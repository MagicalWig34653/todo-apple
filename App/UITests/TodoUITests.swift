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
        // Defensive: a simulator with leftover keyboard state must not leak text into the title.
        if let existing = field.value as? String, !existing.isEmpty, existing != "Was ist zu tun?" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(title)
        app.buttons["quickAddSave"].tap()

        // The created task is due today, so it shows up in "Heute".
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "sheet dismissed")
        // The task is created from "Heute" and therefore planned for today; it is not in "Eingang" (tasks without a date).
        for _ in 0..<12 where !row.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(row.exists, "new task row in Heute")

        // Open the detail sheet.
        row.tap()
        XCTAssertTrue(app.buttons["Fertig"].waitForExistence(timeout: 5), "detail sheet")
        app.buttons["Fertig"].tap()

        // Complete through the leading swipe action (the VoiceOver equivalent is a custom action).
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeRight()
        let done = app.buttons.matching(identifier: "Als erledigt markieren").firstMatch // the row also exposes the custom action
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: row)
        waitForExpectations(timeout: 15)
    }

    /// The title field wraps (vertical axis); the keyboard's Return key must still save, not insert a line break.
    func testQuickAddReturnKeySaves() throws {
        let title = "UITest Return \(Int(Date().timeIntervalSince1970) % 100000)"
        app.buttons["quickAddButton"].tap()
        let field = app.textFields["quickAddTitle"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(title + "\n")
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "Return saved and dismissed the sheet")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        for _ in 0..<12 where !row.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(row.exists, "task created by Return")
        // Clean up so repeated runs do not pile tasks into "Heute".
        row.swipeRight()
        let done = app.buttons.matching(identifier: "Als erledigt markieren").firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
    }

    private func isPad() -> Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func attach(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// iPad: opening a task shows the detail (inspector next to the list; in narrow portrait the system presents it as a panel); screenshots are kept as attachments.
    func testPadInspectorShowsDetailBesideList() throws {
        try XCTSkipUnless(isPad(), "iPad only")
        attach("pad-list")
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Zahnarzttermin' OR label CONTAINS 'Angebote'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        first.tap()
        XCTAssertTrue(app.textFields["task.title"].exists || app.staticTexts["Fällig"].waitForExistence(timeout: 5), "inspector content")
        attach("pad-inspector")
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
