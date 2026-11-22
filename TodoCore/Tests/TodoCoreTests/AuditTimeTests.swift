import XCTest
@testable import TodoCore

/// Card 330C57F8, Apple parity: audit timestamps use the same exact Berlin form as the PWA tooltip, and tasks keep the
/// server's createdAt/updatedAt (absent on older servers).
final class AuditTimeTests: XCTestCase {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testExactUsesBerlinWallClockAndOffset() {
        XCTAssertEqual(AuditTime.exact(date("2026-11-22T09:18:17Z")), "22.11.2026, 10:18:17 GMT+1")
        XCTAssertEqual(AuditTime.exact(date("2026-07-01T10:00:05Z")), "01.07.2026, 12:00:05 GMT+2")
    }

    func testExactAcrossTheSpringClockChange() {
        XCTAssertEqual(AuditTime.exact(date("2026-03-29T00:30:00Z")), "29.03.2026, 01:30:00 GMT+1")
        XCTAssertEqual(AuditTime.exact(date("2026-03-29T01:30:00Z")), "29.03.2026, 03:30:00 GMT+2")
    }

    func testExactIgnoresTheDeviceZoneAndLocale() {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(AuditTime.exact(date("2026-11-22T09:18:17Z")), "22.11.2026, 10:18:17 GMT+1")
    }

    func testTaskDecodesCreatedAndUpdatedAt() throws {
        let json = """
        {"id":"\(UUID())","projectID":"\(UUID())","title":"T","description":"","status":"open","version":1,"boardPosition":0,
         "createdAt":"2026-11-22T09:18:17Z","updatedAt":"2026-11-22T09:20:00Z"}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let task = try decoder.decode(TodoTask.self, from: Data(json.utf8))
        XCTAssertEqual(task.createdAt, date("2026-11-22T09:18:17Z"))
        XCTAssertEqual(task.updatedAt, date("2026-11-22T09:20:00Z"))
    }

    func testTaskWithoutTimesFromAnOlderServerStaysReadable() throws {
        let json = #"{"id":"\#(UUID())","projectID":"\#(UUID())","title":"T","description":"","status":"open","version":1}"#
        let task = try JSONDecoder().decode(TodoTask.self, from: Data(json.utf8))
        XCTAssertNil(task.createdAt)
        XCTAssertNil(task.updatedAt)
    }

    func testTaskTimesRoundTripThroughTheClientCoders() throws {
        let t = TodoTask(id: UUID(), projectID: UUID(), title: "T", createdAt: date("2026-11-22T09:18:17Z"), updatedAt: date("2026-11-22T09:20:00Z"))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(TodoTask.self, from: try encoder.encode(t)), t)
    }
}
