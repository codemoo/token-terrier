import Foundation

/// Parses a single JSONL line from a Claude Code or ChatGPT Codex session log into a `TokenEvent`.
///
/// Both providers emit one JSON object per line. We pull the token-bearing lines:
///
/// **Claude** (`~/.claude/projects/<encoded>/<session-uuid>.jsonl`)
/// - `type == "assistant"` and `message.usage` is an object.
/// - Tokens = `input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens`.
/// - Model from `message.model`. Session key from `sessionId` if present, else file path.
///
/// **Codex** (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`)
/// - `type == "event_msg"` and `payload.type == "token_count"`.
/// - Tokens = `(input_tokens − cached_input_tokens) + output_tokens + reasoning_output_tokens`.
///   `input_tokens` includes the cached prefix in the codex schema, so we subtract
///   `cached_input_tokens` to get the fresh-work portion (analogous to Claude's
///   `cache_read_input_tokens` exclusion).
/// - Session key from the file path (rollout file == one session).
public enum JSONLLineParser {
    /// Parses one trimmed JSONL line and returns a `TokenEvent` if it carries usage tokens.
    public static func parse(
        provider: Provider,
        line: Data,
        sessionFilePath: String)
        -> TokenEvent?
    {
        guard !line.isEmpty else { return nil }
        guard let any = try? JSONSerialization.jsonObject(with: line, options: []),
              let object = any as? [String: Any]
        else {
            return nil
        }
        switch provider {
        case .claude:
            return parseClaude(object: object, sessionFilePath: sessionFilePath)
        case .codex:
            return parseCodex(object: object, sessionFilePath: sessionFilePath)
        }
    }

    private static func parseClaude(object: [String: Any], sessionFilePath: String) -> TokenEvent? {
        guard let type = object["type"] as? String, type == "assistant" else { return nil }
        guard let message = object["message"] as? [String: Any] else { return nil }
        guard let usage = message["usage"] as? [String: Any] else { return nil }
        let input = (usage["input_tokens"] as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? 0
        let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        // cache_read_input_tokens is excluded from the burn-rate metric on purpose:
        // it's effectively free (~95% discount) and represents context replay rather
        // than fresh model work. Including it pushes the per-minute rate to absurd
        // values (>500k/min) on long sessions.
        let total = input + output + cacheCreate
        guard total > 0 else { return nil }
        let timestamp = parseTimestamp(object["timestamp"]) ?? Date()
        let model = message["model"] as? String
        let sessionKey = (object["sessionId"] as? String) ?? sessionFilePath
        return TokenEvent(
            provider: .claude,
            timestamp: timestamp,
            tokens: total,
            model: model,
            sessionKey: sessionKey)
    }

    private static func parseCodex(object: [String: Any], sessionFilePath: String) -> TokenEvent? {
        guard let type = object["type"] as? String, type == "event_msg" else { return nil }
        guard let payload = object["payload"] as? [String: Any] else { return nil }
        guard let payloadType = payload["type"] as? String, payloadType == "token_count" else {
            return nil
        }
        guard let info = payload["info"] as? [String: Any] else { return nil }
        let lastUsage = (info["last_token_usage"] as? [String: Any]) ?? [:]
        let input = (lastUsage["input_tokens"] as? Int) ?? 0
        let cached = (lastUsage["cached_input_tokens"] as? Int) ?? 0
        let output = (lastUsage["output_tokens"] as? Int) ?? 0
        let reasoning = (lastUsage["reasoning_output_tokens"] as? Int) ?? 0
        // Codex의 `input_tokens`는 cached prefix를 포함한 전체 입력 카운트다
        // (실제 응답 라인에서 `total_tokens == input_tokens + output_tokens` 가
        // 성립). cached 부분을 빼지 않으면 같은 컨텍스트로 던진 짧은 후속 turn
        // 한 번이 input 100k+ 로 잡혀 burn rate가 두 자릿수 배로 부풀려진다.
        // Claude의 `cache_read_input_tokens`와 의미는 동일하지만 codex는 두
        // 값을 합산해서 보고하는 게 차이. fresh 토큰만 burn rate로 보낸다.
        let nonCachedInput = max(0, input - cached)
        let total = nonCachedInput + output + reasoning
        guard total > 0 else { return nil }
        let timestamp = parseTimestamp(object["timestamp"]) ?? Date()
        return TokenEvent(
            provider: .codex,
            timestamp: timestamp,
            tokens: total,
            model: nil,
            sessionKey: sessionFilePath)
    }

    // ISO8601DateFormatter is documented as thread-safe for read use. Strict-concurrency
    // doesn't know that, so we mark these as `nonisolated(unsafe)` and only configure them
    // at init time.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoFormatterNoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseTimestamp(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        if let d = isoFormatter.date(from: s) { return d }
        return isoFormatterNoFractional.date(from: s)
    }
}
