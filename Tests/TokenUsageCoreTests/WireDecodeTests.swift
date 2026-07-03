import Foundation
import XCTest
@testable import TokenUsageCore

final class WireDecodeTests: XCTestCase {
    func test_real_wire_payload_decodes() throws {
        let payload = #"""
        {"burn_rate_per_min":134609,"burn_state":"rocket","extras":{"extra_rate_windows":[],"rate_limit_tier":"default_claude_max_20x"},"generated_at_utc":"2026-04-27T06:26:38.129Z","producer_id":"mac-mini.local","producer_tz":"Asia/Seoul","provider":"claude","quota_windows":[{"label":"sonnet","resets_at":"2026-05-02T18:00:01.316Z","scope":"weekly","used_pct":0.01}],"rolling_5h":{"remaining_seconds":2602,"resets_at":"2026-04-27T07:10:00.316Z","used_pct":0.5},"schema":1,"seq":110,"status":{"data_source":"api+jsonl","stale":false,"state":"ok"},"today_sessions":2,"today_total_tokens":3019891,"weekly":{"remaining_seconds":473602,"resets_at":"2026-05-02T18:00:00.316Z","used_pct":0.29}}
        """#
        let data = payload.data(using: .utf8)!
        let snap = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(snap.provider, .claude)
        XCTAssertEqual(snap.seq, 110)
    }

    func testDecodesClaudeAccounts() throws {
        let json = """
        {"schema":1,"seq":1,"generated_at_utc":"2026-07-03T09:00:00.000Z",
         "producer_id":"h","producer_tz":"UTC","provider":"claude",
         "burn_rate_per_min":0,"burn_state":"idle","today_total_tokens":0,"today_sessions":0,
         "rolling_5h":{"used_pct":0,"remaining_seconds":0,"resets_at":null},
         "weekly":{"used_pct":0,"remaining_seconds":0,"resets_at":null},
         "quota_windows":[],"credits":null,
         "extras":{"login_method":null,"account_email":null,"rate_limit_tier":null,"extra_rate_windows":[]},
         "status":{"state":"ok","data_source":"api_only","stale":false},
         "accounts":[
           {"number":1,"email":"a@b.com","active":false,"status":"ok",
            "five_hour":{"used_pct":0.07,"resets_at":"2026-07-03T12:00:00.000Z"},
            "seven_day":{"used_pct":0.29,"resets_at":null}},
           {"number":2,"email":"c@d.com","active":true,"status":"api_key",
            "five_hour":null,"seven_day":null}],
         "accounts_updated_at":"2026-07-03T08:55:00.000Z"}
        """
        let snap = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.accounts?.count, 2)
        XCTAssertEqual(snap.accounts?[0].email, "a@b.com")
        XCTAssertEqual(snap.accounts?[0].fiveHour?.usedPct, 0.07)
        XCTAssertEqual(snap.accounts?[1].status, "api_key")
        XCTAssertNil(snap.accounts?[1].fiveHour)
        XCTAssertEqual(snap.accountsUpdatedAt, "2026-07-03T08:55:00.000Z")
    }

    func testDecodesSnapshotWithoutAccounts() throws {
        let json = """
        {"schema":1,"seq":1,"generated_at_utc":"2026-07-03T09:00:00.000Z",
         "producer_id":"h","producer_tz":"UTC","provider":"claude",
         "burn_rate_per_min":0,"burn_state":"idle","today_total_tokens":0,"today_sessions":0,
         "rolling_5h":{"used_pct":0,"remaining_seconds":0,"resets_at":null},
         "weekly":{"used_pct":0,"remaining_seconds":0,"resets_at":null},
         "quota_windows":[],"credits":null,
         "extras":{"login_method":null,"account_email":null,"rate_limit_tier":null,"extra_rate_windows":[]},
         "status":{"state":"ok","data_source":"api_only","stale":false}}
        """
        let snap = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snap.accounts)
        XCTAssertNil(snap.accountsUpdatedAt)
    }

    func testAccountStatusLabel() {
        XCTAssertNil(accountStatusLabel("ok"))
        XCTAssertEqual(accountStatusLabel("api_key"), "할당량 없음")
        XCTAssertEqual(accountStatusLabel("token_expired"), "토큰 만료")
        XCTAssertEqual(accountStatusLabel("keychain_unavailable"), "키체인 잠김")
        XCTAssertEqual(accountStatusLabel("no_credentials"), "자격증명 없음")
        XCTAssertEqual(accountStatusLabel("unavailable"), "조회 실패")
        XCTAssertEqual(accountStatusLabel("something_new"), "조회 실패")
    }
}
