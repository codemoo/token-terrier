import Foundation
import Logging
import TokenUsageCore

/// In-process producer for the "로컬 직접 read" connection mode. Skips the
/// daemon + SSE entirely and runs the **same** stack the daemon does:
/// `CredentialManager` (reads ~/.claude/.credentials.json + ~/.codex/auth.json,
/// auto-refreshes OAuth), `UsageAPIClient` (the real Anthropic / ChatGPT
/// quota endpoints for 5h + weekly windows + credits), and local watchers for
/// burn-rate ingest. The synthesized `UsageSnapshot` is pushed to
/// `StatusStore` exactly like the SSE path would.
public actor LocalDirectClient {
    public let providers: Set<Provider>
    private let store: StatusStore
    private let producer: ProducerInfo
    private let states: [Provider: UsageState]
    private var poller: JSONLPoller?
    private var hermesWatcher: HermesSQLiteWatcher?
    private var refreshTask: Task<Void, Never>?
    /// Last time we ran the per-provider diagnostic probe. Throttled so a
    /// sustained degraded state doesn't re-run the credential + API legs
    /// every minute (doubling outage traffic and risking extra
    /// refresh-token churn during the very window we want to back off).
    private var lastDiagnosticAt: [Provider: Date] = [:]
    private let diagnosticInterval: TimeInterval = 300

    /// API quota refresh cadence. Anthropic recommends ≥30 s between hits;
    /// 60 s gives us decent freshness without hammering.
    private let refreshInterval: TimeInterval = 60

    public init(store: StatusStore, providers: Set<Provider>) {
        self.providers = providers
        self.store = store
        self.producer = ProducerInfo.current()

        let transport = URLSessionHTTPClient()
        let refresher = OAuthTokenRefresher(transport: transport)
        let usageClient = UsageAPIClient(transport: transport)

        var built: [Provider: UsageState] = [:]
        for provider in providers {
            let manager: CredentialManager
            switch provider {
            case .claude:
                manager = CredentialManager(
                    provider: .claude,
                    loader: { try CredentialFiles.loadClaude() },
                    saver:  { try CredentialFiles.saveClaude($0) },
                    refresher: refresher)
            case .codex:
                manager = CredentialManager(
                    provider: .codex,
                    loader: { try CredentialFiles.loadCodex() },
                    saver:  { try CredentialFiles.saveCodex($0) },
                    refresher: refresher)
            }
            built[provider] = UsageState(
                provider: provider,
                credentials: manager,
                fetcher: usageClient,
                producer: producer)
        }
        self.states = built
    }

    public func start() async {
        guard poller == nil, !providers.isEmpty else { return }

        let providers = self.providers
        await Task { @MainActor [store] in
            for provider in providers {
                store.setState(provider: provider, .connecting, source: "local-direct")
            }
        }.value

        // First quota fetch right away so the user isn't staring at "—"
        // for a minute after switching modes.
        await refreshAll()

        // Periodic quota refresh.
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(60 * 1_000_000_000))
                await self?.refreshAll()
            }
        }

        // JSONL → burn-rate ingest. Each event flows through UsageState's
        // existing logic (which keeps API quota fields intact and only bumps
        // burn fields), then we push the resulting snapshot. Events for
        // providers we don't own are dropped (they're being served by SSE).
        let states = self.states
        let store = self.store
        let logger = Logger(label: "tokenterrier.localdirect.poller")
        let p = JSONLPoller(config: .userDefaults(), logger: logger) { event in
            guard let state = states[event.provider] else { return }
            let snapshot = await state.ingestTokenEvent(event)
            await Task { @MainActor in
                store.update(provider: event.provider, snapshot: snapshot, source: "local-direct")
            }.value
        }
        self.poller = p
        await p.start()

        let hermesLogger = Logger(label: "tokenterrier.localdirect.hermes-sqlite")
        let hermes = HermesSQLiteWatcher(config: .userDefaults(), logger: hermesLogger) { event in
            guard let state = states[event.provider] else { return }
            let snapshot = await state.ingestTokenEvent(event)
            await Task { @MainActor in
                store.update(provider: event.provider, snapshot: snapshot, source: "local-direct")
            }.value
        }
        self.hermesWatcher = hermes
        await hermes.start()
    }

    public func stop() async {
        let inflight = refreshTask
        refreshTask = nil
        inflight?.cancel()
        if let p = poller { await p.stop() }
        poller = nil
        if let hermes = hermesWatcher { await hermes.stop() }
        hermesWatcher = nil
        // Wait for the cancelled refresh task to actually exit before
        // returning. Otherwise a mode swap can race: the old client
        // publishes a stale snapshot to `StatusStore` *after* AppState has
        // already started the new strategy, and the user briefly sees the
        // wrong state.
        await inflight?.value
    }

    private func refreshAll() async {
        for provider in providers {
            guard let state = states[provider] else { continue }
            await refresh(provider: provider, state: state)
        }
    }

    private func refresh(provider: Provider, state: UsageState) async {
        let update = await state.refreshSnapshot()
        let snapshot = update.snapshot
        // Surface non-OK provider states to the log file so users can tell us
        // *why* their localDirect Claude or Codex isn't loading. UsageState
        // swallows the underlying Error on purpose; we re-run the failing
        // leg here just to log the specific cause. Throttled so a sustained
        // outage doesn't run an extra refresh + API roundtrip every 60 s.
        if snapshot.status.state != .ok, shouldRunDiagnostic(for: provider) {
            await logDiagnostic(provider: provider, observed: snapshot.status.state)
        }
        let storeRef = self.store
        await Task { @MainActor in
            storeRef.update(provider: provider, snapshot: snapshot, source: "local-direct")
        }.value
    }

    private func shouldRunDiagnostic(for provider: Provider) -> Bool {
        let now = Date()
        if let last = lastDiagnosticAt[provider],
           now.timeIntervalSince(last) < diagnosticInterval
        {
            return false
        }
        lastDiagnosticAt[provider] = now
        return true
    }

    /// Re-runs the credential + API legs and logs the actual Swift error that
    /// caused `UsageState` to fall back to a degraded snapshot.
    private func logDiagnostic(provider: Provider, observed state: ProviderState) async {
        let manager: CredentialManager
        switch provider {
        case .claude:
            manager = CredentialManager(
                provider: .claude,
                loader: { try CredentialFiles.loadClaude() },
                saver:  { try CredentialFiles.saveClaude($0) },
                refresher: OAuthTokenRefresher())
        case .codex:
            manager = CredentialManager(
                provider: .codex,
                loader: { try CredentialFiles.loadCodex() },
                saver:  { try CredentialFiles.saveCodex($0) },
                refresher: OAuthTokenRefresher())
        }
        let usage = UsageAPIClient()
        do {
            let cred = try await manager.validCredential()
            _ = try await usage.snapshot(
                for: provider,
                credential: cred,
                producer: producer,
                seq: 0,
                now: Date())
            // We got here, but UsageState still reported \(state). Likely a
            // race-condition window — log so we can spot patterns.
            SSELog.shared.log("local-direct \(provider.rawValue) state=\(state) but probe ok (transient?)")
        } catch let e as CredentialFileError {
            SSELog.shared.log("local-direct \(provider.rawValue) credential-file: \(e)")
        } catch let e as CredentialRefreshError {
            SSELog.shared.log("local-direct \(provider.rawValue) refresh-failed: \(e)")
        } catch let e as UsageAPIError {
            SSELog.shared.log("local-direct \(provider.rawValue) api-failed: \(e)")
        } catch {
            SSELog.shared.log("local-direct \(provider.rawValue) error: \(error)")
        }
    }
}
