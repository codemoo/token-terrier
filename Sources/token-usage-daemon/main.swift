import Foundation
import Hummingbird
import Logging
import NIOCore
import TokenUsageCore

@main
struct TokenUsageDaemon {
    static func main() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        let logger = Logger(label: "ai.openclaw.token-usage-daemon")
        let environment = ProcessInfo.processInfo.environment
        let tokenResult = try BearerTokenStore(environment: environment).loadOrCreate()
        if tokenResult.createdFile {
            let message = """
            Generated bearer tokens at \(tokenResult.url.path)
            TOKEN_USAGE_CLAUDE_TOKEN=\(tokenResult.tokens.claude)
            TOKEN_USAGE_CODEX_TOKEN=\(tokenResult.tokens.codex)
            """
            if let data = (message + "\n").data(using: .utf8) {
                FileHandle.standardOutput.write(data)
            }
        }

        let producer = ProducerInfo.current(environment: environment)
        let transport = URLSessionHTTPClient()
        let refresher = OAuthTokenRefresher(transport: transport)
        let usageClient = UsageAPIClient(transport: transport)

        let claudeManager = CredentialManager(
            provider: .claude,
            loader: {
                try CredentialFiles.loadClaude()
            },
            saver: { credential in
                try CredentialFiles.saveClaude(credential)
            },
            refresher: refresher)
        let codexManager = CredentialManager(
            provider: .codex,
            loader: {
                try CredentialFiles.loadCodex()
            },
            saver: { credential in
                try CredentialFiles.saveCodex(credential)
            },
            refresher: refresher)

        let claudeState = UsageState(provider: .claude, credentials: claudeManager, fetcher: usageClient, producer: producer, logger: logger)
        let codexState = UsageState(provider: .codex, credentials: codexManager, fetcher: usageClient, producer: producer, logger: logger)
        let claudeHub = SSEHub()
        let codexHub = SSEHub()
        let backgroundTasks = DaemonTaskRegistry()
        let appContext = DaemonContext(
            tokens: tokenResult.tokens,
            claudeState: claudeState,
            codexState: codexState,
            claudeHub: claudeHub,
            codexHub: codexHub,
            backgroundTasks: backgroundTasks,
            logger: logger)

        let router = Router()
        router.get("healthz") { _, _ in
            try jsonResponse(["ok": true])
        }
        router.get("version") { _, _ in
            try jsonResponse([
                "name": "token-usage-daemon",
                "schema": "1",
                "version": "0.1.0-day1",
            ])
        }
        router.get("claude", "snapshot") { request, _ in
            try await appContext.snapshot(provider: .claude, request: request)
        }
        router.get("codex", "snapshot") { request, _ in
            try await appContext.snapshot(provider: .codex, request: request)
        }
        router.get("claude", "sse") { request, _ in
            try await appContext.sse(provider: .claude, request: request)
        }
        router.get("codex", "sse") { request, _ in
            try await appContext.sse(provider: .codex, request: request)
        }
        // Local usage watchers → burn-rate updates pushed via SSE
        let pollerLogger = Logger(label: "ai.openclaw.token-usage-daemon.poller")
        let poller = JSONLPoller(config: .userDefaults(), logger: pollerLogger) { event in
            let context = appContext
            let snapshot: UsageSnapshot
            switch event.provider {
            case .claude:
                snapshot = await context.claudeState.ingestTokenEvent(event)
                try? await context.claudeHub.publishSnapshot(snapshot)
            case .codex:
                snapshot = await context.codexState.ingestTokenEvent(event)
                try? await context.codexHub.publishSnapshot(snapshot)
            }
        }
        await poller.start()
        let hermesLogger = Logger(label: "ai.openclaw.token-usage-daemon.hermes-sqlite")
        let hermesWatcher = HermesSQLiteWatcher(config: .userDefaults(), logger: hermesLogger) { event in
            let context = appContext
            let snapshot: UsageSnapshot
            switch event.provider {
            case .claude:
                snapshot = await context.claudeState.ingestTokenEvent(event)
                try? await context.claudeHub.publishSnapshot(snapshot)
            case .codex:
                snapshot = await context.codexState.ingestTokenEvent(event)
                try? await context.codexHub.publishSnapshot(snapshot)
            }
        }
        await hermesWatcher.start()

        // Periodic provider refresh. Without this the daemon only fetches on
        // /sse and /snapshot connect; long-running clients never see quota
        // / auth changes pushed and a stale credential file is detected only
        // when somebody reconnects. 60 s matches `UsageState.cacheTTL`.
        let refreshInterval: TimeInterval = 60
        await backgroundTasks.spawn {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(refreshInterval)) } catch { return }
                await appContext.refreshAndPublish(provider: .claude)
            }
        }
        await backgroundTasks.spawn {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(refreshInterval)) } catch { return }
                await appContext.refreshAndPublish(provider: .codex)
            }
        }

        let bind = environment["TOKEN_USAGE_BIND"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = bind?.isEmpty == false ? bind ?? "127.0.0.1" : "127.0.0.1"
        let port = Int(environment["TOKEN_USAGE_PORT"] ?? "") ?? 18910
        logger.info("Starting token usage daemon", metadata: ["bind": "\(host)", "port": "\(port)"])
        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port)))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await app.runService() }
            group.addTask {
                for await _ in shutdownSignals() {
                    app.stop()
                    await poller.stop()
                    await hermesWatcher.stop()
                    await backgroundTasks.cancelAll()
                    await claudeHub.close()
                    await codexHub.close()
                    return
                }
            }
            _ = try await group.next()
            group.cancelAll()
            app.stop()
            await poller.stop()
            await hermesWatcher.stop()
            await backgroundTasks.cancelAll()
            await claudeHub.close()
            await codexHub.close()
        }
    }
}

private actor DaemonTaskRegistry {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var accepting = true

    func spawn(_ operation: @escaping @Sendable () async -> Void) {
        guard accepting else { return }
        let id = UUID()
        tasks[id] = Task {
            await operation()
            await self.remove(id)
        }
    }

    /// Cancels every spawned task and waits for them to finish observing the
    /// cancellation. Without the await, shutdown returns while refresh tasks
    /// are still mid-flight and the daemon exits with untracked work in the
    /// air. The `accepting` flag ensures any race that tries to register a
    /// new task during shutdown becomes a no-op instead of leaking.
    func cancelAll() async {
        accepting = false
        let inflight = Array(tasks.values)
        tasks.removeAll()
        for task in inflight { task.cancel() }
        for task in inflight { await task.value }
    }

    private func remove(_ id: UUID) {
        tasks[id] = nil
    }
}

private func shutdownSignals() -> AsyncStream<Int32> {
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    return AsyncStream { continuation in
        // DispatchSource is thread-safe but DispatchSourceSignal doesn't
        // conform to Sendable; box the pair so onTermination can capture them.
        final class Sources: @unchecked Sendable {
            let term: any DispatchSourceSignal
            let int: any DispatchSourceSignal
            init(_ t: any DispatchSourceSignal, _ i: any DispatchSourceSignal) {
                term = t; int = i
            }
        }
        let sources = Sources(
            DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global()),
            DispatchSource.makeSignalSource(signal: SIGINT, queue: .global()))
        sources.term.setEventHandler { continuation.yield(SIGTERM) }
        sources.int.setEventHandler { continuation.yield(SIGINT) }
        continuation.onTermination = { _ in
            sources.term.cancel()
            sources.int.cancel()
        }
        sources.term.resume()
        sources.int.resume()
    }
}

private struct DaemonContext: Sendable {
    let tokens: BearerTokens
    let claudeState: UsageState
    let codexState: UsageState
    let claudeHub: SSEHub
    let codexHub: SSEHub
    let backgroundTasks: DaemonTaskRegistry
    let logger: Logger

    func snapshot(provider: Provider, request: Request) async throws -> Response {
        guard authorized(provider: provider, request: request) else {
            return unauthorizedResponse()
        }
        let update = await state(for: provider).refreshSnapshot()
        try await publish(update: update, provider: provider)
        return try jsonResponse(update.snapshot)
    }

    func sse(provider: Provider, request: Request) async throws -> Response {
        guard authorized(provider: provider, request: request) else {
            return unauthorizedResponse()
        }
        let lastEventID = request.headers[.init("last-event-id")]
        let stream = await hub(for: provider).subscribe(lastEventID: lastEventID)
        // Refresh in the background so headers + heartbeat go out
        // immediately. A slow upstream fetch (DNS, 429, API timeout) used to
        // delay the first byte for ~30 s, which clients interpreted as a
        // dead stream and reconnected. The refreshed snapshot now arrives
        // through the SSE stream like any other event.
        let providerState = state(for: provider)
        await backgroundTasks.spawn {
            let update = await providerState.refreshSnapshot()
            try? await self.publish(update: update, provider: provider)
        }
        return sseResponse(stream)
    }

    /// Refreshes a provider's snapshot from the upstream API and broadcasts
    /// the result over SSE. Used by both the periodic refresh task and the
    /// /sse / /snapshot HTTP handlers when they need a freshly fetched
    /// snapshot rather than the cached one.
    func refreshAndPublish(provider: Provider) async {
        let update = await state(for: provider).refreshSnapshot()
        try? await publish(update: update, provider: provider)
    }

    private func publish(update: UsageUpdate, provider: Provider) async throws {
        let hub = hub(for: provider)
        // Publish auth_expired first so the state-bearing snapshot is the
        // last frame in the hub's `bufferingNewest(1)` per-client buffer.
        // Otherwise a slow client whose buffer holds only one frame can lose
        // the snapshot when auth_expired evicts it, and the menubar (which
        // only logs auth_expired) never sees the degraded state.
        if update.emitAuthExpired {
            await hub.publishAuthExpired(provider: provider, seq: update.snapshot.seq, state: update.snapshot.status.state)
        }
        try await hub.publishSnapshot(update.snapshot)
    }

    private func authorized(provider: Provider, request: Request) -> Bool {
        BearerTokenStore.isAuthorized(
            authorizationHeader: request.headers[.authorization],
            expectedToken: tokens.token(for: provider))
    }

    private func state(for provider: Provider) -> UsageState {
        switch provider {
        case .claude:
            claudeState
        case .codex:
            codexState
        }
    }

    private func hub(for provider: Provider) -> SSEHub {
        switch provider {
        case .claude:
            claudeHub
        case .codex:
            codexHub
        }
    }

}

private func unauthorizedResponse() -> Response {
    let payload = #"{"error":"unauthorized"}"#
    return Response(
        status: .unauthorized,
        headers: [.contentType: "application/json; charset=utf-8"],
        body: .init(byteBuffer: ByteBuffer(string: payload)))
}

private func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) throws -> Response {
    let data = try JSONEncoder.tokenUsage.encode(value)
    return Response(
        status: status,
        headers: [.contentType: "application/json; charset=utf-8"],
        body: .init(byteBuffer: ByteBuffer(data: data)))
}

private func sseResponse(_ stream: AsyncStream<SSEEvent>) -> Response {
    let body = ResponseBody { writer in
        for await event in stream {
            try await writer.write(ByteBuffer(string: event.text))
        }
    }
    return Response(
        status: .ok,
        headers: [
            .contentType: "text/event-stream; charset=utf-8",
            .cacheControl: "no-cache",
            .connection: "keep-alive",
            .init("x-accel-buffering"): "no",
        ],
        body: body)
}
