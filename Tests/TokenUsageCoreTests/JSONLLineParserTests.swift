import Foundation
import Testing
@testable import TokenUsageCore

@Suite("jsonl line parser")
struct JSONLLineParserTests {
    @Test("parses Claude assistant usage line with cache and reports total tokens")
    func parsesClaudeAssistantLine() throws {
        let json = #"""
        {"type":"assistant","timestamp":"2026-04-25T09:18:34.622Z","sessionId":"f044e139-6921-46a8-895c-02828645709b","message":{"model":"claude-opus-4-7","usage":{"input_tokens":6,"cache_creation_input_tokens":12935,"cache_read_input_tokens":14816,"output_tokens":199}}}
        """#
        let event = JSONLLineParser.parse(
            provider: .claude,
            line: Data(json.utf8),
            sessionFilePath: "/tmp/example.jsonl")
        try #require(event != nil)
        #expect(event?.provider == .claude)
        // input + output + cache_creation. cache_read excluded (replay, not work).
        #expect(event?.tokens == 6 + 199 + 12935)
        #expect(event?.model == "claude-opus-4-7")
        #expect(event?.sessionKey == "f044e139-6921-46a8-895c-02828645709b")
    }

    @Test("ignores non-assistant Claude lines")
    func ignoresClaudeUserLine() {
        let json = #"{"type":"user","message":{"content":"hi"}}"#
        let event = JSONLLineParser.parse(
            provider: .claude,
            line: Data(json.utf8),
            sessionFilePath: "/tmp/example.jsonl")
        #expect(event == nil)
    }

    @Test("ignores Claude assistant lines without usage")
    func ignoresClaudeAssistantWithoutUsage() {
        let json = #"{"type":"assistant","message":{"model":"x"}}"#
        let event = JSONLLineParser.parse(
            provider: .claude,
            line: Data(json.utf8),
            sessionFilePath: "/tmp/example.jsonl")
        #expect(event == nil)
    }

    @Test("parses Codex token_count event_msg using last_token_usage.total_tokens")
    func parsesCodexTokenCount() throws {
        let json = #"""
        {"timestamp":"2026-04-26T17:31:23.023Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":16074,"cached_input_tokens":0,"output_tokens":613,"reasoning_output_tokens":516,"total_tokens":16687},"last_token_usage":{"input_tokens":16074,"cached_input_tokens":0,"output_tokens":613,"reasoning_output_tokens":516,"total_tokens":16687},"model_context_window":258400},"rate_limits":null}}
        """#
        let event = JSONLLineParser.parse(
            provider: .codex,
            line: Data(json.utf8),
            sessionFilePath: "/tmp/rollout-1.jsonl")
        try #require(event != nil)
        #expect(event?.provider == .codex)
        // fresh = input(16074) + output(613) + reasoning(516). cached_input(0) excluded.
        #expect(event?.tokens == 16074 + 613 + 516)
        #expect(event?.sessionKey == "/tmp/rollout-1.jsonl")
    }

    @Test("Codex token_count subtracts cached_input from input for fresh tokens")
    func parsesCodexTokenCountWithCachedPrefix() throws {
        // 실제 사용 사례: 같은 컨텍스트로 짧은 후속 turn — input(104055)에 cached(103296)이
        // 모두 포함되어 있고, 새 모델 작업은 input - cached + output + reasoning 만큼만.
        // cached를 안 빼면 burn rate가 100배 부풀려진다.
        let json = #"""
        {"timestamp":"2026-04-27T15:32:40.927Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":104055,"cached_input_tokens":103296,"output_tokens":384,"reasoning_output_tokens":223,"total_tokens":104439}}}}
        """#
        let event = JSONLLineParser.parse(
            provider: .codex,
            line: Data(json.utf8),
            sessionFilePath: "/tmp/rollout-1.jsonl")
        try #require(event != nil)
        let nonCachedInput = 104055 - 103296
        #expect(event?.tokens == nonCachedInput + 384 + 223) // 759 + 384 + 223 = 1366
    }

    @Test("ignores Codex non-token-count event_msg")
    func ignoresCodexOtherEvent() {
        let json = #"{"timestamp":"x","type":"event_msg","payload":{"type":"something_else","info":{}}}"#
        let event = JSONLLineParser.parse(
            provider: .codex,
            line: Data(json.utf8),
            sessionFilePath: "/tmp/rollout-1.jsonl")
        #expect(event == nil)
    }

    @Test("returns nil on garbage input")
    func nilOnGarbage() {
        let event = JSONLLineParser.parse(
            provider: .claude,
            line: Data("not json".utf8),
            sessionFilePath: "/tmp/x.jsonl")
        #expect(event == nil)
    }
}
