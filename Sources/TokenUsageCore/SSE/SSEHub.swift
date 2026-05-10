import Foundation

/// Broadcasts provider SSE frames to bounded per-client streams.
public actor SSEHub {
    private struct Client {
        let continuation: AsyncStream<SSEEvent>.Continuation
        let heartbeatTask: Task<Void, Never>?
    }

    private let heartbeatInterval: Duration
    private var clients: [UUID: Client] = [:]
    private var latestSnapshot: SSEEvent?
    private var isClosed = false

    public init(heartbeatInterval: Duration = .seconds(10)) {
        self.heartbeatInterval = heartbeatInterval
    }

    /// Registers a new client and immediately sends the latest snapshot when present.
    public func subscribe(lastEventID: String? = nil) -> AsyncStream<SSEEvent> {
        let id = UUID()
        let pair = AsyncStream<SSEEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard !isClosed else {
            // The hub has been shut down. Hand the caller a finished
            // stream so their `for await` loop exits cleanly.
            pair.continuation.finish()
            return pair.stream
        }
        if let latestSnapshot {
            pair.continuation.yield(latestSnapshot)
        }
        let heartbeatTask = Task { [heartbeatInterval] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: heartbeatInterval)
                } catch {
                    return
                }
                pair.continuation.yield(.heartbeat())
            }
        }
        clients[id] = Client(continuation: pair.continuation, heartbeatTask: heartbeatTask)
        pair.continuation.onTermination = { @Sendable _ in
            heartbeatTask.cancel()
            Task {
                await self.unregister(id)
            }
        }
        _ = lastEventID
        return pair.stream
    }

    /// Stores and broadcasts a snapshot event.
    public func publishSnapshot(_ snapshot: UsageSnapshot) throws {
        guard !isClosed else { return }
        let event = try SSEEvent.snapshot(snapshot)
        latestSnapshot = event
        broadcast(event)
    }

    /// Broadcasts an auth-expired transition event.
    public func publishAuthExpired(provider: Provider, seq: Int, state: ProviderState) {
        guard !isClosed else { return }
        broadcast(.authExpired(provider: provider, seq: seq, state: state))
    }

    /// Returns the number of currently registered clients.
    public func clientCount() -> Int {
        clients.count
    }

    /// Tears the hub down: cancels every heartbeat task and finishes every
    /// client stream. Subsequent `subscribe` calls return an already-finished
    /// stream and `publish*` calls become no-ops. Used by the daemon's
    /// graceful shutdown so peers see EOF instead of being killed mid-frame.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        for client in clients.values {
            client.heartbeatTask?.cancel()
            client.continuation.finish()
        }
        clients.removeAll()
    }

    private func broadcast(_ event: SSEEvent) {
        // Collect terminated clients in a separate pass so we don't mutate
        // the dictionary while iterating it. Without this cleanup, peers
        // that disconnected mid-broadcast leak both the dictionary entry
        // and their heartbeat task.
        var terminated: [UUID] = []
        for (id, client) in clients {
            switch client.continuation.yield(event) {
            case .terminated:
                terminated.append(id)
            case .enqueued, .dropped:
                break
            @unknown default:
                break
            }
        }
        for id in terminated {
            unregister(id)
        }
    }

    private func unregister(_ id: UUID) {
        if let client = clients.removeValue(forKey: id) {
            client.heartbeatTask?.cancel()
        }
    }
}
