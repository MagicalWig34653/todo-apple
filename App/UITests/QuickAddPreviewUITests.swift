import XCTest

/// Quick-add preview (card 8DB7E4F8): while typing, the sheet shows what it understood (due date, repetition) and the
/// lines vanish again when the text is removed. Real app against the real backend; nothing is saved.
/// Needs `TODO_UITEST_SERVER` / `TODO_UITEST_TOKEN` like `TodoUITests` (skipped without). With `TODO_TOUR_OUT=<dir>` it also
/// writes PNGs before / while / after typing. The look (`TODO_TOUR_LOOK=light|dark`) only names the files: the appearance itself
/// is set on the simulator (`simctl ui <udid> appearance dark`, run with `TODO_UITEST_DEVICE`); neither the launch argument
/// nor `XCUIDevice.appearance` takes effect here.
@MainActor
final class QuickAddPreviewUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["TODO_UITEST_SERVER"] != nil else {
            throw XCTSkip("TODO_UITEST_SERVER / TODO_UITEST_TOKEN not set")
        }
    }

    private var look: String { ProcessInfo.processInfo.environment["TODO_TOUR_LOOK"] ?? "light" }

    private func launch() {
        let env = ProcessInfo.processInfo.environment
        app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_SERVER"] = env["TODO_UITEST_SERVER"]
        app.launchEnvironment["TODO_DEBUG_TOKEN"] = env["TODO_UITEST_TOKEN"]
        app.launchEnvironment["TODO_DEBUG_SELECT"] = "today"
        app.launchEnvironment["TODO_DEBUG_NOW"] = "12:00"
        app.launch()
    }

    private func shot(_ name: String) {
        guard let out = ProcessInfo.processInfo.environment["TODO_TOUR_OUT"] else { return }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testPreviewAppearsAndDisappears() {
        launch()
        XCTAssertTrue(app.buttons["quickAddButton"].waitForExistence(timeout: 30))
        app.buttons["quickAddButton"].tap()
        let field = app.textFields["quickAddTitle"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        if let existing = field.value as? String, !existing.isEmpty, existing != "Was ist zu tun?" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }

        // Before: plain sheet, nothing recognised.
        XCTAssertFalse(element("quickAddPreviewDue").exists, "no due preview before typing")
        XCTAssertFalse(element("quickAddPreviewRepeat").exists, "no repeat preview before typing")
        shot("quickadd-\(look)-1-vorher")

        // While: the repetition (with interval) and the due date it implies appear.
        let text = "Pflanzen giessen alle 2 Wochen"
        field.typeText(text)
        // First keyboard use on a fresh simulator shows the glide-typing intro; it covers the lower half and nothing else.
        if app.buttons["Continue"].waitForExistence(timeout: 2) { app.buttons["Continue"].tap() }
        let repeatLine = element("quickAddPreviewRepeat")
        XCTAssertTrue(repeatLine.waitForExistence(timeout: 5), "repeat preview appears")
        XCTAssertTrue(repeatLine.label.contains("Alle 2 Wochen"), "repeat preview names the interval: \(repeatLine.label)")
        let dueLine = element("quickAddPreviewDue")
        XCTAssertTrue(dueLine.waitForExistence(timeout: 5), "due preview appears")
        XCTAssertTrue(dueLine.label.contains("Heute"), "a repetition without a date starts today: \(dueLine.label)")
        shot("quickadd-\(look)-2-waehrend-wiederholung")

        // A typed date replaces the implied one.
        field.typeText(" 15.12.")
        let absolute = NSPredicate(format: "label CONTAINS %@", "15. Dez")
        expectation(for: absolute, evaluatedWith: element("quickAddPreviewDue"))
        waitForExpectations(timeout: 5)
        shot("quickadd-\(look)-3-waehrend-datum")

        // After: removing the text removes the preview.
        let typed = text.count + " 15.12.".count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed))
        XCTAssertTrue(element("quickAddPreviewRepeat").waitForNonExistence(timeout: 5), "repeat preview disappears with the text")
        XCTAssertTrue(element("quickAddPreviewDue").waitForNonExistence(timeout: 5), "due preview disappears with the text")
        shot("quickadd-\(look)-4-nachher")
        app.terminate()
    }
}
