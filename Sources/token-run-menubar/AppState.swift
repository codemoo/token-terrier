import Foundation
import Observation
import TokenUsageCore

/// Top-level glue: owns settings, the status store, and whichever client(s)
/// match the user's `ConnectionMode`. The menu-bar SwiftUI scenes read the
/// observable settings/store; the clients pull a value-typed
/// `SettingsSnapshot` each attempt so they stay outside the main actor's
/// hot path.
@MainActor
@Observable
public final class AppState {
    public let settings: AppSettings
    public let status: StatusStore
    private var sseClients: [Provider: SSEClient] = [:]
    private var localDirect: LocalDirectClient?
    private var providerStrategy: [Provider: Strategy] = [:]
    private var settingsObserver: Task<Void, Never>?

    private enum Strategy: Equatable { case sse, localDirect }

    public init() {
        let settings = AppSettings()
        self.settings = settings
        self.status = StatusStore()

        Task { @MainActor in
            await self.reapplyStrategies()
            self.observeSettings()
        }
    }

    /// Compares the per-provider connection mode against the running clients
    /// and swaps strategies in / out as needed. Idempotent.
    private func reapplyStrategies() async {
        let desiredFor: (Provider) -> Strategy = { [settings] provider in
            settings.mode(for: provider) == .localDirect ? .localDirect : .sse
        }

        // 1) Stop SSE clients that should no longer be running, and let
        //    LocalDirectClient know which providers it now owns.
        for provider in Provider.allCases where providerStrategy[provider] != desiredFor(provider) {
            if let existing = sseClients[provider] {
                await existing.stop()
                sseClients[provider] = nil
            }
            // Reset visible state so the user immediately sees the swap.
            status.setState(provider: provider, .connecting, source: nil)
        }

        // 2) Reconcile LocalDirectClient against the new active set.
        let localProviders: Set<Provider> = Set(
            Provider.allCases.filter { desiredFor($0) == .localDirect })
        let currentLocal = localDirect?.providers ?? []
        if localProviders != currentLocal {
            await localDirect?.stop()
            localDirect = nil
            if !localProviders.isEmpty {
                let client = LocalDirectClient(store: status, providers: localProviders)
                localDirect = client
                await client.start()
            }
        }

        // 3) Spin up SSE clients for SSE-strategy providers that aren't running.
        for provider in Provider.allCases where desiredFor(provider) == .sse && sseClients[provider] == nil {
            let getSnapshot: @Sendable () async -> SettingsSnapshot = { [weak self] in
                await self?.snapshotSettings() ?? SettingsSnapshot(
                    claudeConnectionMode: .auto,
                    codexConnectionMode: .auto,
                    remoteURL: "",
                    loopbackURL: "",
                    claudeBearer: "",
                    codexBearer: "")
            }
            let client = SSEClient(provider: provider, getSettingsSnapshot: getSnapshot, store: status)
            sseClients[provider] = client
            await client.start()
        }

        for provider in Provider.allCases {
            providerStrategy[provider] = desiredFor(provider)
        }
    }

    /// Polls per-provider settings every second and re-runs `reapplyStrategies`
    /// when anything changes. SwiftUI's `@Observable` doesn't expose a native
    /// AsyncSequence, and this beats sprinkling property observers over every
    /// settings touch.
    private func observeSettings() {
        settingsObserver?.cancel()
        let weakSelf = { [weak self] in self }
        settingsObserver = Task { @MainActor in
            var lastClaude = self.settings.claudeConnectionMode
            var lastCodex  = self.settings.codexConnectionMode
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let me = weakSelf() else { return }
                let nowClaude = me.settings.claudeConnectionMode
                let nowCodex = me.settings.codexConnectionMode
                if nowClaude != lastClaude || nowCodex != lastCodex {
                    lastClaude = nowClaude
                    lastCodex = nowCodex
                    await me.reapplyStrategies()
                }
            }
        }
    }

    public func snapshotSettings() async -> SettingsSnapshot {
        SettingsSnapshot(
            claudeConnectionMode: settings.claudeConnectionMode,
            codexConnectionMode: settings.codexConnectionMode,
            remoteURL: settings.remoteURL,
            loopbackURL: settings.loopbackURL,
            claudeBearer: settings.claudeBearer,
            codexBearer: settings.codexBearer)
    }
}
