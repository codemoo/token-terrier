import Foundation

/// Coordinates credential loading and singleflight refresh for one provider.
public actor CredentialManager {
    public typealias CredentialLoader = @Sendable () async throws -> OAuthCredential
    public typealias CredentialSaver = @Sendable (OAuthCredential) async throws -> Void

    private let provider: Provider
    private let loader: CredentialLoader
    private let saver: CredentialSaver
    private let refresher: OAuthTokenRefresher
    private let refreshLock: CredentialRefreshLock?
    private var cached: OAuthCredential?
    private var refreshTask: Task<OAuthCredential, Error>?

    public init(
        provider: Provider,
        loader: @escaping CredentialLoader,
        saver: @escaping CredentialSaver,
        refresher: OAuthTokenRefresher = OAuthTokenRefresher(),
        refreshLock: CredentialRefreshLock? = nil)
    {
        self.provider = provider
        self.loader = loader
        self.saver = saver
        self.refresher = refresher
        // Default to a lock file next to the credential JSON. Tests can pass
        // their own `CredentialRefreshLock` (with a temp URL) or pass `nil`
        // explicitly via the package-internal helper if they want the old
        // unlocked behavior — production callers should let it default.
        self.refreshLock = refreshLock ?? .default(for: provider)
    }

    /// Returns a credential that is fresh enough for a provider API request.
    /// Re-reads the credential file every call so other writers (Claude/Codex
    /// CLI, daemon, LocalDirect) winning a refresh race don't leave us pinned
    /// to a stale in-memory token for the rest of the process lifetime.
    public func validCredential(now: Date = Date()) async throws -> OAuthCredential {
        let credential = try await reloadFromDisk()
        guard credential.needsRefresh(now: now) else { return credential }
        do {
            return try await refreshSingleflight(credential, now: now)
        } catch {
            // A refresh rejection (HTTP 4xx) typically means another writer
            // already rotated the token. Wait briefly, re-read disk, and
            // adopt the fresh credential rather than degrading the UI to a
            // false "logged out" state. With the cross-process lock this is
            // mostly belt-and-suspenders for writers that don't share the
            // lock (Claude/Codex CLI proper).
            if error.isAuthRefreshRejection {
                try? await Task.sleep(for: .milliseconds(250))
                if let latest = try? await reloadFromDisk(),
                   latest != credential,
                   !latest.needsRefresh(now: now)
                {
                    return latest
                }
            }
            throw error
        }
    }

    /// Reads the credential file and refreshes the in-memory cache.
    @discardableResult
    public func reloadFromDisk() async throws -> OAuthCredential {
        let loaded = try await loader()
        guard loaded.provider == provider else {
            throw CredentialFileError.unsupportedProvider(
                "Loaded \(loaded.provider.rawValue), expected \(provider.rawValue)")
        }
        cached = loaded
        return loaded
    }

    /// Account key for the on-disk credential without triggering a refresh.
    /// Used by `UsageState` to invalidate cached snapshots when the user
    /// logs out / switches accounts. Returns `nil` when the file is
    /// missing or unreadable so the caller falls back to the safe path.
    public func currentAccountKey() async -> String? {
        try? await reloadFromDisk().accountKey
    }

    /// Forces an OAuth refresh-token roundtrip even when the cached
    /// `expiresAt` / `lastRefresh` say the access token is still valid.
    /// Used after an upstream `401` on a token whose local expiry hadn't
    /// elapsed — the provider has revoked it (or its server-side TTL is
    /// shorter than ours), so we must rotate before degrading. If another
    /// writer rotated the token while we were getting the 401, we adopt
    /// the disk credential without spending our refresh token.
    public func forceRefresh(after rejected: OAuthCredential) async throws -> OAuthCredential {
        if let refreshTask {
            return try await refreshTask.value
        }
        let provider = self.provider
        let loader = self.loader
        let saver = self.saver
        let refresher = self.refresher
        let refreshLock = self.refreshLock

        let task = Task<OAuthCredential, Error> {
            func refreshFromLatestDisk() async throws -> OAuthCredential {
                let latest = try await loader()
                guard latest.provider == provider else {
                    throw CredentialFileError.unsupportedProvider(
                        "Loaded \(latest.provider.rawValue), expected \(provider.rawValue)")
                }
                if latest.accessToken != rejected.accessToken {
                    return latest
                }
                let refreshed = try await refresher.refresh(latest)
                try await saver(refreshed)
                return refreshed
            }
            if let refreshLock {
                return try await refreshLock.withLock { try await refreshFromLatestDisk() }
            }
            return try await refreshFromLatestDisk()
        }
        refreshTask = task
        do {
            let refreshed = try await task.value
            cached = refreshed
            refreshTask = nil
            return refreshed
        } catch {
            refreshTask = nil
            throw error
        }
    }

    /// Replaces the in-memory credential cache.
    public func setCredentialForTesting(_ credential: OAuthCredential?) {
        self.cached = credential
    }

    private func refreshSingleflight(_ credential: OAuthCredential, now: Date) async throws -> OAuthCredential {
        if let refreshTask {
            return try await refreshTask.value
        }
        let provider = self.provider
        let loader = self.loader
        let saver = self.saver
        let refresher = self.refresher
        let refreshLock = self.refreshLock

        let task = Task<OAuthCredential, Error> {
            // Inside the cross-process lock, re-read disk first. If another
            // writer already saved a fresh credential while we were waiting
            // for the lock, adopt their result and skip our own refresh —
            // otherwise we'd burn a (possibly single-use) refresh token
            // they already spent and self-inflict an HTTP 401.
            func refreshFromLatestDisk() async throws -> OAuthCredential {
                let latest = try await loader()
                guard latest.provider == provider else {
                    throw CredentialFileError.unsupportedProvider(
                        "Loaded \(latest.provider.rawValue), expected \(provider.rawValue)")
                }
                guard latest.needsRefresh(now: now) else { return latest }
                let refreshed = try await refresher.refresh(latest)
                try await saver(refreshed)
                return refreshed
            }
            if let refreshLock {
                return try await refreshLock.withLock {
                    try await refreshFromLatestDisk()
                }
            }
            return try await refreshFromLatestDisk()
        }
        refreshTask = task
        do {
            let refreshed = try await task.value
            cached = refreshed
            refreshTask = nil
            return refreshed
        } catch {
            refreshTask = nil
            throw error
        }
    }
}

private extension Error {
    /// True when an OAuth refresh failure looks like the provider rejected
    /// our token (HTTP 4xx) — meaning another writer probably already won
    /// the refresh race. Network errors return false because re-reading
    /// disk wouldn't change anything.
    var isAuthRefreshRejection: Bool {
        guard let err = self as? CredentialRefreshError else { return false }
        switch err {
        case .rejected, .codexLoginRequired:
            return true
        case .noRefreshToken, .invalidResponse, .network:
            return false
        }
    }
}
