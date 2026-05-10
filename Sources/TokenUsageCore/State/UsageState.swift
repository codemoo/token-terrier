import Foundation
import Logging

/// Result of a provider refresh attempt.
public struct UsageUpdate: Equatable, Sendable {
    public let snapshot: UsageSnapshot
    public let emitAuthExpired: Bool

    public init(snapshot: UsageSnapshot, emitAuthExpired: Bool) {
        self.snapshot = snapshot
        self.emitAuthExpired = emitAuthExpired
    }
}

/// Owns the latest provider snapshot and monotonic sequence number.
public actor UsageState {
    private let provider: Provider
    private let credentials: CredentialManager
    private let fetcher: ProviderUsageFetching
    private let producer: ProducerInfo
    private let burnTracker: BurnTracker
    private let cacheTTL: TimeInterval
    private let stickyTTL: TimeInterval
    private let logger: Logger?
    private var seq: Int
    private var latestSnapshot: UsageSnapshot?
    private var lastState: ProviderState?
    private var lastFetchAt: Date?
    /// Most recent **successful** snapshot from the API. We hold onto it so a
    /// transient 429 / 5xx doesn't immediately downgrade the UI to a degraded
    /// snapshot — we keep serving the old good data (with refreshed burn) for
    /// up to `stickyTTL` seconds.
    private var lastOkSnapshot: UsageSnapshot?
    private var lastOkAt: Date?
    /// Account key in effect when `latestSnapshot` was fetched. Cached
    /// snapshots from a different account are stale by definition: we
    /// must re-fetch instead of serving the previous account's quota for
    /// up to a minute (cacheTTL) or up to 10 minutes (stickyTTL).
    private var cacheAccountKey: String?
    private var lastOkAccountKey: String?
    /// When the upstream API returned `429` recently, we suspend our own
    /// fetches until this time. Without this, the daemon's 60 s periodic
    /// refresh keeps re-triggering the same rate-limit window — every
    /// failed call counts as a new request to Cloudflare's bucket and the
    /// cooldown never starts. The backoff is independent from `cacheTTL`
    /// (which only affects when an *unforced* call is allowed); even if
    /// the cache is expired, we keep serving the cached/sticky snapshot
    /// until the backoff lifts.
    private var fetchSuspendedUntil: Date?
    private let rateLimitBackoff: TimeInterval = 300

    public init(
        provider: Provider,
        credentials: CredentialManager,
        fetcher: ProviderUsageFetching,
        producer: ProducerInfo,
        burnTracker: BurnTracker? = nil,
        initialSequence: Int = 0,
        cacheTTL: TimeInterval = 60,
        stickyTTL: TimeInterval = 600,
        logger: Logger? = nil)
    {
        self.provider = provider
        self.credentials = credentials
        self.fetcher = fetcher
        self.producer = producer
        self.burnTracker = burnTracker ?? BurnTracker(provider: provider)
        self.seq = initialSequence
        self.cacheTTL = cacheTTL
        self.stickyTTL = stickyTTL
        self.logger = logger
    }

    /// Returns the most recent snapshot, creating a degraded one if none exists.
    /// Always reflects the latest burn-rate read from the burn tracker.
    public func latest(now: Date = Date()) async -> UsageSnapshot {
        let burn = await burnTracker.snapshot(now: now)
        if let latestSnapshot {
            return latestSnapshot.with(burn: burn)
        }
        let snapshot = UsageSnapshot.degraded(
            provider: provider,
            seq: seq,
            producer: producer,
            now: now,
            state: .networkError)
        latestSnapshot = snapshot
        lastState = snapshot.status.state
        return snapshot.with(burn: burn)
    }

    /// Records a JSONL-derived token event and returns an updated snapshot reflecting the
    /// new burn rate. The seq is bumped so subscribers always see a forward-moving stream.
    public func ingestTokenEvent(_ event: TokenEvent, now: Date = Date()) async -> UsageSnapshot {
        let burn = await burnTracker.ingest(event, now: now)
        seq += 1
        let base = latestSnapshot ?? UsageSnapshot.degraded(
            provider: provider,
            seq: seq,
            producer: producer,
            now: now,
            state: lastState ?? .networkError)
        let updated = base.with(
            burn: burn,
            seq: seq,
            generatedAtUTC: SnapshotDateFormatter.string(from: now))
        latestSnapshot = updated
        return updated
    }

    /// Fetches a fresh snapshot, returning a degraded snapshot on any provider failure.
    /// Successful fetches (and *also* failed ones) are cached for `cacheTTL`
    /// seconds — every `/snapshot` and `/sse` connect would otherwise hammer
    /// the provider's OAuth-usage endpoint, and Anthropic in particular
    /// rate-limits aggressively (HTTP 429). Cached calls still bump `seq` and
    /// re-merge the live burn rate so subscribers see fresh frames.
    public func refreshSnapshot(now: Date = Date(), forceRefetch: Bool = false) async -> UsageUpdate {
        // Resolve the account currently on disk before any cache decision so
        // login / account switches invalidate cached snapshots from the
        // previous account instead of serving them for cacheTTL/stickyTTL.
        let currentAccount = await credentials.currentAccountKey()

        let isSameAccount = currentAccount != nil && cacheAccountKey == currentAccount
        let cacheValid = !forceRefetch
            && isSameAccount
            && lastFetchAt.map { now.timeIntervalSince($0) < cacheTTL } ?? false
        // 429-backoff path: even past cacheTTL, we don't issue a new fetch
        // while the upstream rate-limit cooldown is in flight. We continue
        // to serve `latestSnapshot` (which is itself either a cached OK or a
        // sticky lastOk) so the UI keeps the same numbers it already had.
        let suspended = !forceRefetch
            && isSameAccount
            && (fetchSuspendedUntil.map { now < $0 } ?? false)

        if (cacheValid || suspended), let cached = latestSnapshot {
            seq += 1
            let burn = await burnTracker.snapshot(now: now)
            let merged = cached.with(
                burn: burn,
                seq: seq,
                generatedAtUTC: SnapshotDateFormatter.string(from: now))
            latestSnapshot = merged
            return UsageUpdate(snapshot: merged, emitAuthExpired: false)
        }

        seq += 1
        lastFetchAt = now
        let burn = await burnTracker.snapshot(now: now)
        do {
            let credential = try await credentials.validCredential(now: now)
            let raw: UsageSnapshot
            do {
                raw = try await fetcher.snapshot(
                    for: provider,
                    credential: credential,
                    producer: producer,
                    seq: seq,
                    now: now)
            } catch UsageAPIError.unauthorized {
                // Two recovery paths before declaring auth-expired:
                //
                // 1. Another writer (CLI, daemon, LocalDirect) may have just
                //    rotated the access token. Reload from disk and retry
                //    with the newer token if it differs.
                // 2. The on-disk token still matches what we sent, so the
                //    provider considers it dead even though our local
                //    `expiresAt` / `lastRefresh` window said it was fresh —
                //    early revocation, or a server-side TTL shorter than
                //    ours. Force an OAuth refresh under the lock and retry
                //    once. Only if THAT also fails do we degrade.
                let latest = try await credentials.reloadFromDisk()
                if latest.accessToken != credential.accessToken {
                    raw = try await fetcher.snapshot(
                        for: provider,
                        credential: latest,
                        producer: producer,
                        seq: seq,
                        now: now)
                } else {
                    let refreshed = try await credentials.forceRefresh(after: credential)
                    raw = try await fetcher.snapshot(
                        for: provider,
                        credential: refreshed,
                        producer: producer,
                        seq: seq,
                        now: now)
                }
            }
            let merged = raw.with(burn: burn)
            latestSnapshot = merged
            lastOkSnapshot = raw
            lastOkAt = now
            cacheAccountKey = currentAccount
            lastOkAccountKey = currentAccount
            let previous = lastState
            lastState = merged.status.state
            return UsageUpdate(
                snapshot: merged,
                emitAuthExpired: shouldEmitAuthExpired(from: previous, to: merged.status.state))
        } catch {
            let state = mapError(error)
            logger?.warning("usage refresh failed", metadata: [
                "provider": "\(provider.rawValue)",
                "state": "\(state)",
                "error": "\(error)",
            ])

            // On HTTP 429 from the upstream usage endpoint, freeze our own
            // fetches for `rateLimitBackoff` seconds. Otherwise the daemon's
            // 60 s periodic refresh keeps re-hitting the rate-limit bucket
            // and Cloudflare never starts the cooldown. The sticky cache
            // path below still publishes the last-known-good snapshot, so
            // the UI doesn't blank out while we wait.
            if case let UsageAPIError.server(code, _) = error, code == 429 {
                let until = now.addingTimeInterval(rateLimitBackoff)
                fetchSuspendedUntil = until
                logger?.warning("upstream 429 — suspending fetches", metadata: [
                    "provider": "\(provider.rawValue)",
                    "until": "\(SnapshotDateFormatter.string(from: until))",
                ])
            }

            // For transient errors (network/server-5xx/429) we'd rather serve
            // the last-good snapshot than a degraded one — the UI flapping
            // between "ok" and "API 장애" every minute is worse than showing
            // slightly stale quota numbers. Auth/credential errors still
            // degrade immediately so the user gets the relogin prompt. The
            // last-OK snapshot is also keyed by account so a transient error
            // right after an account switch doesn't resurface the previous
            // account's quota numbers.
            let isTransient = (state == .networkError)
            if isTransient,
               let currentAccount,
               lastOkAccountKey == currentAccount,
               let lastOk = lastOkSnapshot,
               let lastOkAt,
               now.timeIntervalSince(lastOkAt) < stickyTTL
            {
                let merged = lastOk.with(
                    burn: burn,
                    seq: seq,
                    generatedAtUTC: SnapshotDateFormatter.string(from: now))
                latestSnapshot = merged
                let previous = lastState
                lastState = .ok
                return UsageUpdate(
                    snapshot: merged,
                    emitAuthExpired: shouldEmitAuthExpired(from: previous, to: .ok))
            }

            let raw = UsageSnapshot.degraded(
                provider: provider,
                seq: seq,
                producer: producer,
                now: now,
                state: state)
            let merged = raw.with(burn: burn)
            latestSnapshot = merged
            cacheAccountKey = currentAccount
            let previous = lastState
            lastState = state
            return UsageUpdate(
                snapshot: merged,
                emitAuthExpired: shouldEmitAuthExpired(from: previous, to: state))
        }
    }

    private func shouldEmitAuthExpired(from previous: ProviderState?, to next: ProviderState) -> Bool {
        let authStates: Set<ProviderState> = [.authExpired, .codexLoggedOut]
        return authStates.contains(next) && previous != next
    }

    private func mapError(_ error: Error) -> ProviderState {
        if let usage = error as? UsageAPIError {
            switch usage {
            case .unauthorized:
                return provider == .codex ? .codexLoggedOut : .authExpired
            case .invalidResponse:
                return .quotaEndpointChanged
            case .server:
                return .networkError
            case .network:
                return .networkError
            }
        }
        if let refresh = error as? CredentialRefreshError {
            switch refresh {
            case .codexLoginRequired:
                return .codexLoggedOut
            case .noRefreshToken:
                return provider == .codex ? .codexLoggedOut : .authExpired
            case .invalidResponse:
                return .quotaEndpointChanged
            case .rejected:
                return provider == .codex ? .codexLoggedOut : .authExpired
            case .network:
                return .networkError
            }
        }
        if error is CredentialFileError {
            return provider == .codex ? .codexLoggedOut : .authExpired
        }
        return .networkError
    }
}
