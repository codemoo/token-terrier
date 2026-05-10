import Foundation
import TokenUsageCore

/// Streams `event: snapshot` frames from one provider's SSE endpoint and forwards
/// each decoded `UsageSnapshot` to the `StatusStore` on the main actor.
///
/// The chosen URL depends on `ConnectionMode` and walks a fallback chain in
/// `auto` mode: loopback → configured remote. `localDirect` mode is handled by
/// `LocalDirectClient` instead — the SSE client is torn down whenever that
/// mode is active.
///
/// Reconnects on any error with a 1 s → 10 s exponential backoff (kept short
/// so a freshly-launched app — including post-Sparkle-update launches — gets
/// its SSE stream back within a few seconds rather than minutes).
public actor SSEClient {
    public let provider: Provider
    private let getSettingsSnapshot: @Sendable () async -> SettingsSnapshot
    private let store: StatusStore
    private var task: Task<Void, Never>?
    private var backoff: TimeInterval = 1

    public init(
        provider: Provider,
        getSettingsSnapshot: @Sendable @escaping () async -> SettingsSnapshot,
        store: StatusStore)
    {
        self.provider = provider
        self.getSettingsSnapshot = getSettingsSnapshot
        self.store = store
    }

    public func start() {
        guard task == nil else { return }
        task = Task { await self.loop() }
    }

    public func stop() async {
        let inflight = task
        task = nil
        inflight?.cancel()
        // Await the cancelled loop's exit before returning. Without this,
        // a mode swap that calls `await stop()` in `AppState` can still see
        // a stale snapshot land in `StatusStore` after the new strategy
        // has taken over — the URLSession byte stream is mid-frame, the
        // dispatch is mid-await, and the cancellation hasn't reached
        // `Task.isCancelled` yet.
        await inflight?.value
    }

    private func loop() async {
        while !Task.isCancelled {
            let snapshot = await getSettingsSnapshot()
            let attempts = candidateURLs(snapshot: snapshot)
            var connected = false
            for (label, url) in attempts {
                let success = await streamOnce(url: url, label: label, bearer: snapshot.bearer(for: provider))
                if success {
                    connected = true
                    backoff = 1
                    break
                }
            }
            if !connected {
                await store.setState(provider: provider, .offline)
            }
            // Sleep before next attempt — bounded exponential backoff.
            let delay = backoff
            backoff = min(backoff * 1.5, 10)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// Returns the URL list to try, in order. `auto` does loopback then remote.
    private func candidateURLs(snapshot: SettingsSnapshot) -> [(label: String, url: URL)] {
        switch snapshot.mode(for: provider) {
        case .auto:
            return [
                ("loopback", url(base: snapshot.loopbackURL)),
                ("remote", url(base: snapshot.remoteURL)),
            ].compactMap { label, u in u.map { (label, $0) } }
        case .loopback:
            return [url(base: snapshot.loopbackURL)].compactMap { $0 }.map { ("loopback", $0) }
        case .remote:
            return [url(base: snapshot.remoteURL)].compactMap { $0 }.map { ("remote", $0) }
        case .localDirect:
            // Handled by LocalDirectClient; the SSE client should be inactive
            // when this mode is selected (AppState swaps strategies).
            return []
        }
    }

    private func url(base: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "\(trimmed)/\(provider.rawValue)/sse"),
              url.scheme != nil,
              url.host != nil
        else {
            return nil
        }
        return url
    }

    private func streamOnce(url: URL, label: String, bearer: String) async -> Bool {
        guard !bearer.isEmpty else {
            return false
        }
        await store.setState(provider: provider, .connecting, source: label)

        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // SSE is a long-lived stream where data may go quiet between server
        // heartbeats. URLSession treats `timeoutInterval` as an *idle*
        // timeout — if the value is shorter than the server's heartbeat
        // cadence, the request gets killed right between heartbeats. The
        // hub now beats every 10 s, so 60 s gives us 6× safety margin
        // before a real silence is treated as a dead stream. (Initial
        // connect-failure speed is unaffected: ECONNREFUSED / DNS
        // failures bubble up immediately.)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let session = URLSession(configuration: streamingSessionConfig())
        defer { session.finishTasksAndInvalidate() }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                SSELog.shared.log("\(provider.rawValue) \(label) bad status \(code)")
                return false
            }
            await processStream(bytes: bytes, source: label)
            return true
        } catch {
            SSELog.shared.log("\(provider.rawValue) \(label) error \(error.localizedDescription)")
            return false
        }
    }

    private func processStream(bytes: URLSession.AsyncBytes, source: String) async {
        // SSE uses a blank line (`\n\n`) as the event delimiter, but
        // `URLSession.AsyncBytes.lines` collapses consecutive newlines and never
        // yields the empty line — events would never dispatch. So we read raw
        // bytes and split lines ourselves. We also track `event:` so that
        // non-snapshot frames (like `auth_expired`) reach the right handler
        // instead of being decoded as a `UsageSnapshot` and silently failing.
        var lineBytes: [UInt8] = []
        var dataBuffer = ""
        var eventType = ""
        var sawCR = false

        do {
            for try await byte in bytes {
                if Task.isCancelled { return }

                let isLineEnd: Bool
                if byte == 0x0A {
                    isLineEnd = true
                } else if byte == 0x0D {
                    // CR — assume CRLF; wait for the LF (handled in next iteration).
                    sawCR = true
                    continue
                } else {
                    if sawCR {
                        // We saw CR earlier and the next byte is not LF, so the
                        // CR was a stand-alone terminator. Process the line then
                        // fall through to append this byte to a fresh line.
                        sawCR = false
                        let line = String(decoding: lineBytes, as: UTF8.self)
                        lineBytes.removeAll(keepingCapacity: true)
                        if line.isEmpty {
                            if !dataBuffer.isEmpty {
                                let payload = dataBuffer
                                let type = eventType.isEmpty ? "snapshot" : eventType
                                dataBuffer = ""
                                await dispatch(eventType: type, eventData: payload, source: source)
                            }
                            // Always reset on frame boundary, even when the
                            // frame had no `data:` lines — otherwise a stray
                            // `event:` would leak into the next frame's type.
                            eventType = ""
                        } else if !line.hasPrefix(":") {
                            if let value = stripped(line: line, prefix: "data:") {
                                if !dataBuffer.isEmpty { dataBuffer += "\n" }
                                dataBuffer += value
                            } else if let value = stripped(line: line, prefix: "event:") {
                                eventType = value
                            }
                        }
                    }
                    lineBytes.append(byte)
                    continue
                }

                if isLineEnd {
                    sawCR = false
                    let line = String(decoding: lineBytes, as: UTF8.self)
                    lineBytes.removeAll(keepingCapacity: true)
                    if line.isEmpty {
                        if !dataBuffer.isEmpty {
                            let payload = dataBuffer
                            let type = eventType.isEmpty ? "snapshot" : eventType
                            dataBuffer = ""
                            await dispatch(eventType: type, eventData: payload, source: source)
                        }
                        // Always reset on frame boundary, even when the
                        // frame had no `data:` lines — otherwise a stray
                        // `event:` would leak into the next frame's type.
                        eventType = ""
                        continue
                    }
                    if line.hasPrefix(":") { continue } // heartbeat
                    if let value = stripped(line: line, prefix: "data:") {
                        if !dataBuffer.isEmpty { dataBuffer += "\n" }
                        dataBuffer += value
                    } else if let value = stripped(line: line, prefix: "event:") {
                        eventType = value
                    }
                    // ignore id: lines
                }
            }
        } catch {
            return
        }
    }

    private func stripped(line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let after = line.dropFirst(prefix.count)
        if after.first == " " {
            return String(after.dropFirst())
        }
        return String(after)
    }

    private func dispatch(eventType: String, eventData: String, source: String) async {
        guard let data = eventData.data(using: .utf8) else { return }
        switch eventType {
        case "snapshot":
            do {
                let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)
                await store.update(provider: provider, snapshot: snapshot, source: source)
            } catch {
                SSELog.shared.log("\(provider.rawValue) decode FAILED: \(error)")
            }
        case "auth_expired":
            // The snapshot stream already conveys `status.state == .authExpired`,
            // so no extra UI trigger is needed here. We log it so the file
            // log shows the exact moment the daemon flagged a re-login.
            SSELog.shared.log("\(provider.rawValue) auth_expired (\(source))")
        default:
            SSELog.shared.log("\(provider.rawValue) unknown event '\(eventType)' from \(source)")
        }
    }

    private func streamingSessionConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        // Idle timeout for *each request* — needs to outlast the server's
        // 10 s heartbeat with margin (we use 60 s in `request.timeoutInterval`
        // and keep this in sync).
        config.timeoutIntervalForRequest = 60
        // Allow the long-lived stream itself to run forever.
        config.timeoutIntervalForResource = TimeInterval.greatestFiniteMagnitude
        // `waitsForConnectivity = true` makes URLSession sit on a request when
        // the system reports "limited connectivity", which happens for ~tens
        // of seconds right after a Sparkle-driven app relaunch. Failing fast
        // lets us cycle through the auto fallback chain instead of getting
        // pinned in `.connecting` until the user manually re-launches.
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "token-run-menubar/0.1"]
        return config
    }
}

/// Tiny ad-hoc file logger so we can see what the menu-bar app is doing without
/// having to launch from Terminal. Writes to ~/Library/Logs/token-run-menubar.log.
final class SSELog: @unchecked Sendable {
    static let shared = SSELog()
    private let url: URL
    private let queue = DispatchQueue(label: "token-run.sselog")
    private let formatter: ISO8601DateFormatter

    private init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        url = logs.appendingPathComponent("token-run-menubar.log")
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async { [url] in
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path),
                   let handle = try? FileHandle(forWritingTo: url)
                {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }
}

/// Snapshot of the user's settings at the moment a connection attempt is made.
/// Captured by value so the actor doesn't need to await back into `@MainActor` each line.
public struct SettingsSnapshot: Sendable {
    public let claudeConnectionMode: ConnectionMode
    public let codexConnectionMode: ConnectionMode
    public let remoteURL: String
    public let loopbackURL: String
    public let claudeBearer: String
    public let codexBearer: String

    public init(
        claudeConnectionMode: ConnectionMode,
        codexConnectionMode: ConnectionMode,
        remoteURL: String,
        loopbackURL: String,
        claudeBearer: String,
        codexBearer: String)
    {
        self.claudeConnectionMode = claudeConnectionMode
        self.codexConnectionMode = codexConnectionMode
        self.remoteURL = remoteURL
        self.loopbackURL = loopbackURL
        self.claudeBearer = claudeBearer
        self.codexBearer = codexBearer
    }

    public func bearer(for provider: Provider) -> String {
        switch provider {
        case .claude: return claudeBearer
        case .codex: return codexBearer
        }
    }

    public func mode(for provider: Provider) -> ConnectionMode {
        switch provider {
        case .claude: return claudeConnectionMode
        case .codex:  return codexConnectionMode
        }
    }
}
