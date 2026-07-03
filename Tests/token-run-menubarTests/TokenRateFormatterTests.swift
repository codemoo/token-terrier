import XCTest
@testable import token_run_menubar

final class TokenRateFormatterTests: XCTestCase {
    func test_perHourLabel() {
        XCTAssertEqual(TokenRate.perHourLabel(920), "920 tok/h")
        XCTAssertEqual(TokenRate.perHourLabel(1234), "1.2k tok/h")
        XCTAssertEqual(TokenRate.perHourLabel(3_400_000), "3.4M tok/h")
        XCTAssertEqual(TokenRate.perHourLabel(0), "0 tok/h")
    }
}
