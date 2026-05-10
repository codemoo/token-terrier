import Foundation
import Logging

/// Polls Claude and Codex local JSONL session directories on a fixed interval and dispatches
/// any new `TokenEvent`s to a callback. Uses an in-memory per-file cursor (offset/mtime/size)
/// so a single file is read incrementally; truncation/rotation resets the cursor.
public actor JSONLPoller {
    public typealias Sink = @Sendable (TokenEvent) async -> Void

    public struct Config: Sendable {
        public let claudeRoot: URL
        public let codexRoot: URL
        public let pollInterval: TimeInterval
        public let maxLineBytes: Int

        public init(
            claudeRoot: URL,
            codexRoot: URL,
            pollInterval: TimeInterval = 2.0,
            maxLineBytes: Int = 8 * 1024 * 1024)
        {
            self.claudeRoot = claudeRoot
            self.codexRoot = codexRoot
            self.pollInterval = pollInterval
            self.maxLineBytes = maxLineBytes
        }

        /// Defaults for this user's home: `~/.claude/projects` + `~/.codex/sessions`.
        public static func userDefaults() -> Config {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Config(
                claudeRoot: home.appendingPathComponent(".claude/projects", isDirectory: true),
                codexRoot: home.appendingPathComponent(".codex/sessions", isDirectory: true))
        }
    }

    private struct FileCursor {
        var size: Int64
        var inode: UInt64
        var offset: UInt64
        var partial: Data
    }

    private let config: Config
    private let logger: Logger
    private let sink: Sink
    private var cursors: [URL: FileCursor] = [:]
    private var task: Task<Void, Never>?

    public init(config: Config, logger: Logger, sink: @escaping Sink) {
        self.config = config
        self.logger = logger
        self.sink = sink
    }

    /// Starts the background polling loop. Idempotent.
    public func start() {
        if task != nil { return }
        let interval = config.pollInterval
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Stops the loop and waits for the in-flight tick to drain. Safe to
    /// call repeatedly. The `await task.value` is what makes a daemon-wide
    /// graceful shutdown actually graceful — without it, a long upstream
    /// JSONL read could be torn down mid-line.
    public func stop() async {
        let inflight = task
        inflight?.cancel()
        task = nil
        await inflight?.value
    }

    /// One scan + dispatch pass. Visible for tests.
    public func tick() async {
        let claudeFiles = enumerateJSONL(under: config.claudeRoot) ?? []
        let codexFiles = enumerateJSONL(under: config.codexRoot) ?? []
        // Drop cursors for files that no longer exist; otherwise the
        // dictionary leaks one entry for every session file the user has
        // ever opened and the daemon's memory footprint grows without
        // bound across long runs.
        let live = Set(claudeFiles).union(codexFiles)
        cursors = cursors.filter { live.contains($0.key) }
        for url in claudeFiles {
            await readNew(provider: .claude, url: url)
        }
        for url in codexFiles {
            await readNew(provider: .codex, url: url)
        }
    }

    private func enumerateJSONL(under root: URL) -> [URL]? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return nil }
        var out: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            out.append(url)
        }
        return out
    }

    private func readNew(provider: Provider, url: URL) async {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        // First time we see a file: start at EOF so we only ingest *new* lines added
        // after the daemon started. Historic lines (potentially millions of tokens
        // from past sessions) would otherwise burst the burn-rate window on startup.
        var cursor = cursors[url] ?? FileCursor(
            size: size, inode: inode, offset: UInt64(size), partial: Data())
        if cursor.inode != inode || cursor.size > size {
            // Rotation/truncation: also resume from EOF for the same reason.
            cursor = FileCursor(size: size, inode: inode, offset: UInt64(size), partial: Data())
        }
        if size <= Int64(cursor.offset) {
            cursors[url] = cursor
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            cursors[url] = cursor
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: cursor.offset)
        } catch {
            cursors[url] = cursor
            return
        }
        let data = handle.readDataToEndOfFile()
        cursor.offset += UInt64(data.count)
        cursor.size = size
        cursor.inode = inode

        var buffer = cursor.partial + data
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<nl]
            buffer = buffer[(nl + 1)...]
            let lineCopy = Data(line)
            await dispatchLine(provider: provider, line: lineCopy, url: url)
        }
        if buffer.count > config.maxLineBytes {
            // pathological line; drop and resync
            cursor.partial = Data()
        } else {
            cursor.partial = Data(buffer)
        }
        cursors[url] = cursor
    }

    private func dispatchLine(provider: Provider, line: Data, url: URL) async {
        guard let event = JSONLLineParser.parse(
            provider: provider,
            line: line,
            sessionFilePath: url.path)
        else { return }
        await sink(event)
    }
}
