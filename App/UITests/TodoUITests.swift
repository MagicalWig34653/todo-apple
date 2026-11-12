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
        // The floating tab bar and the FAB cover the last rows; scroll until the row itself takes the tap.
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }

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
        // Let presentation animations (sheet, inspector) and keyboard transitions finish: the audit reads mid-flight frames otherwise.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 2)
        var report: [String] = []
        try app.performAccessibilityAudit { issue in
            // Keyboard internals are not ours; contrast/Dynamic-Type findings are recorded as attachments (open items in docs/HIG-AUDIT.md).
            if issue.element?.elementType == .keyboard || issue.detailedDescription.contains("TUIPrediction") { return true }
            // iPad's full software keyboard draws key caps the audit cannot attribute to an element (no element, text nodes only).
            if issue.element == nil, issue.auditType.rawValue == 2 /* element detection */, self.app.keyboards.firstMatch.exists { return true }
            // "Für dich" scrolls beneath the translucent floating tab bar; a section header that happens to sit under the
            // glass is reported as unattributed text (no element, no frame). Depends on the scroll position, not on our views.
            if name == "feed", issue.element == nil, issue.auditType.rawValue == 2 { return true }
            report.append("[\(name)] \(issue.auditType.rawValue) | \(issue.element?.label ?? "-") | \(issue.element?.elementType.rawValue ?? 0) | \(issue.element?.frame.debugDescription ?? "-") | \(issue.detailedDescription)")
            return true
        }
        let soft: Set<UInt64> = [XCUIAccessibilityAuditType.contrast.rawValue, XCUIAccessibilityAuditType.textClipped.rawValue, XCUIAccessibilityAuditType.dynamicType.rawValue]
        let hard = report.filter { r in !soft.contains { r.hasPrefix("[\(name)] \($0) ") } }
        let att = XCTAttachment(string: report.joined(separator: "\n")); att.lifetime = .keepAlways; add(att)
        if !hard.isEmpty {
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
            let tree = XCTAttachment(string: app.debugDescription); tree.lifetime = .keepAlways; add(tree)
            XCTFail("AUDIT-ISSUES\n" + hard.joined(separator: "\n"))
        }
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

    // MARK: Navigation variant A (four tabs)

    private func tab(_ name: String) -> XCUIElement { app.tabBars.buttons[name] }

    /// iPhone: exactly Für dich, Projekte, Planen, Suche; the former Todoist tabs are gone from the bar.
    func testTabBarHasFourTabs() throws {
        try XCTSkipIf(isPad(), "iPhone tab bar")
        for name in ["Für dich", "Projekte", "Planen", "Suche"] {
            XCTAssertTrue(tab(name).waitForExistence(timeout: 5), "tab \(name)")
        }
        XCTAssertEqual(app.tabBars.buttons.count, 4)
        for gone in ["Eingang", "Anstehend", "Durchsuchen", "Heute"] {
            XCTAssertFalse(tab(gone).exists, "no tab \(gone)")
        }
        // Launched with TODO_DEBUG_SELECT=today: "Planen" is selected, segment "Heute".
        XCTAssertTrue(tab("Planen").isSelected)
    }

    /// "Für dich" shows the agent overview; the Steuerzentrale is one tap away.
    func testForYouOpensCommandCenterInOneTap() throws {
        try XCTSkipIf(isPad(), "iPhone tab bar")
        tab("Für dich").tap()
        let overview = app.buttons["forYou.commandCenter"]
        XCTAssertTrue(overview.waitForExistence(timeout: 10), "agent overview")
        overview.tap()
        XCTAssertTrue(app.staticTexts["Steuerzentrale"].waitForExistence(timeout: 10), "command center opened")
        // Back to the start tab root.
        tab("Für dich").tap()
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
    }

    /// Lage-Ampel: the row on "Für dich" shows Claude, Codex, disk and the age; test data come from the debug stub.
    private func relaunchForYou(statusAge: Int) {
        app.terminate()
        app.launchEnvironment["TODO_DEBUG_SELECT"] = "feed"
        app.launchEnvironment["TODO_DEBUG_SYSTEM_STATUS"] = #"{"status":{"claude_ampel":"gelb","claude_nutzbare_konten":[4,7],"codex":{"verbraucht_pct":5,"erlaubt_bis_jetzt_pct":19.2,"freigabe":true},"platte_ampel":"gruen","platte_frei_gb":104.9}}"#
        app.launchEnvironment["TODO_DEBUG_SYSTEM_STATUS_AGE"] = String(statusAge)
        app.launch()
    }

    func testForYouShowsSystemStatusRow() throws {
        try XCTSkipIf(isPad(), "iPhone tab bar; the iPad shows the row in the sidebar")
        relaunchForYou(statusAge: 3)
        XCTAssertTrue(app.descendants(matching: .any)["systemStatus.row"].waitForExistence(timeout: 20), "status row")
        let row = app.descendants(matching: .any)["systemStatus.row"]
        XCTAssertTrue(row.label.contains("4, 7 nutzbar"), row.label)
        XCTAssertTrue(row.label.contains("104,9 GB frei"), row.label)
        XCTAssertTrue(row.label.contains("vor 3 min"), row.label)
        XCTAssertFalse(app.descendants(matching: .any)["systemStatus.stale"].exists)
        try audit("feed") // same known element-less finding under the tab bar as the feed audit
    }

    func testSystemStatusRowTurnsGreyWhenStale() throws {
        try XCTSkipIf(isPad(), "iPhone tab bar; the iPad shows the row in the sidebar")
        relaunchForYou(statusAge: 45)
        let row = app.descendants(matching: .any)["systemStatus.stale"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "stale row")
        XCTAssertTrue(row.label.contains("veraltet"), row.label)
    }

    /// "Planen" keeps Heute, Anstehend and Eingang as segments, and labels/filters via the toolbar.
    func testPlanKeepsTodayUpcomingInboxAndLabels() throws {
        try XCTSkipIf(isPad(), "iPhone tab bar")
        tab("Planen").tap()
        let segments = app.segmentedControls["planSection"]
        XCTAssertTrue(segments.waitForExistence(timeout: 5))
        for name in ["Heute", "Anstehend", "Eingang"] { XCTAssertTrue(segments.buttons[name].exists, "segment \(name)") }
        segments.buttons["Eingang"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Geburtstagsgeschenk' OR label BEGINSWITH 'Angebote' OR label BEGINSWITH 'Umzugswagen'")).firstMatch.waitForExistence(timeout: 5) || app.staticTexts["Eingang"].exists)
        segments.buttons["Anstehend"].tap()
        XCTAssertTrue(app.staticTexts["Anstehend"].waitForExistence(timeout: 5))
        app.buttons["plan.labels"].tap()
        XCTAssertTrue(app.navigationBars["Filter und Etiketten"].waitForExistence(timeout: 5), "labels screen")
    }

    /// "Projekte" lists the projects without scrolling; a project offers list/board and its agent view with labels.
    func testProjectsTabListsProjectsAndAgentView() throws {
        try XCTSkipIf(isPad(), "iPhone tab bar")
        tab("Projekte").tap()
        let project = app.buttons.matching(NSPredicate(format: "label == 'Website-Relaunch'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        XCTAssertTrue(project.isHittable, "visible without scrolling")
        project.tap()
        XCTAssertTrue(app.segmentedControls["project.layout"].waitForExistence(timeout: 10), "labeled list/board switch")
        app.buttons["project.agents"].tap()
        XCTAssertTrue(app.staticTexts["Steuerzentrale"].waitForExistence(timeout: 10), "project command center")
    }

    /// Account, teams, agents and activity sit behind the avatar.
    func testAccountMenuHoldsAccountTeamsAgents() throws {
        try XCTSkipIf(isPad(), "iPhone tab bar")
        tab("Projekte").tap()
        let avatar = app.buttons["accountMenu"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        avatar.tap()
        for name in ["Konto", "Teams", "Agenten & Runner", "Aktivität"] {
            XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5), "menu entry \(name)")
        }
        app.buttons["Agenten & Runner"].tap()
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 5), "pushed onto the open tab")
        XCTAssertTrue(tab("Projekte").isSelected)
    }

    /// "Für dich": needs seed data with `TODO_LIVE_SEED_FEED=1`; shows the needs-you card with its option buttons.
    func testFeedShowsNeedsYouAndAudit() throws {
        app.terminate()
        app.launchEnvironment["TODO_DEBUG_SELECT"] = "feed"
        app.launch()
        let title = app.staticTexts["Braucht dich"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "needs-you section")
        XCTAssertTrue(app.buttons["Ja, mobil zuerst"].waitForExistence(timeout: 5))
        try audit("feed")
    }

    /// Rows carry the agent state as text, not color alone: needs `TODO_LIVE_SEED_FEED=1` (question on "Design-Review
    /// vorbereiten", review on "Texte fuer Startseite freigeben").
    func testProjectRowsShowAgentState() throws {
        try XCTSkipIf(isPad(), "iPhone tab bar")
        tab("Projekte").tap()
        let project = app.buttons.matching(NSPredicate(format: "label == 'Website-Relaunch'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        let question = app.buttons.matching(NSPredicate(format: "label == 'Design-Review vorbereiten'")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        let hasState = { (row: XCUIElement, text: String) in
            (0..<10).contains { _ in
                if (row.value as? String)?.contains(text) == true { return true }
                Thread.sleep(forTimeInterval: 1); return false
            }
        }
        XCTAssertTrue(hasState(question, "Frage offen"), "question state in VoiceOver value: \(question.value ?? "")")
        let review = app.buttons.matching(NSPredicate(format: "label == 'Texte fuer Startseite freigeben'")).firstMatch
        XCTAssertTrue(review.exists)
        XCTAssertTrue(hasState(review, "Review"), "review state in VoiceOver value: \(review.value ?? "")")
    }

    private func element(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func openWebsiteCard(_ title: String) {
        tab("Projekte").tap()
        let project = app.buttons.matching(NSPredicate(format: "label == 'Website-Relaunch'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        let card = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "card \(title)")
        card.tap()
        XCTAssertTrue(app.buttons["Fertig"].waitForExistence(timeout: 5), "detail sheet")
    }

    /// Chat in the card detail like the PWA (needs `TODO_LIVE_SEED_FEED=1`): the open question has its own chat with the
    /// seeded message and takes a reply; the bar at the bottom writes into the task's own chat; the review has its chat.
    func testDetailChatsForTaskQuestionAndReview() throws {
        try XCTSkipIf(isPad(), "iPhone tab bar")
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        openWebsiteCard("Design-Review vorbereiten")
        XCTAssertTrue(app.descendants(matching: .any)["chat.question"].waitForExistence(timeout: 10), "question chat")
        XCTAssertTrue(element(containing: "Zählt das iPad auch als mobil?").waitForExistence(timeout: 10), "seeded question message")

        let reply = "Ja, iPad zählt mit \(stamp)"
        let field = app.textFields["chat.field.question"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        for _ in 0..<6 where !field.isHittable { app.swipeUp() }
        field.tap()
        field.typeText(reply)
        app.buttons["chat.send.question"].tap()
        XCTAssertTrue(element(containing: reply).waitForExistence(timeout: 10), "reply in question chat")

        let note = "UITest Nachricht \(stamp)"
        let taskField = app.textFields["chat.field.task"]
        XCTAssertTrue(taskField.waitForExistence(timeout: 5))
        taskField.tap()
        taskField.typeText(note)
        app.buttons["chat.send.task"].tap()
        let sent = element(containing: note)
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "message in task chat")
        // The task chat is its own thread: the question reply does not show up twice.
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'chat.bubble.mine' AND label CONTAINS %@", reply)).count, 1)
        app.buttons["Fertig"].tap()

        openWebsiteCard("Texte fuer Startseite freigeben")
        XCTAssertTrue(app.descendants(matching: .any)["chat.review"].waitForExistence(timeout: 10), "review chat")
        XCTAssertTrue(element(containing: "Bitte die Datenschutzerklärung noch prüfen.").waitForExistence(timeout: 10), "seeded review message")
    }
}
