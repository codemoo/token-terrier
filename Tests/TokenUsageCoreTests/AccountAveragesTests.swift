import XCTest
@testable import TokenUsageCore

final class AccountAveragesTests: XCTestCase {
    private func mkAccount(status: String, five: Double?, seven: Double?, fiveReset: String? = nil, sevenReset: String? = nil) -> AccountUsage {
        AccountUsage(
            number: 1,
            email: "a@x",
            active: true,
            status: status,
            fiveHour: five.map { AccountWindow(usedPct: $0, resetsAt: fiveReset) },
            sevenDay: seven.map { AccountWindow(usedPct: $0, resetsAt: sevenReset) })
    }

    func test_average_ignoresNonOkAndNilWindow() {
        let accts = [
            mkAccount(status: "ok", five: 0.4, seven: 0.6),
            mkAccount(status: "ok", five: 0.2, seven: nil),
            mkAccount(status: "token_expired", five: 0.9, seven: 0.9), // 제외
        ]
        XCTAssertEqual(AccountAverages.fiveHour(accts)!, 0.3, accuracy: 1e-9) // (0.4+0.2)/2
        XCTAssertEqual(AccountAverages.sevenDay(accts)!, 0.6, accuracy: 1e-9) // 0.6 하나만
    }

    func test_average_nilWhenNoEligible() {
        XCTAssertNil(AccountAverages.fiveHour([mkAccount(status: "token_expired", five: 0.5, seven: 0.5)]))
        XCTAssertNil(AccountAverages.fiveHour([]))
    }

    func test_average_clampsOutOfRangeWindowValues() {
        let accts = [
            mkAccount(status: "ok", five: -1.0, seven: nil),
            mkAccount(status: "ok", five: 1.5, seven: nil),
        ]
        XCTAssertEqual(AccountAverages.fiveHour(accts)!, 0.5, accuracy: 1e-9)
    }

    func test_window_usesEarliestResetFromEligibleAccounts() {
        let now = SnapshotDateFormatter.date(from: "2026-07-04T00:00:00.000Z")!
        let accts = [
            mkAccount(status: "ok", five: 0.4, seven: nil, fiveReset: "2026-07-04T03:00:00.000Z"),
            mkAccount(status: "ok", five: 0.2, seven: nil, fiveReset: "2026-07-04T01:00:00.000Z"),
            mkAccount(status: "token_expired", five: 1.0, seven: nil, fiveReset: "2026-07-04T00:30:00.000Z"),
        ]
        let window = AccountAverages.fiveHourWindow(accts, now: now)!
        XCTAssertEqual(window.usedPct, 0.3, accuracy: 1e-9)
        XCTAssertEqual(window.resetsAt, "2026-07-04T01:00:00.000Z")
        XCTAssertEqual(window.remainingSeconds, 3_600)
    }
}
