import XCTest
@testable import TodoCore

/// Notifications of one project stack as one group on the lock screen (thread identifier), with a summary line per
/// category. Remote pushes carry `aps.thread-id` from the server; local copies ("Später") must keep or rebuild it.
final class PushGroupingTests: XCTestCase {
    let pid = UUID(uuidString: "6F1C2D3E-4B5A-4C6D-8E7F-901A2B3C4D5E")!
    let tid = UUID(uuidString: "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D")!

    private func userInfo(thread: String?, kind: String = "reminder", project: UUID? = nil) -> [AnyHashable: Any] {
        var aps: [String: Any] = ["category": "TODO_REMINDER"]
        if let thread { aps["thread-id"] = thread }
        var info: [AnyHashable: Any] = ["aps": aps, "kind": kind, "taskID": tid.uuidString]
        if let project { info["projectID"] = project.uuidString }
        return info
    }

    func testPayloadReadsServerThreadID() {
        let payload = PushPayload(userInfo: userInfo(thread: pid.uuidString, project: pid))
        XCTAssertEqual(payload.threadID, pid.uuidString)
    }

    func testPayloadIgnoresEmptyOrNonStringThreadID() {
        XCTAssertNil(PushPayload(userInfo: userInfo(thread: "")).threadID)
        XCTAssertNil(PushPayload(userInfo: ["aps": ["thread-id": 7]]).threadID)
        XCTAssertNil(PushPayload(userInfo: userInfo(thread: nil)).threadID)
    }

    func testServerThreadWinsOverProject() {
        let payload = PushPayload(userInfo: userInfo(thread: "custom-thread", project: pid))
        XCTAssertEqual(PushGrouping.threadIdentifier(for: payload), "custom-thread")
    }

    func testSameProjectGroupsReminderAndQuestionTogether() {
        let reminder = PushPayload(userInfo: userInfo(thread: nil, kind: "reminder", project: pid))
        let question = PushPayload(userInfo: userInfo(thread: nil, kind: "question", project: pid))
        XCTAssertEqual(PushGrouping.threadIdentifier(for: reminder), pid.uuidString)
        XCTAssertEqual(PushGrouping.threadIdentifier(for: reminder), PushGrouping.threadIdentifier(for: question))
    }

    func testDifferentProjectsStaySeparate() {
        let other = UUID()
        let a = PushPayload(userInfo: userInfo(thread: nil, project: pid))
        let b = PushPayload(userInfo: userInfo(thread: nil, project: other))
        XCTAssertNotEqual(PushGrouping.threadIdentifier(for: a), PushGrouping.threadIdentifier(for: b))
    }

    func testProjectlessKindsGroupByKind() {
        let confirmation = PushPayload(userInfo: ["aps": [:], "kind": "action_request"])
        let brief = PushPayload(userInfo: ["aps": [:], "kind": "daily_brief"])
        XCTAssertEqual(PushGrouping.threadIdentifier(for: confirmation), "todolino.action_request")
        XCTAssertEqual(PushGrouping.threadIdentifier(for: brief), "todolino.daily_brief")
    }

    func testUnknownPayloadHasNoThread() {
        XCTAssertNil(PushGrouping.threadIdentifier(for: PushPayload(userInfo: [:])))
    }

    func testEveryRegisteredCategoryHasASummaryFormatKey() {
        let categories = [PushIdentifiers.reminder, PushIdentifiers.question, PushIdentifiers.review, PushIdentifiers.comment,
                          PushIdentifiers.confirmation, PushIdentifiers.dailyBrief]
        let keys = categories.map { PushGrouping.summaryFormatKey(category: $0) }
        XCTAssertFalse(keys.contains(nil))
        XCTAssertEqual(Set(keys).count, categories.count, "each category has its own summary line")
        XCTAssertEqual(PushGrouping.summaryFormatKey(category: PushIdentifiers.question), "push.summary.questions")
        XCTAssertNil(PushGrouping.summaryFormatKey(category: "SOMETHING_ELSE"))
    }
}
