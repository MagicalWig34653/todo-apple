import XCTest
@testable import TodoCore

final class DecodingTests: XCTestCase {
    func testHealthDecodes() throws {
        let decoded = try JSONDecoder().decode(HealthResponse.self, from: Data(#"{"status":"ok"}"#.utf8))
        XCTAssertEqual(decoded, HealthResponse(status: "ok"))
    }
}
