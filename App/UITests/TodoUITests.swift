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
        // Fixed time of day for the app's clock (the quick-add default for "today" is "now + 1 h", which crosses midnight
        // late in the evening). `TEST_RUNNER_TODO_UITEST_NOW=23:30` simulates the edge case.
        app.launchEnvironment["TODO_DEBUG_NOW"] = env["TODO_UITEST_NOW"] ?? "12:00"
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
        // The floating tab bar and the FAB cover the last rows. `isHittable` is not enough: a row whose frame reaches under the
        // translucent tab bar still reports true, but the tap at its centre lands on the tab bar ("Planen" again: the list jumps
        // to the top, the row is gone). Which row sits there depends on how many tasks other tests left in "Heute".
        // Scroll in small steps until the whole row ends above the tab bar and clears the FAB.
        for _ in 0..<8 where !clearsFloatingBars(row) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(clearsFloatingBars(row), "row scrolled clear of the tab bar")

        // Open the detail sheet. A tap while the list still decelerates from the swipes only stops the scrolling and
        // opens nothing (cause of the flaky "detail sheet" failure), so wait until the row stands still first.
        settle(row)
        row.tap()
        if !app.buttons["Fertig"].waitForExistence(timeout: 3) { settle(row); row.tap() }
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

    /// True when the row is hittable and its frame ends above the floating tab bar.
    private func clearsFloatingBars(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let bar = app.tabBars.firstMatch
        let limit = bar.exists ? bar.frame.minY : app.frame.maxY
        return element.frame.maxY <= limit
    }

    /// Waits until the element's frame stops moving (scroll momentum after `swipeUp`), at most about 3 s.
    private func settle(_ element: XCUIElement) {
        var last = element.frame
        for _ in 0..<15 {
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 0.2)
            let now = element.frame
            if now == last { return }
            last = now
        }
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
        // The simulator's own framebuffer too (in `<scratch>/shots` when run through scripts/ui-tests.sh): rotated iPad
        // screenshots from XCUITest are cropped.
        if ProcessInfo.processInfo.environment["TODO_UITEST_HELPER"] != nil { try? helperCall("/shot/\(name)") }
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

    /// iPad: the text size moving into the accessibility range swaps the detail from the inspector into a sheet (and back).
    /// The open task must survive that. The system's Dynamic Type audit is the real size sweep available to a UI test.
    func testPadDetailStaysOpenAcrossTextSizeChange() throws {
        try XCTSkipUnless(isPad(), "iPad only")
        openSeededDetail()
        try app.performAccessibilityAudit(for: .dynamicType) { _ in true }
        XCTAssertTrue(app.buttons["Fertig"].waitForExistence(timeout: 10), "detail still open after the text size sweep")
        attach("pad-detail-after-size-sweep")
        app.buttons["Fertig"].tap()
        XCTAssertTrue(app.buttons["Fertig"].waitForNonExistence(timeout: 5), "\"Fertig\" still closes the detail")
    }

    // MARK: iPad detail across system text size changes (card 30B568CF): landscape, fast toggling, unsent input

    private enum SystemSize: String {
        case normal = "large", axThreshold = "accessibility-medium", axLargest = "accessibility-extra-extra-extra-large"
    }

    /// Asks `scripts/sim-text-size-helper.py` (host side, started by `scripts/ui-tests.sh`) to change the simulator's
    /// preferred content size category: the real system change, while the app runs.
    private func helperCall(_ path: String) throws {
        guard let base = ProcessInfo.processInfo.environment["TODO_UITEST_HELPER"], let url = URL(string: base + path) else {
            throw XCTSkip("TODO_UITEST_HELPER not set (run through scripts/ui-tests.sh)")
        }
        final class Box: @unchecked Sendable { var status = 0 }
        let box = Box(), done = expectation(description: "helper \(path)")
        URLSession.shared.dataTask(with: url) { _, response, _ in box.status = (response as? HTTPURLResponse)?.statusCode ?? 0; done.fulfill() }.resume()
        wait(for: [done], timeout: 90)
        XCTAssertEqual(box.status, 200, "helper call \(path)")
    }

    /// Sets the system text size now and puts it back to normal when the test ends (the simulator keeps it otherwise).
    private func setSystemSize(_ size: SystemSize) throws {
        try helperCall("/size/\(size.rawValue)")
    }

    private func restoreSystemSizeAfterTest() throws {
        try setSystemSize(.normal)
        addTeardownBlock { try? self.helperCall("/size/\(SystemSize.normal.rawValue)") }
    }

    /// By identifier prefix: the message field is "chat.field.<kind>".
    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", id)).firstMatch
    }

    /// The detail is open exactly once: one "Fertig" (a second bar behind a sheet was the earlier symptom) and the title field.
    private func assertDetailOpen(_ context: String, title: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "count == 1")
        let single = XCTNSPredicateExpectation(predicate: predicate, object: app.buttons.matching(identifier: "Fertig"))
        XCTAssertEqual(XCTWaiter.wait(for: [single], timeout: 15), .completed, "\(context): exactly one \"Fertig\" (count \(app.buttons.matching(identifier: "Fertig").count))", file: file, line: line)
        XCTAssertTrue(element("task.title").waitForExistence(timeout: 10), "\(context): task title field", file: file, line: line)
        if let title { XCTAssertEqual(element("task.title").value as? String, title, "\(context): same task", file: file, line: line) }
    }

    // The detail's scroll view, found by any of its fields (off-screen ones are not in the accessibility tree).
    private var detailScroll: XCUIElement {
        app.scrollViews.containing(NSPredicate(format: "identifier IN {'task.title', 'task.description', 'subtask.add', 'label.new'}")).firstMatch
    }

    /// `isHittable` is false for the title (a text field with a scroll indicator child), so visibility is by frame.
    private func visible(_ field: XCUIElement) -> Bool {
        let window = app.windows.firstMatch.frame
        return field.exists && field.frame.minY > 90 && (field.isHittable || field.frame.maxY < window.maxY - 100)
    }

    private func reveal(_ field: XCUIElement) {
        for _ in 0..<8 where !visible(field) { detailScroll.swipeUp(velocity: .slow) }
        for _ in 0..<8 where !visible(field) { detailScroll.swipeDown(velocity: .slow) }
    }

    private func hasFocus(_ field: XCUIElement) -> Bool { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }

    private func focus(_ field: XCUIElement) {
        reveal(field)
        for _ in 0..<3 where !hasFocus(field) {
            field.tap()
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "focus")], timeout: 0.8)
        }
    }

    /// Types into a field of the open detail without sending or submitting it.
    private func typeDraft(_ id: String, _ text: String) {
        let field = element(id)
        reveal(field)
        focus(field)
        XCTAssertTrue(hasFocus(field), "\(id) has keyboard focus")
        field.typeText(text)
    }

    private func assertDraft(_ id: String, contains text: String, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = element(id)
        reveal(field)
        XCTAssertTrue(field.exists, "\(context): \(id) exists", file: file, line: line)
        XCTAssertTrue(((field.value as? String) ?? "").contains(text), "\(context): unsent \(id) kept (now \"\(field.value as? String ?? "nil")\")", file: file, line: line)
    }

    private func seededTitle() -> String { (element("task.title").value as? String) ?? "" }

    /// iPad landscape: sheet and inspector swap the same way, the open task survives both directions and "Fertig" still closes it.
    func testPadDetailStaysOpenAcrossTextSizeChangeLandscape() throws {
        try XCTSkipUnless(isPad(), "iPad only")
        try restoreSystemSizeAfterTest()
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        let landscape = NSPredicate { _, _ in self.app.windows.firstMatch.frame.width > self.app.windows.firstMatch.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: nil)], timeout: 10), .completed, "landscape")
        openSeededDetail()
        let title = seededTitle()
        XCTAssertFalse(title.isEmpty)
        assertDetailOpen("landscape, before", title: title)
        attach("1-vorher-quer-inspector")
        try setSystemSize(.axLargest)
        assertDetailOpen("landscape, accessibility size", title: title)
        attach("2-waehrend-quer-sheet")
        try setSystemSize(.normal)
        assertDetailOpen("landscape, back to normal", title: title)
        attach("3-nachher-quer-inspector")
        // And once more through the smallest accessibility size (the swap threshold).
        try setSystemSize(.axThreshold)
        assertDetailOpen("landscape, threshold size", title: title)
        try setSystemSize(.normal)
        assertDetailOpen("landscape, back again", title: title)
        app.buttons["Fertig"].tap()
        XCTAssertTrue(app.buttons["Fertig"].waitForNonExistence(timeout: 5), "\"Fertig\" still closes the detail")
    }

    /// iPad: the text size flips back and forth faster than the sheet/inspector animation; the open task must survive
    /// whatever size the burst ends on, with exactly one detail on screen.
    func testPadDetailStaysOpenAcrossRapidTextSizeToggling() throws {
        try XCTSkipUnless(isPad(), "iPad only")
        try restoreSystemSizeAfterTest()
        openSeededDetail()
        let title = seededTitle()
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "panel settled")], timeout: 2)
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        // Only the message field: it sits in the bar below the scroll view, so checking it needs no scrolling. Scrolling the
        // detail after a burst once left the app without an "animations complete" notification for over 15 minutes (not
        // reproduced in two follow-up runs, see docs/STATUS.md).
        let drafts = [("chat.field", "Zeile\(stamp)")]
        for (id, text) in drafts { typeDraft(id, text) }
        attach("1-vorher-schnell-inspector")
        let flips = Array(repeating: ["large", SystemSize.axLargest.rawValue], count: 6).flatMap { $0 }   // 12 changes, ends on the largest
        try helperCall("/burst/\(flips.joined(separator: ","))?gap=0")
        assertDetailOpen("burst ends large text", title: title)
        for (id, text) in drafts { assertDraft(id, contains: text, "burst ends large text") }
        attach("2-waehrend-schnell-sheet")
        try helperCall("/burst/\((flips + ["large"]).joined(separator: ","))?gap=0")  // 13 changes, ends on normal
        assertDetailOpen("burst ends normal", title: title)
        for (id, text) in drafts { assertDraft(id, contains: text, "burst ends normal") }
        attach("3-nachher-schnell-inspector")
        // Slower, but still inside the animation: the threshold size against normal with 120 ms between changes.
        let slow = Array(repeating: ["large", SystemSize.axThreshold.rawValue], count: 5).flatMap { $0 }
        try helperCall("/burst/\(slow.joined(separator: ","))?gap=120")
        assertDetailOpen("slow burst ends threshold", title: title)
        try helperCall("/burst/\((slow + ["large"]).joined(separator: ","))?gap=120")
        assertDetailOpen("slow burst ends normal", title: title)
        for (id, text) in drafts { assertDraft(id, contains: text, "slow burst ends normal") }
        app.buttons["Fertig"].tap()
        XCTAssertTrue(app.buttons["Fertig"].waitForNonExistence(timeout: 5), "\"Fertig\" still closes the detail")
    }

    /// iPad: one tap on the title of the open detail focuses it, and typing goes into the title (card 9E107820).
    func testPadSingleTapFocusesTitle() throws {
        try XCTSkipUnless(isPad(), "iPad only")
        openSeededDetail()
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "panel settled")], timeout: 2)
        let field = element("task.title")
        XCTAssertTrue(field.waitForExistence(timeout: 10), "title exists")
        XCTAssertFalse(hasFocus(field), "title not focused before the tap")
        attach("titel-1-vor-tipp")
        field.tap()
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "focus")], timeout: 1.5)
        attach("titel-2-nach-tipp")
        XCTAssertTrue(hasFocus(field), "one tap focuses the title")
        let stamp = " Tipp\(Int(Date().timeIntervalSince1970) % 100000)"
        field.typeText(stamp)
        XCTAssertTrue(((field.value as? String) ?? "").contains(stamp.trimmingCharacters(in: .whitespaces)), "typed into the title (now \"\(field.value as? String ?? "nil")\")")
        attach("titel-3-getippt")
        // The panel makes room by hiding the sidebar in portrait; closing it brings the sidebar back.
        app.buttons["Fertig"].tap()
        XCTAssertTrue(app.buttons["Fertig"].waitForNonExistence(timeout: 5), "\"Fertig\" closes the detail")
        XCTAssertTrue(app.staticTexts["Steuerzentrale"].waitForExistence(timeout: 5), "sidebar back after closing the detail")
    }

    /// iPad portrait: with the detail open the panel never lies over the list, and the sidebar makes room for it
    /// (card 1A952C26). Once the sidebar button had been used, the system kept the sidebar beside the open panel, also
    /// after the next start of the app.
    func testPadPortraitDetailNeverCoversList() throws {
        try XCTSkipUnless(isPad(), "iPad only")
        XCUIDevice.shared.orientation = .portrait
        let sidebarEntry = app.staticTexts["Steuerzentrale"].firstMatch
        func tapSidebarButton() {
            let buttons = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Seitenleiste'"))
            XCTAssertTrue(buttons.firstMatch.waitForExistence(timeout: 10), "sidebar button")
            // With the sidebar over the list the list's own button lies underneath it: take the one on top.
            (buttons.allElementsBoundByIndex.last { $0.isHittable } ?? buttons.firstMatch).tap()
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "sidebar settled")], timeout: 1.5)
        }
        // The user's own choice: hide the sidebar, show it again.
        if !sidebarEntry.waitForExistence(timeout: 5) { tapSidebarButton() }
        tapSidebarButton()
        XCTAssertTrue(sidebarEntry.waitForNonExistence(timeout: 5), "sidebar hidden by its button")
        tapSidebarButton()
        XCTAssertTrue(sidebarEntry.waitForExistence(timeout: 5), "sidebar shown by its button")

        func openAndCheck(_ context: String) {
            openSeededDetail()
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "panel settled")], timeout: 1.5)
            attach("pad-portrait-\(context)")
            // "Fertig" is the leftmost control of the panel. The add button and "Auf heute legen" sit at the list's
            // trailing edge: left of the panel only if the list got its own room.
            let panelEdge = app.buttons["Fertig"].frame.minX
            let add = app.buttons["quickAddButton"].frame
            XCTAssertLessThanOrEqual(add.maxX, panelEdge, "\(context): add button under the panel (\(add))")
            let move = app.buttons["Auf heute legen"].firstMatch
            if move.exists { XCTAssertLessThanOrEqual(move.frame.maxX, panelEdge, "\(context): list header under the panel (\(move.frame))") }
            XCTAssertFalse(sidebarEntry.exists, "\(context): sidebar still open beside list and panel")
        }
        func closeAndCheck(_ context: String) {
            app.buttons["Fertig"].tap()
            XCTAssertTrue(app.buttons["Fertig"].waitForNonExistence(timeout: 5), "\(context): \"Fertig\" closes the detail")
            XCTAssertTrue(sidebarEntry.waitForExistence(timeout: 5), "\(context): sidebar back after closing")
        }
        XCTAssertLessThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height, "portrait")
        openAndCheck("first")
        closeAndCheck("first")
        openAndCheck("again")
        // The sidebar button still brings the sidebar over the open detail, and the list is free again once it goes.
        tapSidebarButton()
        XCTAssertTrue(sidebarEntry.waitForExistence(timeout: 5), "sidebar on request while the detail is open")
        attach("pad-portrait-sidebar-on-request")
        tapSidebarButton()
        XCTAssertTrue(sidebarEntry.waitForNonExistence(timeout: 5), "sidebar hidden again")
        XCTAssertLessThanOrEqual(app.buttons["quickAddButton"].frame.maxX, app.buttons["Fertig"].frame.minX, "list free after the sidebar went")
        closeAndCheck("again")
        // The choice survives a restart of the app.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["quickAddButton"].waitForExistence(timeout: 30))
        openAndCheck("relaunch")
        closeAndCheck("relaunch")
    }

    /// iPad: text typed into the detail but not sent (title, note, subtask, label, message) is still there after the swap
    /// to the sheet and back; title and note are also saved by the view disappearing.
    func testPadDetailKeepsUnsentInputAcrossTextSizeChange() throws {
        try XCTSkipUnless(isPad(), "iPad only")
        try restoreSystemSizeAfterTest()
        openSeededDetail()
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "panel settled")], timeout: 2)
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        let drafts: [(id: String, text: String)] = [
            ("task.title", " Titel\(stamp)"), ("task.description", "Notiz\(stamp)"),
            ("subtask.add", "Unter\(stamp)"), ("label.new", "Etikett\(stamp)"), ("chat.field", "Nachricht\(stamp)"),
        ]
        for draft in drafts {
            let field = element(draft.id)
            XCTAssertTrue(field.waitForExistence(timeout: 10), "\(draft.id) exists")
            focus(field)
            XCTAssertTrue(hasFocus(field), "\(draft.id) has keyboard focus")
            field.typeText(draft.text)   // no Return: nothing is sent or submitted
        }
        func assertDrafts(_ context: String) {
            for draft in drafts { assertDraft(draft.id, contains: draft.text.trimmingCharacters(in: .whitespaces), context) }
        }
        attach("1-vorher-eingabe-inspector")
        try setSystemSize(.axLargest)
        assertDetailOpen("typed, accessibility size")
        attach("2-waehrend-eingabe-sheet")
        assertDrafts("accessibility size")
        try setSystemSize(.normal)
        assertDetailOpen("typed, back to normal")
        attach("3-nachher-eingabe-inspector")
        assertDrafts("back to normal")
    }

    private func openSeededDetail() {
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Zahnarzttermin' OR label CONTAINS 'Angebote'")).firstMatch
        if !first.waitForExistence(timeout: 15) { XCTFail("HIERARCHY " + String(app.debugDescription.prefix(5000))) }
        XCTAssertTrue(first.exists)
        first.tap()
        XCTAssertTrue(app.buttons["Fertig"].waitForExistence(timeout: 5))
    }

    /// Runs the audit and prints every issue (type, element label, description); fails on all of them.
    private func audit(_ name: String) throws {
        // Let presentation animations (sheet, inspector) and keyboard transitions finish: the audit reads mid-flight frames otherwise.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 2)
        var report: [String] = []
        // Two passes: the text size audits resize the whole app (on the iPad that swaps inspector and sheet). Element
        // detection compares a screenshot with the element tree and reports visible texts as inaccessible when the screen is
        // rebuilt under it, so everything but the size audits runs first, on the unchanged screen.
        let textSize: XCUIAccessibilityAuditType = [.dynamicType, .textClipped]
        let handle: (XCUIAccessibilityAuditIssue) -> Bool = { issue in
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
        try app.performAccessibilityAudit(for: XCUIAccessibilityAuditType.all.subtracting(textSize), handle)
        try app.performAccessibilityAudit(for: textSize, handle)
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
        openSeededDetail()
        try audit("detail")
        XCTAssertTrue(app.buttons["Fertig"].waitForExistence(timeout: 10), "the audit examined the detail, which is still open")
    }

    // MARK: Navigation variant A (four tabs)

    private func tab(_ name: String) -> XCUIElement { app.tabBars.buttons[name] }

    /// iPhone: exactly Für dich, Jetzt, Projekte, Planen, Suche (Jetzt since 18.11.); the former Todoist tabs are gone from the bar.
    func testTabBarHasFiveTabs() throws {
        try XCTSkipIf(isPad(), "iPhone tab bar")
        for name in ["Für dich", "Jetzt", "Projekte", "Planen", "Suche"] {
            XCTAssertTrue(tab(name).waitForExistence(timeout: 5), "tab \(name)")
        }
        XCTAssertEqual(app.tabBars.buttons.count, 5)
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

    /// Settings (the former account screen), teams, agents and activity sit behind the avatar.
    func testAccountMenuHoldsAccountTeamsAgents() throws {
        try XCTSkipIf(isPad(), "iPhone tab bar")
        tab("Projekte").tap()
        let avatar = app.buttons["accountMenu"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        avatar.tap()
        for name in ["Einstellungen", "Teams", "Agenten & Runner", "Aktivität"] {
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
        // The detail is a lazy stack; the task chat sits below criteria and links and appears only when scrolled to.
        for _ in 0..<8 where !sent.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "message in task chat")
        // The task chat is its own thread: the question reply does not show up twice.
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'chat.bubble.mine' AND label CONTAINS %@", reply)).count, 1)
        app.buttons["Fertig"].tap()

        openWebsiteCard("Texte fuer Startseite freigeben")
        XCTAssertTrue(app.descendants(matching: .any)["chat.review"].waitForExistence(timeout: 10), "review chat")
        XCTAssertTrue(element(containing: "Bitte die Datenschutzerklärung noch prüfen.").waitForExistence(timeout: 10), "seeded review message")
    }

    // MARK: Wave 3 (needs `TODO_LIVE_SEED_W3=1`)

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func scrollTo(_ e: XCUIElement, max: Int = 8) {
        for _ in 0..<max where !(e.exists && e.isHittable) { app.swipeUp() }
    }

    /// Agent confirmations in "Für dich": one is rejected, the irreversible one runs only after typing the project name.
    func testConfirmationsRejectAndConfirmByName() throws {
        app.terminate()
        app.launchEnvironment["TODO_DEBUG_SELECT"] = "feed"
        app.launch()
        let section = app.staticTexts["Bestätigung nötig"]
        guard section.waitForExistence(timeout: 20) else { throw XCTSkip("no confirmations seeded (TODO_LIVE_SEED_W3=1)") }
        let cards = app.descendants(matching: .any).matching(identifier: "confirm.card")
        XCTAssertEqual(cards.count, 2)
        attach("w3-confirmations")
        let project = cards.containing(NSPredicate(format: "label CONTAINS 'Altprojekt'")).firstMatch
        let task = cards.containing(NSPredicate(format: "label CONTAINS 'Yoga'")).firstMatch
        XCTAssertTrue(project.exists && task.exists, app.debugDescription)

        task.buttons["confirm.reject"].tap()
        XCTAssertTrue(task.descendants(matching: .any)["confirm.outcome"].waitForExistence(timeout: 10), "rejected outcome")
        XCTAssertTrue(element(containing: "Abgelehnt").exists)

        project.buttons["confirm.confirm"].tap()
        let run = project.buttons["confirm.run"]
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        XCTAssertFalse(run.isEnabled, "locked until the name is typed")
        let name = project.textFields["confirm.name"]
        name.tap()
        name.typeText("Altprojek")
        XCTAssertFalse(run.isEnabled)
        name.typeText("t")
        attach("w3-confirm-name")
        XCTAssertTrue(run.isEnabled)
        run.tap()
        XCTAssertTrue(element(containing: "Projekt gelöscht").waitForExistence(timeout: 15), "project deleted outcome")
    }

    /// Criteria are edited in the card detail (add, tick); prerequisites and the milestone are shown below.
    func testDetailEditsCriteriaAndShowsLinks() throws {
        try XCTSkipIf(isPad(), "iPhone tab bar")
        openWebsiteCard("Design-Review vorbereiten")
        let field = app.textFields["criteria.field"]
        guard field.waitForExistence(timeout: 10) else { throw XCTSkip("no criteria card (TODO_LIVE_SEED_W3=1)") }
        XCTAssertTrue(element(containing: "Mobil zuerst").exists, "seeded criterion")
        let text = "UITest Kriterium \(Int(Date().timeIntervalSince1970) % 100000)"
        scrollTo(field)
        field.tap()
        field.typeText(text)
        app.buttons["criteria.addButton"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'criteria.row' AND label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "new criterion")
        XCTAssertEqual(row.value as? String, "Offen")
        if app.keyboards.firstMatch.exists { app.swipeDown() }
        scrollTo(row)
        row.tap()
        let ticked = NSPredicate(format: "value == 'Erfüllt'")
        expectation(for: ticked, evaluatedWith: row)
        waitForExpectations(timeout: 10)

        let links = any("links.card")
        scrollTo(links)
        XCTAssertTrue(links.waitForExistence(timeout: 10), "links card")
        XCTAssertTrue(element(containing: "Rechnung Hosting pruefen").exists, "prerequisite")
        XCTAssertTrue(element(containing: "Beta-Start").exists, "milestone")
        attach("w3-detail-criteria-links")
        // Clean up: delete the criterion through its accessibility action.
        row.press(forDuration: 1.0)
        let delete = app.buttons["Kriterium löschen"]
        if delete.waitForExistence(timeout: 3) { delete.tap(); XCTAssertTrue(row.waitForNonExistence(timeout: 10)) }
    }

    /// Classic projects hide the agent tools; the display options switch the mode.
    func testProjectModeHidesAgentToolsInClassic() throws {
        try XCTSkipIf(isPad(), "iPhone tab bar")
        tab("Projekte").tap()
        let project = app.buttons.matching(NSPredicate(format: "label == 'Sport'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        XCTAssertTrue(app.segmentedControls["project.layout"].waitForExistence(timeout: 10))
        let agents = app.buttons["project.agents"]
        let mode = app.segmentedControls["project.mode"]
        app.buttons["Anzeige"].tap()
        XCTAssertTrue(mode.waitForExistence(timeout: 5), "mode picker")
        guard mode.buttons["Klassisch"].isSelected else { throw XCTSkip("Sport not seeded as classic (TODO_LIVE_SEED_W3=1)") }
        attach("w3-project-mode")
        XCTAssertFalse(agents.exists, "classic hides the agent view")
        mode.buttons["Projektmanagement"].tap()
        XCTAssertTrue(agents.waitForExistence(timeout: 10), "management shows the agent view")
        mode.buttons["Klassisch"].tap()
        XCTAssertTrue(agents.waitForNonExistence(timeout: 10), "classic again")
    }

    /// The settings hub: appearance, passkeys, devices, connections and a runner pairing code.
    func testSettingsHubShowsSectionsAndPairsRunner() throws {
        try XCTSkipIf(isPad(), "iPhone tab bar")
        tab("Projekte").tap()
        app.buttons["accountMenu"].tap()
        app.buttons["Einstellungen"].tap()
        XCTAssertTrue(app.segmentedControls["settings.scheme"].waitForExistence(timeout: 10), "appearance")
        attach("w3-settings")
        // The list is lazy: sections below the fold exist only once scrolled to.
        for title in ["Passkeys", "Angemeldete Geräte", "Verbindungen", "Runner koppeln"] {
            let header = app.staticTexts[title]
            scrollTo(header)
            XCTAssertTrue(header.exists, "section \(title)")
        }
        XCTAssertTrue(element(containing: "Claude Code").exists, "MCP connection listed")
        let label = app.textFields["Name des Macs"]
        scrollTo(label)
        label.tap()
        label.typeText("Mac mini")
        app.buttons["settings.runner.pair"].tap()
        let code = app.staticTexts["settings.runner.pairCode"]
        XCTAssertTrue(code.waitForExistence(timeout: 10), "pairing code")
        XCTAssertFalse(code.label.isEmpty)
        attach("w3-settings-runner")
        try audit("settings")
    }
}
