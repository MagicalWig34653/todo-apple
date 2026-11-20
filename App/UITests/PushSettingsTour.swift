import XCTest

/// Local helper, not part of the regular suite (card 9B691C3A, preview of the confirmation and daily brief switches):
/// launches the real app against a scratch backend with push prefs (any fresh account) and writes PNGs of settings >
/// notifications, with real taps on the "Tagesbericht" switch. Needs `TODO_UITEST_SERVER`, `TODO_UITEST_TOKEN`,
/// `TODO_TOUR_OUT` (directory). The account's prefs end where they began (daily brief off).
/// File names: `tagesbericht-<aus|an>-<hell|dunkel>[-accessibility3].png` (large text: only the "an" state).
final class PushSettingsTour: XCTestCase {
    private var out = ""

    func testTour() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"], let dir = env["TODO_TOUR_OUT"] else {
            throw XCTSkip("tour variables not set")
        }
        out = dir
        continueAfterFailure = false

        // A throw-away launch absorbs the 401 the first request after an install may answer.
        let warm = XCUIApplication()
        warm.launchEnvironment["TODO_DEBUG_SERVER"] = server
        warm.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        warm.launchEnvironment["TODO_DEBUG_SELECT"] = "account"
        warm.launch()
        Thread.sleep(forTimeInterval: 8)
        warm.terminate()

        for look in ["hell", "dunkel", "hell-accessibility3"] {
            let dark = look.hasPrefix("dunkel"), large = look.hasSuffix("accessibility3")
            let app = XCUIApplication()
            app.launchEnvironment["TODO_DEBUG_SERVER"] = server
            app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
            app.launchEnvironment["TODO_DEBUG_SELECT"] = "account"
            app.launchArguments += ["-appearance.colorScheme", dark ? "dark" : "light"]
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXL" : "UICTContentSizeCategoryL"]
            app.launch()

            let brief = app.switches["push.cat.dailyBrief"]
            let time = app.descendants(matching: .any)["push.dailyBrief.time"]
            XCTAssertTrue(reveal(app, brief), "daily brief switch (\(look))")
            XCTAssertTrue(app.switches["push.cat.confirmations"].exists, "confirmations switch (\(look))")
            XCTAssertEqual(brief.value as? String, "0", "daily brief starts off")
            XCTAssertFalse(time.exists, "no time picker while off")
            if !large { shot("tagesbericht-aus-\(look)") }

            flip(brief)
            if !time.waitForExistence(timeout: 15), let debug = ProcessInfo.processInfo.environment["TODO_TOUR_DEBUG"] {
                try? app.debugDescription.write(toFile: "\(debug)/tree-\(look).txt", atomically: true, encoding: .utf8)
                try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(debug)/fail-\(look).png"))
            }
            XCTAssertTrue(time.exists, "time picker after switching on (\(look))")
            XCTAssertEqual(app.switches["push.cat.dailyBrief"].value as? String, "1")
            XCTAssertTrue(reveal(app, app.switches["push.cat.dailyBrief"]), "switch still visible")
            Thread.sleep(forTimeInterval: 2)
            shot("tagesbericht-an-\(look)")

            // Reset the account for the next look (real tap again).
            flip(app.switches["push.cat.dailyBrief"])
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: time)
            waitForExpectations(timeout: 15)
            app.terminate()
        }
    }

    /// The element's center is the label; the real switch sits at the trailing edge of the row.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    /// Scrolls the settings list with deterministic drags until the element sits in the upper part of the screen.
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        if !element.waitForExistence(timeout: 30) {
            // The list is lazy: sections below the fold exist only once scrolled to.
            for _ in 0..<25 where !element.exists { drag(app) }
        }
        var n = 0
        let height = app.windows.firstMatch.frame.height
        while element.exists && (!element.isHittable || element.frame.maxY > height * 0.7) && n < 40 { drag(app); n += 1 }
        return element.exists && element.isHittable
    }

    private func drag(_ app: XCUIApplication) {
        let from = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let to = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        from.press(forDuration: 0.05, thenDragTo: to)
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }
}
