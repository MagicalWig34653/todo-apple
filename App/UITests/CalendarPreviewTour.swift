import XCTest

/// Local helper, not part of the regular suite (card 8CECAD24): launches the real app with `TODO_DEBUG_CALENDAR_PREVIEW=1`
/// (sample data, no server, no account; writes only change the local copy) and writes PNGs. Needs `TODO_TOUR_OUT` (directory).
/// File names: `<ansicht>-<hell|dunkel>[-accessibility3|-xxxl].png`. Phone: the iPhone tests; iPad: the iPad tests (skipped on the other idiom).
final class CalendarPreviewTour: XCTestCase {
    private var out = ""
    private let pad = UIDevice.current.userInterfaceIdiom == .pad

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["TODO_TOUR_OUT"] else { throw XCTSkip("TODO_TOUR_OUT not set") }
        out = dir
        continueAfterFailure = false
    }

    // MARK: iPhone

    func testPhoneDayListAndSheets() throws {
        try XCTSkipIf(pad, "iPhone only")
        for look in ["hell", "dunkel"] {
            let app = launch(dark: look == "dunkel")
            XCTAssertTrue(app.buttons["calendar.unscheduledButton"].waitForExistence(timeout: 20), "day list (\(look))")
            Thread.sleep(forTimeInterval: 2)
            shot("tagesliste-\(look)", app)
            if look == "hell" {
                app.buttons["calendar.unscheduledButton"].tap()
                XCTAssertTrue(app.navigationBars["Ohne Termin"].waitForExistence(timeout: 10), "sheet Ohne Termin")
                Thread.sleep(forTimeInterval: 2)
                shot("ohne-termin-blatt-hell", app)
            }
            app.terminate()
        }
    }

    func testPhoneLargeTextWeekStripCentered() throws {
        try XCTSkipIf(pad, "iPhone only")
        let app = launch(dark: false, content: "UICTContentSizeCategoryAccessibilityXL")
        XCTAssertTrue(app.buttons["calendar.unscheduledButton"].waitForExistence(timeout: 20), "day list at large text")
        Thread.sleep(forTimeInterval: 2)
        shot("tagesliste-hell-accessibility3", app)
        for _ in 0..<2 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1)
        shot("tagesliste-karten-hell-accessibility3", app)
        app.terminate()
    }

    func testPhoneDetailEditorAndRollbackHint() throws {
        try XCTSkipIf(pad, "iPhone only")
        // Full title, project, start, duration, due date: the long title is the one the grid truncates.
        let app = launch(dark: false)
        let long = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'calendar.card.Dokumentation'")).firstMatch
        XCTAssertTrue(long.waitForExistence(timeout: 20), "card with the long title")
        scrollTo(long, app)
        long.tap()
        XCTAssertTrue(app.staticTexts["calendar.detail.title"].waitForExistence(timeout: 10), "detail sheet")
        Thread.sleep(forTimeInterval: 1.5)
        shot("detail-karte-hell", app)
        app.buttons["calendar.detail.edit"].tap()
        XCTAssertTrue(app.switches["calendar.editor.allDay"].waitForExistence(timeout: 10), "editor")
        Thread.sleep(forTimeInterval: 1.5)
        shot("start-und-dauer-hell", app)
        app.terminate()

        // A failing write (sample: 409): optimistic move, rollback, hint.
        let failing = launch(dark: false, failure: "conflict")
        let card = failing.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'calendar.card.Kalender-Raster'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "card to unschedule")
        card.press(forDuration: 1.2)
        XCTAssertTrue(failing.buttons["Entplanen"].waitForExistence(timeout: 10), "context menu")
        failing.buttons["Entplanen"].tap()
        XCTAssertTrue(failing.descendants(matching: .any)["calendar.notice"].waitForExistence(timeout: 10), "rollback hint")
        XCTAssertTrue(card.exists, "the card is back")
        Thread.sleep(forTimeInterval: 1)
        shot("rollback-hinweis-hell", failing)
        failing.terminate()
    }

    func testPhoneEditSavesLocallyInTheSample() throws {
        try XCTSkipIf(pad, "iPhone only")
        let app = launch(dark: false)
        let card = app.buttons["calendar.card.Review der Push-Vorschau"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()
        app.buttons["calendar.detail.edit"].tap()
        app.switches["calendar.editor.allDay"].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["calendar.editor.save"].tap()
        XCTAssertTrue(app.buttons["calendar.card.Review der Push-Vorschau"].staticTexts["Ganztägig"].waitForExistence(timeout: 10), "now an all-day card")
        app.terminate()
    }

    // MARK: iPad

    func testPadWeekGridPortrait() throws {
        try XCTSkipUnless(pad, "iPad only")
        for look in ["hell", "dunkel"] {
            let app = launch(dark: look == "dunkel")
            Thread.sleep(forTimeInterval: 6)
            shot("wochenraster-\(look)", app)
            XCTAssertTrue(app.descendants(matching: .any)["calendar.sidePanel"].exists, "week grid with side panel (\(look))")
            app.terminate()
        }
    }

    func testPadLandscapeAndLargeText() throws {
        try XCTSkipUnless(pad, "iPad only")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch(dark: false)
        Thread.sleep(forTimeInterval: 6)
        screenShot("wochenraster-quer-hell")
        app.terminate()
        // Large but not an accessibility size: the grid stays (hour height and columns scale with the text).
        let large = launch(dark: false, content: "UICTContentSizeCategoryXXXL")
        Thread.sleep(forTimeInterval: 6)
        screenShot("wochenraster-quer-hell-xxxl")
        large.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func testPadOverlappingBlockDetailAndDrag() throws {
        try XCTSkipUnless(pad, "iPad only")
        let app = launch(dark: false)
        Thread.sleep(forTimeInterval: 6)
        // Overlapping 09:00 block with a truncated title: a tap shows everything.
        let block = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Kalender-Raster umsetzen'")).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 20), "overlapping block")
        block.tap()
        XCTAssertTrue(app.staticTexts["calendar.detail.title"].waitForExistence(timeout: 10), "detail")
        Thread.sleep(forTimeInterval: 1.5)
        shot("ueberlappung-detail-hell", app)
        app.buttons["calendar.detail.close"].tap()
        Thread.sleep(forTimeInterval: 1)

        // Drag a block three hours down (the sample accepts the write locally).
        let moving = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Datenschutzerklärung aktualisieren'")).firstMatch
        XCTAssertTrue(moving.waitForExistence(timeout: 10), "block to drag")
        let before = moving.frame
        let from = moving.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        from.press(forDuration: 1.0, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 156)), withVelocity: .slow, thenHoldForDuration: 1.0)
        Thread.sleep(forTimeInterval: 2)
        shot("ziehen-nachher-hell", app)
        let after = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Datenschutzerklärung aktualisieren'")).firstMatch
        XCTAssertTrue(after.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(after.frame.minY, before.minY + 100, "the block moved down by about three hours")
        app.terminate()
    }

    // MARK: Helpers

    private func launch(dark: Bool, content: String = "UICTContentSizeCategoryL", failure: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_CALENDAR_PREVIEW"] = "1"
        if let failure { app.launchEnvironment["TODO_DEBUG_CALENDAR_FAIL"] = failure }
        app.launchArguments += ["-appearance.colorScheme", dark ? "dark" : "light"]
        app.launchArguments += ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", content]
        app.launch()
        return app
    }

    /// Landscape: the screen's own capture (the app's capture is cropped); it comes in the device's native portrait
    /// orientation, so the file is turned upright afterwards (`sips -r 270`, noted in docs/CALENDAR.md).
    private func screenShot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(out)/\(name)-roh.png"))
    }

    private func scrollTo(_ element: XCUIElement, _ app: XCUIApplication) {
        var n = 0
        while !element.isHittable && n < 8 { app.swipeUp(); n += 1 }
    }

    /// The app's own screenshot follows the interface orientation (the screen's stays in the device's native portrait).
    private func shot(_ name: String, _ app: XCUIApplication) {
        let png = app.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }
}
