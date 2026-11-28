import XCTest

/// Card 6C3E3F88: the pending states of the selection editor (preview indicator, locked "Sichern") must end on success,
/// "nothing new", server error and cancel, and an old preview must never look current. Needs a scratch backend with the seed
/// of TodoCore `LiveProjectGroupsTests.testSeedGroupsTour` behind `scripts/selection-proxy.py`; run through
/// `scripts/ui-tests-selection.sh` (env `TODO_UITEST_PROXY`, `TODO_UITEST_TOKEN`, optional `TODO_TOUR_OUT` and
/// `TODO_PROOF_LOOK` for pictures), skipped otherwise. Tests expect the seeded mandate "Gruppen: Kunden" with three
/// projects: `testSaveSucceedsAndClosesTheEditor` restores it, `testSaveThenCancelWhilePending` changes it and runs last
/// (XCTest orders by name).
final class SelectionPendingTests: XCTestCase {
    private var proxy = ""
    private var token = ""
    private var app: XCUIApplication!
    private var look: String { ProcessInfo.processInfo.environment["TODO_PROOF_LOOK"] ?? "hell" }

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let proxy = env["TODO_UITEST_PROXY"], let token = env["TODO_UITEST_TOKEN"] else {
            throw XCTSkip("proxy variables not set (scripts/ui-tests-selection.sh)")
        }
        self.proxy = proxy
        self.token = token
        continueAfterFailure = false
        try control([:])
        launch()
        if !app.buttons["mandate.row.Brain"].waitForExistence(timeout: 8) {
            // The first request after an install may answer 401; a second launch reads normally.
            app.terminate()
            launch()
        }
    }

    // MARK: Preview

    func testPreviewNothingNew() throws {
        let row = try mandateRow()
        shot("nichts-neues-1-vorher")
        try control(["preview": ["delay": 5]])
        row.tap()
        assertPending()
        shot("nichts-neues-2-waehrend")
        assertCount(3)
        XCTAssertFalse(loading.exists, "indicator gone")
        XCTAssertFalse(text(beginning: "Neu:").exists, "nothing added")
        XCTAssertFalse(text(beginning: "Entfällt:").exists, "nothing removed")
        XCTAssertFalse(save.isEnabled, "nothing to save")
        shot("nichts-neues-3-nachher")
    }

    func testPreviewServerErrorEndsTheIndicator() throws {
        let row = try mandateRow()
        shot("vorschau-fehler-1-vorher")
        try control(["preview": ["delay": 4, "status": 500]])
        row.tap()
        assertPending()
        shot("vorschau-fehler-2-waehrend")
        XCTAssertTrue(failed.waitForExistence(timeout: 20), "failure text")
        XCTAssertFalse(loading.exists, "indicator gone")
        XCTAssertFalse(count.exists)
        shot("vorschau-fehler-3-nachher")
        // A failed preview does not block saving a changed selection (the server checks it anyway).
        flip("selection.project.Garten")
        assertPending()
        XCTAssertFalse(save.isEnabled, "locked while the new preview is pending")
        XCTAssertTrue(failed.waitForExistence(timeout: 20))
        XCTAssertFalse(loading.exists)
        XCTAssertTrue(save.isEnabled, "free again after the failed preview")
        XCTAssertEqual(try slowRequests("preview").map(\.status), [500, 500])
    }

    /// The old preview must not stand next to a changed selection, and "Sichern" waits for the answer that belongs to it.
    func testPreviewOfAChangedSelectionReplacesTheOldOne() throws {
        try mandateRow().tap()
        assertCount(3)
        shot("vorschau-wechsel-1-vorher")
        try control(["preview": ["delay": 6]])
        flip("selection.project.Garten")
        Thread.sleep(forTimeInterval: 1.5)
        shot("vorschau-wechsel-2-waehrend")
        XCTAssertFalse(count.exists, "the preview of the old selection is gone: \(count.exists ? count.label : "")")
        XCTAssertTrue(loading.exists, "indicator while the new preview is pending")
        XCTAssertFalse(save.isEnabled, "locked while the preview is pending")
        assertCount(4)
        XCTAssertFalse(loading.exists)
        XCTAssertTrue(text(beginning: "Neu: Garten").exists)
        XCTAssertTrue(save.isEnabled)
        shot("vorschau-wechsel-3-nachher")
    }

    func testPreviewCancelledByAnotherChange() throws {
        try mandateRow().tap()
        assertCount(3)
        shot("vorschau-abbruch-aenderung-1-vorher")
        try control(["preview": ["delay": 6]])
        flip("selection.project.Garten")
        Thread.sleep(forTimeInterval: 3)
        flip("selection.project.Umzug / Kueche")
        let secondChange = Date()
        // The first answer arrives about 3 s after the second change; it belongs to a cancelled request and must not show.
        Thread.sleep(forTimeInterval: 4)
        XCTAssertLessThan(Date().timeIntervalSince(secondChange), 6, "still inside the second request")
        XCTAssertFalse(count.exists, "neither the old preview nor the cancelled answer shows: \(count.exists ? count.label : "")")
        XCTAssertTrue(loading.exists)
        XCTAssertFalse(save.isEnabled)
        shot("vorschau-abbruch-aenderung-2-waehrend")
        assertCount(5)
        XCTAssertFalse(loading.exists)
        XCTAssertTrue(save.isEnabled)
        shot("vorschau-abbruch-aenderung-3-nachher")
        XCTAssertEqual(try slowRequests("preview").count, 2)
    }

    func testPreviewCancelledByClosingTheSheet() throws {
        let row = try mandateRow()
        try control(["preview": ["delay": 6]])
        shot("vorschau-schliessen-1-vorher")
        row.tap()
        assertPending()
        shot("vorschau-schliessen-2-waehrend")
        app.buttons["sheet.cancel"].tap()
        XCTAssertTrue(waitGone(app.buttons["selection.save"]), "sheet closed")
        XCTAssertFalse(loading.exists, "indicator gone with the sheet")
        Thread.sleep(forTimeInterval: 8) // the late answer has arrived
        XCTAssertFalse(app.alerts.firstMatch.exists, "a cancelled preview reports nothing")
        XCTAssertFalse(loading.exists)
        XCTAssertTrue(row.isHittable)
        shot("vorschau-schliessen-3-nachher")
        try control([:])
        row.tap()
        assertCount(3)
        XCTAssertFalse(loading.exists, "reopened sheet ends normally")
    }

    // MARK: Save

    func testSaveFailureKeepsTheEditorAndUnlocks() throws {
        try mandateRow().tap()
        assertCount(3)
        flip("selection.project.Garten")
        assertCount(4)
        XCTAssertTrue(save.isEnabled)
        shot("speichern-fehler-1-vorher")
        try control(["save": ["delay": 5, "status": 500]])
        save.tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(save.isEnabled, "locked while saving")
        shot("speichern-fehler-2-waehrend")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "the failure is reported")
        XCTAssertTrue(alert.label.contains("Etwas ist schiefgelaufen") || alert.staticTexts.element(matching: NSPredicate(format: "label BEGINSWITH %@", "Etwas ist schiefgelaufen")).exists, alert.debugDescription)
        shot("speichern-fehler-3-nachher")
        alert.buttons["OK"].tap()
        XCTAssertTrue(waitGone(alert))
        XCTAssertTrue(save.isEnabled, "free again")
        XCTAssertEqual(app.switches["selection.project.Garten"].value as? String, "1", "the choice is kept")
        shot("speichern-fehler-4-frei")
        app.buttons["sheet.cancel"].tap()
        XCTAssertTrue(waitGone(app.buttons["selection.save"]))
        let row = try mandateRow()
        XCTAssertTrue(row.label.contains("3 Projekte"), "nothing stored: \(row.label)")
        XCTAssertEqual(try slowRequests("save").map(\.forwarded), [false])
    }

    /// Stores one more project and takes it out again, so the following test sees the seeded mandate.
    func testSaveSucceedsAndClosesTheEditor() throws {
        try mandateRow().tap()
        assertCount(3)
        flip("selection.project.Garten")
        assertCount(4)
        shot("speichern-erfolg-1-vorher")
        try control(["save": ["delay": 5]])
        save.tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(save.isEnabled, "locked while saving")
        shot("speichern-erfolg-2-waehrend")
        XCTAssertTrue(waitGone(save), "editor closes after saving")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        var row = try mandateRow()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "4 Projekte"), evaluatedWith: row)
        waitForExpectations(timeout: 15)
        shot("speichern-erfolg-3-nachher")
        try control([:])
        row.tap()
        assertCount(4)
        XCTAssertFalse(save.isEnabled, "no lock to see, but nothing changed yet")
        flip("selection.project.Garten")
        assertCount(3)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(waitGone(save))
        row = try mandateRow()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "3 Projekte"), evaluatedWith: row)
        waitForExpectations(timeout: 15)
    }

    /// "Abbrechen" closes the sheet but does not take back a request that is already on its way: a failure is then silent
    /// and leaves no lock behind, a success is stored and shown in the list.
    func testSaveThenCancelWhilePending() throws {
        // 1. Cancel, then the save fails.
        try mandateRow().tap()
        assertCount(3)
        flip("selection.project.Garten")
        assertCount(4)
        try control(["save": ["delay": 5, "status": 500]])
        save.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(save.isEnabled)
        app.buttons["sheet.cancel"].tap()
        XCTAssertTrue(waitGone(app.buttons["selection.save"]), "cancel closes while saving")
        Thread.sleep(forTimeInterval: 7)
        XCTAssertFalse(app.alerts.firstMatch.exists, "no message on the closed sheet")
        var row = try mandateRow()
        XCTAssertTrue(row.label.contains("3 Projekte"), row.label)
        try control([:])
        row.tap()
        assertCount(3)
        XCTAssertEqual(app.switches["selection.project.Garten"].value as? String, "0")
        flip("selection.project.Garten")
        assertCount(4)
        XCTAssertTrue(save.isEnabled, "no lock left over")
        shot("speichern-abbruch-1-vorher")
        // 2. Cancel, and the save succeeds.
        try control(["save": ["delay": 6]])
        save.tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(save.isEnabled)
        shot("speichern-abbruch-2-waehrend")
        app.buttons["sheet.cancel"].tap()
        XCTAssertTrue(waitGone(app.buttons["selection.save"]))
        row = try mandateRow()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "4 Projekte"), evaluatedWith: row)
        waitForExpectations(timeout: 20)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        shot("speichern-abbruch-3-nachher")
        XCTAssertEqual(try slowRequests("save").map(\.status), [200])
    }

    // MARK: Helpers

    private var save: XCUIElement { app.buttons["selection.save"] }
    private var count: XCUIElement { app.staticTexts["selection.preview.count"] }
    private var loading: XCUIElement { text(beginning: "Vorschau wird berechnet") }
    private var failed: XCUIElement { text(beginning: "Vorschau nicht verfügbar") }

    private func text(beginning prefix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func launch() {
        app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_SERVER"] = proxy
        app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        app.launchEnvironment["TODO_DEBUG_SELECT"] = "account"
        app.launchArguments += ["-appearance.colorScheme", look == "dunkel" ? "dark" : "light"]
        app.launch()
    }

    private func assertPending(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(loading.waitForExistence(timeout: 3), "preview indicator", file: file, line: line)
        XCTAssertFalse(count.exists, "no preview yet", file: file, line: line)
    }

    private func assertCount(_ n: Int, file: StaticString = #filePath, line: UInt = #line) {
        let wanted = NSPredicate(format: "exists == true AND label CONTAINS %@", "Wirkt jetzt auf \(n) Projekte")
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: wanted, object: count)], timeout: 20)
        // Seen once under load (28.11.2026): no preview and no preview request after the tap on the row. Say what is on
        // screen then, to tell "the editor never opened" from "it opened and asked nothing".
        var state = ""
        if result != .completed {
            shot("fehler-vorschau-\(n)")
            let row = app.buttons["mandate.row.Brain"]
            state = " (editor open: \(save.exists), pending: \(loading.exists), failed: \(failed.exists), row enabled: \(row.exists ? "\(row.isEnabled)" : "row not found"))"
        }
        XCTAssertEqual(result, .completed, "preview with \(n) projects: \(count.exists ? count.label : "none")\(state)", file: file, line: line)
    }

    private func flip(_ identifier: String) {
        let toggle = app.switches[identifier]
        for _ in 0..<5 where !(toggle.exists && toggle.isHittable) { app.swipeUp() }
        // The element's center is the label; the real switch sits at the trailing edge of the row.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    /// The mandate row of the settings, scrolled into the upper part of the screen.
    private func mandateRow() throws -> XCUIElement {
        let row = app.buttons["mandate.row.Brain"]
        _ = row.waitForExistence(timeout: 30)
        let height = app.windows.firstMatch.frame.height
        for _ in 0..<40 where !row.exists || !row.isHittable || row.frame.maxY > height * 0.6 {
            let from = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let to = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        XCTAssertTrue(row.exists && row.isHittable, "mandate row")
        return row
    }

    private func waitGone(_ element: XCUIElement) -> Bool {
        let gone = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: element)], timeout: 10) == .completed
    }

    private struct SlowRequest: Decodable { let rule: String; let status: Int; let forwarded: Bool }

    private func control(_ rules: [String: Any]) throws {
        _ = try call("/__control", body: try JSONSerialization.data(withJSONObject: rules))
    }

    private func slowRequests(_ rule: String) throws -> [SlowRequest] {
        try JSONDecoder().decode([SlowRequest].self, from: call("/__log", body: nil)).filter { $0.rule == rule }
    }

    private func call(_ path: String, body: Data?) throws -> Data {
        var request = URLRequest(url: try XCTUnwrap(URL(string: proxy + path)))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        let done = expectation(description: path)
        nonisolated(unsafe) var result: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { result = data }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result, "proxy answers \(path)")
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["TODO_TOUR_OUT"] else { return }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(look)-\(name).png"))
    }
}
