import XCTest

/// Local helper, not part of the regular suite (card 8CECAD24, phase 1: static calendar preview with sample data): launches
/// the real app with `TODO_DEBUG_CALENDAR_PREVIEW=1` (no server, no account) and writes PNGs. Needs `TODO_TOUR_OUT` (directory).
/// iPhone: day list light and dark, the sheet "Ohne Termin" (real tap) light, day list at large text (AccessibilityXL =
/// accessibility3). iPad: week grid light and dark. File names: `<ansicht>-<hell|dunkel>[-accessibility3].png`.
final class CalendarPreviewTour: XCTestCase {
    private var out = ""

    func testTour() throws {
        guard let dir = ProcessInfo.processInfo.environment["TODO_TOUR_OUT"] else { throw XCTSkip("TODO_TOUR_OUT not set") }
        out = dir
        continueAfterFailure = false
        let pad = UIDevice.current.userInterfaceIdiom == .pad

        if pad {
            for look in ["hell", "dunkel"] {
                let app = launch(dark: look == "dunkel", large: false)
                Thread.sleep(forTimeInterval: 6)
                shot("wochenraster-\(look)", app)
                XCTAssertTrue(app.descendants(matching: .any)["calendar.sidePanel"].exists, "week grid with side panel (\(look))")
                app.terminate()
            }
            return
        }

        for look in ["hell", "dunkel"] {
            let app = launch(dark: look == "dunkel", large: false)
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

        let large = launch(dark: false, large: true)
        XCTAssertTrue(large.buttons["calendar.unscheduledButton"].waitForExistence(timeout: 20), "day list at large text")
        Thread.sleep(forTimeInterval: 2)
        shot("tagesliste-hell-accessibility3", large)
        // The cards of the day, scrolled into view (the header takes most of the first screen at this size).
        for _ in 0..<2 { large.swipeUp() }
        Thread.sleep(forTimeInterval: 1)
        shot("tagesliste-karten-hell-accessibility3", large)
        large.terminate()
    }

    private func launch(dark: Bool, large: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_CALENDAR_PREVIEW"] = "1"
        app.launchArguments += ["-appearance.colorScheme", dark ? "dark" : "light"]
        app.launchArguments += ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXL" : "UICTContentSizeCategoryL"]
        app.launch()
        return app
    }

    /// The app's own screenshot follows the interface orientation (the screen's stays in the device's native portrait).
    private func shot(_ name: String, _ app: XCUIApplication) {
        let png = app.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }
}
