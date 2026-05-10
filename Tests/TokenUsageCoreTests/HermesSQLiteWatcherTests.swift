import Foundation
import Logging
import SQLite3
import Testing
@testable import TokenUsageCore

@Suite("Hermes SQLite watcher")
struct HermesSQLiteWatcherTests {
    @Test("baselines existing rows, then emits provider fresh-token deltas")
    func baselinesThenEmitsFreshTokenDeltas() async throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        try createHermesDatabase(at: dbURL)
        try insertSession(
            at: dbURL,
            id: "codex-session",
            billingProvider: "openai-codex",
            model: "gpt-5.5",
            input: 100,
            output: 10,
            reasoning: 5,
            cacheRead: 1_000)
        try insertSession(
            at: dbURL,
            id: "claude-session",
            billingProvider: "anthropic",
            model: "claude-opus-4-7",
            input: 20,
            output: 4,
            reasoning: 1,
            cacheRead: 500)
        try insertSession(
            at: dbURL,
            id: "ignored-session",
            billingProvider: "local",
            model: "other",
            input: 1,
            output: 1,
            reasoning: 1)

        let recorder = EventRecorder()
        let watcher = HermesSQLiteWatcher(
            config: .init(dbURL: dbURL, pollInterval: 60),
            logger: Logger(label: "test.hermes-sqlite"))
        { event in
            await recorder.append(event)
        }

        await watcher.tick()
        let baselineEvents = await recorder.snapshot()
        #expect(baselineEvents.isEmpty)

        try updateSession(
            at: dbURL,
            id: "codex-session",
            input: 180,
            output: 30,
            reasoning: 9,
            cacheRead: 99_999,
            cacheWrite: 88_888)
        try updateSession(
            at: dbURL,
            id: "claude-session",
            input: 35,
            output: 8,
            reasoning: 2,
            cacheRead: 10_000,
            cacheWrite: 9_000)
        try updateSession(
            at: dbURL,
            id: "ignored-session",
            input: 10_000,
            output: 10_000,
            reasoning: 10_000)

        await watcher.tick()
        let events = await recorder.snapshot()
        #expect(events.count == 2)

        let codex = try #require(events.first { $0.sessionKey == "codex-session" })
        let expectedCodexDelta = 104
        #expect(codex.provider == .codex)
        #expect(codex.model == "gpt-5.5")
        #expect(codex.tokens == expectedCodexDelta)

        let claude = try #require(events.first { $0.sessionKey == "claude-session" })
        let expectedClaudeDelta = 20
        #expect(claude.provider == .claude)
        #expect(claude.tokens == expectedClaudeDelta)

        try updateSession(
            at: dbURL,
            id: "codex-session",
            input: 180,
            output: 30,
            reasoning: 9,
            cacheRead: 123_456,
            cacheWrite: 654_321)
        await watcher.tick()
        let afterCacheOnlyUpdate = await recorder.snapshot()
        #expect(afterCacheOnlyUpdate.count == 2)
    }

    @Test("removes ended sessions after final delta")
    func removesEndedSessionsAfterFinalDelta() async throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        try createHermesDatabase(at: dbURL)
        try insertSession(
            at: dbURL,
            id: "ending-session",
            billingProvider: "openai-codex",
            model: "gpt-5.5",
            input: 10,
            output: 5,
            reasoning: 1)

        let recorder = EventRecorder()
        let watcher = HermesSQLiteWatcher(
            config: .init(dbURL: dbURL, pollInterval: 60),
            logger: Logger(label: "test.hermes-sqlite"))
        { event in
            await recorder.append(event)
        }

        await watcher.tick()
        try updateSession(
            at: dbURL,
            id: "ending-session",
            input: 20,
            output: 7,
            reasoning: 3,
            endedAt: 1_777_318_383)

        await watcher.tick()
        let events = await recorder.snapshot()
        let expectedFinalDelta = 14
        #expect(events.count == 1)
        #expect(events.first?.tokens == expectedFinalDelta)

        try updateSession(
            at: dbURL,
            id: "ending-session",
            input: 30,
            output: 10,
            reasoning: 5,
            endedAt: 1_777_318_383)
        await watcher.tick()
        let afterEndedUpdate = await recorder.snapshot()
        #expect(afterEndedUpdate.count == 1)
    }

    @Test("missing database is a silent noop")
    func missingDatabaseIsNoop() async {
        let dbURL = temporaryDatabaseURL()
        try? FileManager.default.removeItem(at: dbURL)
        let recorder = EventRecorder()
        let watcher = HermesSQLiteWatcher(
            config: .init(dbURL: dbURL, pollInterval: 60),
            logger: Logger(label: "test.hermes-sqlite"))
        { event in
            await recorder.append(event)
        }

        await watcher.tick()
        let events = await recorder.snapshot()
        #expect(events.isEmpty)
    }
}

private actor EventRecorder {
    private var events: [TokenEvent] = []

    func append(_ event: TokenEvent) {
        events.append(event)
    }

    func snapshot() -> [TokenEvent] {
        events
    }
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("tokenterrier-hermes-\(UUID().uuidString).db")
}

private func createHermesDatabase(at url: URL) throws {
    try withDatabase(at: url) { db in
        try execute(db, """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            user_id TEXT,
            model TEXT,
            model_config TEXT,
            system_prompt TEXT,
            parent_session_id TEXT,
            started_at REAL NOT NULL,
            ended_at REAL,
            end_reason TEXT,
            message_count INTEGER DEFAULT 0,
            tool_call_count INTEGER DEFAULT 0,
            input_tokens INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0,
            cache_write_tokens INTEGER DEFAULT 0,
            reasoning_tokens INTEGER DEFAULT 0,
            billing_provider TEXT,
            billing_base_url TEXT,
            billing_mode TEXT,
            estimated_cost_usd REAL,
            actual_cost_usd REAL,
            cost_status TEXT,
            cost_source TEXT,
            pricing_version TEXT,
            title TEXT,
            api_call_count INTEGER DEFAULT 0,
            FOREIGN KEY (parent_session_id) REFERENCES sessions(id)
        );
        """)
    }
}

private func insertSession(
    at url: URL,
    id: String,
    billingProvider: String,
    model: String,
    input: Int64,
    output: Int64,
    reasoning: Int64,
    cacheRead: Int64 = 0,
    cacheWrite: Int64 = 0,
    endedAt: Double? = nil) throws
{
    try withDatabase(at: url) { db in
        let sql = """
        INSERT INTO sessions (
            id, source, user_id, model, started_at, ended_at, billing_provider,
            input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens
        )
        VALUES (?, 'discord', 'test-user', ?, 1777313183, ?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(db, sql) { statement in
            try bindText(statement, 1, id)
            try bindText(statement, 2, model)
            try bindOptionalDouble(statement, 3, endedAt)
            try bindText(statement, 4, billingProvider)
            try bindInt64(statement, 5, input)
            try bindInt64(statement, 6, output)
            try bindInt64(statement, 7, cacheRead)
            try bindInt64(statement, 8, cacheWrite)
            try bindInt64(statement, 9, reasoning)
            try stepDone(statement, db: db)
        }
    }
}

private func updateSession(
    at url: URL,
    id: String,
    input: Int64,
    output: Int64,
    reasoning: Int64,
    cacheRead: Int64 = 0,
    cacheWrite: Int64 = 0,
    endedAt: Double? = nil) throws
{
    try withDatabase(at: url) { db in
        let sql = """
        UPDATE sessions
        SET input_tokens = ?, output_tokens = ?, reasoning_tokens = ?,
            cache_read_tokens = ?, cache_write_tokens = ?, ended_at = ?
        WHERE id = ?;
        """
        try withStatement(db, sql) { statement in
            try bindInt64(statement, 1, input)
            try bindInt64(statement, 2, output)
            try bindInt64(statement, 3, reasoning)
            try bindInt64(statement, 4, cacheRead)
            try bindInt64(statement, 5, cacheWrite)
            try bindOptionalDouble(statement, 6, endedAt)
            try bindText(statement, 7, id)
            try stepDone(statement, db: db)
        }
    }
}

private func withDatabase<T>(at url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
    var database: OpaquePointer?
    let code = sqlite3_open(url.path, &database)
    guard code == SQLITE_OK, let db = database else {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "no database handle"
        if let database { sqlite3_close(database) }
        throw SQLiteTestError.operation("open", code, message)
    }
    defer { sqlite3_close(db) }
    return try body(db)
}

private func withStatement<T>(
    _ db: OpaquePointer,
    _ sql: String,
    _ body: (OpaquePointer) throws -> T) throws -> T
{
    var statement: OpaquePointer?
    let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard code == SQLITE_OK, let statement else {
        throw SQLiteTestError.operation("prepare", code, String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    return try body(statement)
}

private func execute(_ db: OpaquePointer, _ sql: String) throws {
    var rawError: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(db, sql, nil, nil, &rawError)
    guard code == SQLITE_OK else {
        let message = rawError.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
        if let rawError { sqlite3_free(rawError) }
        throw SQLiteTestError.operation("exec", code, message)
    }
}

private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) throws {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let code = value.withCString { pointer in
        sqlite3_bind_text(statement, index, pointer, -1, transient)
    }
    guard code == SQLITE_OK else {
        throw SQLiteTestError.operation("bind_text", code, "index \(index)")
    }
}

private func bindInt64(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) throws {
    let code = sqlite3_bind_int64(statement, index, value)
    guard code == SQLITE_OK else {
        throw SQLiteTestError.operation("bind_int64", code, "index \(index)")
    }
}

private func bindOptionalDouble(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) throws {
    let code: Int32
    if let value {
        code = sqlite3_bind_double(statement, index, value)
    } else {
        code = sqlite3_bind_null(statement, index)
    }
    guard code == SQLITE_OK else {
        throw SQLiteTestError.operation("bind_double", code, "index \(index)")
    }
}

private func stepDone(_ statement: OpaquePointer, db: OpaquePointer) throws {
    let code = sqlite3_step(statement)
    guard code == SQLITE_DONE else {
        throw SQLiteTestError.operation("step", code, String(cString: sqlite3_errmsg(db)))
    }
}

private enum SQLiteTestError: Error, CustomStringConvertible {
    case operation(String, Int32, String)

    var description: String {
        switch self {
        case let .operation(name, code, message):
            return "\(name) failed with SQLite code \(code): \(message)"
        }
    }
}
