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
}
