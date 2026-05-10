import Foundation
import Testing
@testable import TokenUsageCore

@Suite("usage normalizers")
struct NormalizerTests {
    private let producer = ProducerInfo(id: "test-producer", timeZone: "Asia/Seoul")
    private let now = SnapshotDateFormatter.date(from: "2026-04-27T05:00:00Z") ?? Date(timeIntervalSince1970: 1_777_264_400)

    @Test("normalizes Claude usage fixture")
    func normalizesClaudeFixture() throws {
        let response = try decodeFixture(ClaudeUsageResponse.self, name: "claude_usage")
        let credential = OAuthCredential(
            provider: .claude,
            accessToken: "access",
            refreshToken: "refresh",
            rateLimitTier: "max")
        let snapshot = UsageNormalizer.normalizeClaude(response, credential: credential, seq: 7, producer: producer, now: now)
        #expect(snapshot.provider == .claude)
        #expect(snapshot.seq == 7)
        #expect(snapshot.rolling5h.usedPct == 0.21)
        #expect(snapshot.weekly.usedPct == 0.25)
        #expect(snapshot.quotaWindows == [
            QuotaWindow(label: "sonnet", scope: "weekly", usedPct: 0.01, resetsAt: "2026-05-02T18:00:00.000Z"),
        ])
        #expect(snapshot.credits == nil)
        #expect(snapshot.extras.rateLimitTier == "max")
        #expect(snapshot.status.state == .ok)
        #expect(snapshot.burnRatePerMinute == 0)
        #expect(snapshot.burnState == "idle")
    }

    @Test("normalizes Codex raw snake_case fixture")
    func normalizesCodexRawFixture() throws {
        let response = try decodeFixture(CodexUsageResponse.self, name: "codex_usage_raw")
        let credential = OAuthCredential(provider: .codex, accessToken: "access", refreshToken: "refresh")
        let snapshot = UsageNormalizer.normalizeCodex(response, credential: credential, seq: 3, producer: producer, now: now)
        #expect(snapshot.provider == .codex)
        #expect(snapshot.rolling5h.usedPct == 0)
        #expect(snapshot.weekly.usedPct == 0.09)
        #expect(snapshot.credits?.remaining == 863.9)
        #expect(snapshot.extras.loginMethod == "pro")
    }

    @Test("normalizes Codex camelCase fixture")
    func normalizesCodexCamelFixture() throws {
        let response = try decodeFixture(CodexUsageResponse.self, name: "codex_usage_camel")
        let credential = OAuthCredential(provider: .codex, accessToken: "access", refreshToken: "refresh")
        let snapshot = UsageNormalizer.normalizeCodex(response, credential: credential, seq: 4, producer: producer, now: now)
        #expect(snapshot.rolling5h.resetsAt == "2026-04-27T10:01:35.000Z")
        #expect(snapshot.weekly.resetsAt == "2026-04-28T18:18:24.000Z")
        #expect(snapshot.credits == Credits(remaining: 863.9, updatedAt: "2026-04-27T05:02:00.000Z"))
        #expect(snapshot.extras.loginMethod == "pro")
        #expect(snapshot.extras.accountEmail == "person@example.com")
    }

    private func decodeFixture<T: Decodable>(_ type: T.Type, name: String) throws -> T {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }
}
