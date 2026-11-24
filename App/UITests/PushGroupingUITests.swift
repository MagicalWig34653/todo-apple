import XCTest

/// Card DF163B26 (bundle notifications): the real `NotificationDelegate` handles a reminder's "Später" action and the debug
/// probe reports what the app then really scheduled with the system (`getPendingNotificationRequests`) and which summary
/// lines the registered categories carry (`getNotificationCategories`). Same session variables as `PushResponseUITests`.
final class PushGroupingUITests: XCTestCase {
    private let projectID = "6F1C2D3E-4B5A-4C6D-8E7F-901A2B3C4D5E"
    private let taskID = "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D"

    override func setUpWithError() throws { continueAfterFailure = false }

    private func payload(thread: String?) -> String {
        let threadPart = thread.map { ",\"thread-id\":\"\($0)\"" } ?? ""
        return """
        {"aps":{"alert":{"body":"Eine Aufgabe wartet.","title":"Erinnerung"},"badge":1,"category":"TODO_REMINDER",\
        "mutable-content":1,"sound":"default"\(threadPart)},"kind":"reminder","projectID":"\(projectID)","taskID":"\(taskID)"}
        """
    }

    private func launchSnoozing(thread: String?) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"] else {
            throw XCTSkip("TODO_UITEST_SERVER / TODO_UITEST_TOKEN not set")
        }
        let app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_SERVER"] = server
        app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        app.launchEnvironment["TODO_DEBUG_SELECT"] = "today"
        app.launchEnvironment["TODO_DEBUG_DELIVER_RESPONSE"] = payload(thread: thread)
        app.launchEnvironment["TODO_DEBUG_DELIVER_ONLY"] = "didReceive"
        app.launchEnvironment["TODO_DEBUG_DELIVER_ACTION"] = "TODO_SNOOZE"
        app.launch()
        return app
    }

    private func probeLabel(_ app: XCUIApplication, containing text: String) -> String {
        let probe = app.otherElements["debug.pushProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 20), "probe present")
        expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: probe)
        waitForExpectations(timeout: 20)
        return probe.label
    }

    /// A push without `thread-id` still lands in the project's stack when it is snoozed (local copy).
    func testSnoozedCopyJoinsTheProjectThread() throws {
        let app = try launchSnoozing(thread: nil)
        let label = probeLabel(app, containing: "snoozeThread=")
        XCTAssertTrue(label.contains("snoozeThread=\(projectID)"), label)
    }

    /// The server's own thread id is kept.
    func testSnoozedCopyKeepsTheServerThread() throws {
        let app = try launchSnoozing(thread: projectID)
        let label = probeLabel(app, containing: "snoozeThread=")
        XCTAssertTrue(label.contains("snoozeThread=\(projectID)"), label)
    }

    /// Every category summarises its hidden notifications ("%u weitere ...").
    func testEveryCategoryHasASummaryLine() throws {
        let app = try launchSnoozing(thread: projectID)
        let label = probeLabel(app, containing: "summaries=")
        XCTAssertTrue(label.contains("summaries=6/6"), label)
    }
}
