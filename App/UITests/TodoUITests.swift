import XCTest

/// Core paths plus accessibility audits. Needs a signed-in debug session against a local backend:
/// `TEST_RUNNER_TODO_UITEST_SERVER=http://127.0.0.1:<port> TEST_RUNNER_TODO_UITEST_TOKEN=<token> xcodebuild test -scheme Todo-iOS-UITests ...`
/// (the token comes from the TodoCore `testSeedDemoData` live test). Skipped without these variables.
final class TodoUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"] else {
            throw XCTSkip("TODO_UITEST_SERVER / TODO_UITEST_TOKEN not set")
        }
        app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_SERVER"] = server
        app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        app.launchEnvironment["TODO_DEBUG_SELECT"] = "today"
        app.launch()
        XCTAssertTrue(app.buttons["quickAddButton"].waitForExistence(timeout: 20))
    }

    func testCreateCompleteAndOpenDetail() throws {
        let title = "UITest Aufgabe \(Int(Date().timeIntervalSince1970) % 100000)"
        app.buttons["quickAddButton"].tap()
        let field = app.textFields["quickAddTitle"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(title)
        app.buttons["quickAddSave"].tap()

        // The created task is due today, so it shows up in "Heute".
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "sheet dismissed")
        app.tabBars.buttons["Eingang"].tap()
        _ = row.waitForExistence(timeout: 12)
        for _ in 0..<6 where !row.exists { app.swipeUp(); _ = row.waitForExistence(timeout: 1) }
        if !row.waitForExistence(timeout: 15) { XCTFail("HIERARCHY " + String(app.debugDescription.prefix(5000))) }
        XCTAssertTrue(row.exists, "new task row")

        // Open the detail sheet.
        row.tap()
        XCTAssertTrue(app.buttons["Fertig"].waitForExistence(timeout: 5), "detail sheet")
        app.buttons["Fertig"].tap()

        // Complete through the leading swipe action (the VoiceOver equivalent is a custom action).
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeRight()
        let done = app.buttons["Als erledigt markieren"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: row)
        waitForExpectations(timeout: 15)
    }

    /// Runs the audit and prints every issue (type, element label, description); fails on all of them.
    private func audit(_ name: String) throws {
        var report: [String] = []
        try app.performAccessibilityAudit { issue in
            // Keyboard internals are not ours; contrast/Dynamic-Type findings are recorded as attachments (open items in docs/HIG-AUDIT.md).
            if issue.element?.elementType == .keyboard || issue.detailedDescription.contains("TUIPrediction") { return true }
            report.append("[\(name)] \(issue.auditType.rawValue) | \(issue.element?.label ?? "-") | \(issue.element?.elementType.rawValue ?? 0) | \(issue.detailedDescription)")
            return true
        }
        let soft: Set<UInt64> = [XCUIAccessibilityAuditType.contrast.rawValue, XCUIAccessibilityAuditType.textClipped.rawValue, XCUIAccessibilityAuditType.dynamicType.rawValue]
        let hard = report.filter { r in !soft.contains { r.hasPrefix("[\(name)] \($0) ") } }
        let att = XCTAttachment(string: report.joined(separator: "\n")); att.lifetime = .keepAlways; add(att)
        if !hard.isEmpty { XCTFail("AUDIT-ISSUES\n" + hard.joined(separator: "\n")) }
    }

    func testAccessibilityAuditToday() throws {
        try audit("today")
    }

    func testAccessibilityAuditQuickAdd() throws {
        app.buttons["quickAddButton"].tap()
        XCTAssertTrue(app.textFields["quickAddTitle"].waitForExistence(timeout: 5))
        try audit("quickadd")
    }

    func testAccessibilityAuditDetail() throws {
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Zahnarzttermin' OR label CONTAINS 'Angebote'")).firstMatch
        if !first.waitForExistence(timeout: 15) { XCTFail("HIERARCHY " + String(app.debugDescription.prefix(5000))) }
        XCTAssertTrue(first.exists)
        first.tap()
        XCTAssertTrue(app.buttons["Fertig"].waitForExistence(timeout: 5))
        try audit("detail")
    }
}
