import Foundation
import Logging
import SQLite3

/// Polls Hermes' local SQLite state database and emits delta token events for
/// provider-backed sessions. Hermes stores cumulative per-session token counts,
/// so this watcher keeps an in-memory baseline by session id and emits only
/// positive fresh-token deltas observed after startup.
public actor HermesSQLiteWatcher {
    public typealias Sink = @Sendable (TokenEvent) async -> Void

    public struct Config: Sendable {
        public let dbURL: URL
        public let pollInterval: TimeInterval

        public init(dbURL: URL, pollInterval: TimeInterval = 30) {
            self.dbURL = dbURL
            self.pollInterval = pollInterval
        }

        /// Default Hermes state database: `~/.hermes/state.db`.
        public static func userDefaults() -> Config {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Config(dbURL: home.appendingPathComponent(".hermes/state.db"))
        }
    }

    private struct SessionRow {
        let id: String
        let provider: Provider?
        let model: String?
        let freshTokens: Int
        let hasEnded: Bool
    }

    private let config: Config
    private let logger: Logger
    private let sink: Sink
    private var lastSeenFreshTokens: [String: Int] = [:]
    private var hasCompletedInitialTick = false
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

    /// Stops the loop and waits for any in-flight SQLite read to finish.
    public func stop() async {
        let inflight = task
        inflight?.cancel()
        task = nil
        await inflight?.value
    }

    /// One database scan + dispatch pass. Visible for tests.
    public func tick() async {
        guard let rows = readSessionRows() else { return }

        var activeSessionIDs = Set<String>()
        for row in rows {
            if row.hasEnded {
                if let previous = lastSeenFreshTokens[row.id] {
                    await dispatchDelta(for: row, previous: previous)
                    lastSeenFreshTokens.removeValue(forKey: row.id)
                }
                continue
            }

            activeSessionIDs.insert(row.id)
            if let previous = lastSeenFreshTokens[row.id] {
                await dispatchDelta(for: row, previous: previous)
                lastSeenFreshTokens[row.id] = row.freshTokens
            } else {
                lastSeenFreshTokens[row.id] = row.freshTokens
                if hasCompletedInitialTick {
                    await dispatchDelta(for: row, previous: 0)
                }
            }
        }

        lastSeenFreshTokens = lastSeenFreshTokens.filter { activeSessionIDs.contains($0.key) }
        hasCompletedInitialTick = true
    }

    private func dispatchDelta(for row: SessionRow, previous: Int) async {
        let delta = row.freshTokens - previous
        guard delta > 0, let provider = row.provider else { return }
        await sink(TokenEvent(
            provider: provider,
            timestamp: Date(),
            tokens: delta,
            model: row.model,
            sessionKey: row.id))
    }

    private func readSessionRows() -> [SessionRow]? {
        guard FileManager.default.fileExists(atPath: config.dbURL.path) else {
            return nil
        }

        var connection: OpaquePointer?
        let openCode = sqlite3_open_v2(config.dbURL.path, &connection, SQLITE_OPEN_READONLY, nil)
        guard openCode == SQLITE_OK, let db = connection else {
            if let connection {
                logger.warning("Unable to open Hermes SQLite database", metadata: [
                    "path": "\(config.dbURL.path)",
                    "code": "\(openCode)",
                    "message": "\(String(cString: sqlite3_errmsg(connection)))",
                ])
                sqlite3_close(connection)
            }
            return nil
        }
        defer { sqlite3_close(db) }

        // Keep the connection read-only even if Hermes is actively writing WAL frames.
        sqlite3_exec(db, "PRAGMA query_only = ON;", nil, nil, nil)

        let sql = """
        SELECT id, billing_provider, model, input_tokens, output_tokens, reasoning_tokens, ended_at
        FROM sessions
        ORDER BY id;
        """
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            logger.warning("Unable to prepare Hermes session query", metadata: [
                "path": "\(config.dbURL.path)",
                "code": "\(prepareCode)",
                "message": "\(String(cString: sqlite3_errmsg(db)))",
            ])
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var rows: [SessionRow] = []
        while true {
            let stepCode = sqlite3_step(statement)
            if stepCode == SQLITE_DONE {
                return rows
            }
            guard stepCode == SQLITE_ROW else {
                logger.warning("Unable to read Hermes session rows", metadata: [
                    "path": "\(config.dbURL.path)",
                    "code": "\(stepCode)",
                    "message": "\(String(cString: sqlite3_errmsg(db)))",
                ])
                return nil
            }

            guard let id = columnString(statement, 0) else { continue }
            let billingProvider = columnString(statement, 1)
            let model = columnString(statement, 2)
            let input = sqlite3_column_int64(statement, 3)
            let output = sqlite3_column_int64(statement, 4)
            let reasoning = sqlite3_column_int64(statement, 5)
            let hasEnded = sqlite3_column_type(statement, 6) != SQLITE_NULL

            rows.append(SessionRow(
                id: id,
                provider: provider(from: billingProvider),
                model: model,
                freshTokens: freshTokens(input: input, output: output, reasoning: reasoning),
                hasEnded: hasEnded))
        }
    }

    private func columnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: UnsafeRawPointer(raw).assumingMemoryBound(to: CChar.self))
    }

    private func freshTokens(input: Int64, output: Int64, reasoning: Int64) -> Int {
        var total: Int64 = 0
        for value in [input, output, reasoning] {
            let tokens = max(0, value)
            guard Int64.max - total >= tokens else { return Int.max }
            total += tokens
        }
        return total > Int64(Int.max) ? Int.max : Int(total)
    }

    private func provider(from billingProvider: String?) -> Provider? {
        guard let billingProvider else { return nil }
        let normalized = billingProvider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if normalized.contains("codex") {
            return .codex
        }
        if normalized.contains("anthropic") {
            return .claude
        }
        return nil
    }
}
