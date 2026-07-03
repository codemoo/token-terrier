import XCTest
@testable import TokenUsageCore

final class AccountUsageDecodeTests: XCTestCase {
    func test_accountUsage_decodesTokenFields() throws {
        let json = #"{"number":1,"email":"a@x","active":true,"status":"ok","tokens_per_hour":1234.5,"total_tokens":99}"#
        let a = try JSONDecoder().decode(AccountUsage.self, from: Data(json.utf8))
        XCTAssertEqual(a.tokensPerHour, 1234.5)
        XCTAssertEqual(a.totalTokens, 99)
    }

    func test_accountUsage_tokenFieldsOptionalMissing() throws {
        let json = #"{"number":1,"email":"a@x","active":true,"status":"ok"}"#
        let a = try JSONDecoder().decode(AccountUsage.self, from: Data(json.utf8))
        XCTAssertNil(a.tokensPerHour)
        XCTAssertNil(a.totalTokens)
    }
}
