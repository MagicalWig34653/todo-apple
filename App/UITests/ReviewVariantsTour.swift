import XCTest

/// Local helper, not part of the regular suite (card 1D9C8B0C, review with variants): launches the real app against a seeded
/// backend (`LiveReviewVariantsTests.testSeedVariantReviews`) and writes PNGs of the real screens, including real taps on
/// "Wählen" and the undo bar. Needs `TODO_UITEST_SERVER`, `TODO_UITEST_TOKEN`, `TODO_TOUR_OUT` (directory), optional
/// `TODO_TOUR_PREFIX` (default "iphone") and `TODO_TOUR_LOOKS` (default `light-ax,light,dark`: the looks that choose come last, a chosen review leaves the pending lists).
final class ReviewVariantsTour: XCTestCase {
    private var out = ""
    private var prefix = "iphone"

    func testTour() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"], let dir = env["TODO_TOUR_OUT"] else {
            throw XCTSkip("tour variables not set")
        }
        out = dir
        prefix = env["TODO_TOUR_PREFIX"] ?? "iphone"
        let looks = (env["TODO_TOUR_LOOKS"] ?? "light-ax,light,dark").split(separator: ",").map(String.init)

        // The very first launch after an install answered 401 to its first requests (session expired screen); a throw-away
        // launch absorbs that so the shots show the real screens.
        let warm = XCUIApplication()
        warm.launchEnvironment["TODO_DEBUG_SERVER"] = server
        warm.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        warm.launchEnvironment["TODO_DEBUG_SELECT"] = "feed"
        warm.launch()
        Thread.sleep(forTimeInterval: 8)
        warm.terminate()

        for look in looks {
            let dark = look.hasPrefix("dark"), ax = look.hasSuffix("ax")

            func launch(_ select: String, mode: String? = nil) -> XCUIApplication {
                let app = XCUIApplication()
                app.launchEnvironment["TODO_DEBUG_SERVER"] = server
                app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
                app.launchEnvironment["TODO_DEBUG_SELECT"] = select
                if let mode { app.launchEnvironment["TODO_DEBUG_CC_MODE"] = mode }
                app.launchArguments += ["-push.primerDismissed", "YES"] // the notification primer would cover the cards
                // Neither -AppleInterfaceStyle nor XCUIDevice.appearance changed the look in this simulator (the "dark" shots came out
                // light, caught by looking at them); the app's own appearance setting (UserDefaults) does.
                app.launchArguments += ["-appearance.colorScheme", dark ? "dark" : "light"]
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", ax ? "UICTContentSizeCategoryAccessibilityXL" : "UICTContentSizeCategoryL"]
                app.launch()
                return app
            }

            // 1. Review with three picture variants (task detail) and the same review in the command center list.
            var app = launch("task:Kartenwahl ShowerNow")
            XCTAssertTrue(app.buttons["Wählen: Variante A, Windkarte"].waitForExistence(timeout: 30), "variant cards in the task detail")
            shot("1a-bilder-varianten-oben-\(look)")
            XCTAssertTrue(reveal(app, "Wählen: Variante B, Radarkarte").isHittable, "choose button B with picture")
            Thread.sleep(forTimeInterval: 3) // pictures load through the authenticated preview route
            shot("1-bilder-varianten-\(look)")
            app.terminate()

            // 2. Text-only variants: no picture area.
            app = launch("task:Wetterdaten-Anbieter")
            XCTAssertTrue(reveal(app, "Wählen: Variante A, Open-Meteo").isHittable, "choose button A text only")
            shot("2-text-varianten-\(look)")
            app.terminate()

            // 3. Command center with the review cards (a plain review without variants stays as before).
            app = launch("commandcenter", mode: "list")
            XCTAssertTrue(app.staticTexts["Wahl nötig"].firstMatch.waitForExistence(timeout: 30), "badge in the command center")
            shot("3-steuerzentrale-\(look)")
            app.swipeUp()
            Thread.sleep(forTimeInterval: 3)
            shot("3b-steuerzentrale-gescrollt-\(look)")
            app.terminate()

            // 4. A real tap on "Wählen": the review is accepted with that variant, the undo bar names the choice and the time.
            let (task, button) = dark ? ("Anbieter Dunkel", "Wählen: Variante B, Wetterdienst A") : ("Anbieter Hell", "Wählen: Variante B, Wetterdienst A")
            guard (look == "light" || look == "dark"), env["TODO_TOUR_CHOOSE"] != "0" else { continue }
            app = launch("task:\(task)")
            let choose = reveal(app, button)
            XCTAssertTrue(choose.isHittable, "choose button before tapping")
            choose.tap()
            let bar = app.otherElements["review.undo.bar"]
            XCTAssertTrue(bar.waitForExistence(timeout: 20), "undo bar after the choice")
            XCTAssertTrue(app.staticTexts["Variante B gewählt: Wetterdienst A"].firstMatch.waitForExistence(timeout: 10), "choice text")
            XCTAssertTrue(app.buttons["Rückgängig"].exists, "undo button")
            Thread.sleep(forTimeInterval: 2)
            shot("4-nach-wahl-text-\(look)")
            var up = 0
            while !app.staticTexts["Agent"].firstMatch.isHittable && up < 12 { drag(app, up: false); up += 1 }
            Thread.sleep(forTimeInterval: 1)
            shot("4b-nach-wahl-ergebnis-\(look)")
            app.terminate()

            // 5. Same with a picture variant.
            if dark {
                app = launch("task:Karte Wahl Bild")
                let pictureChoose = reveal(app, "Wählen: Variante B, Radarkarte")
                XCTAssertTrue(pictureChoose.isHittable)
                pictureChoose.tap()
                XCTAssertTrue(app.otherElements["review.undo.bar"].waitForExistence(timeout: 20))
                Thread.sleep(forTimeInterval: 3)
                var back = 0
                while !app.staticTexts["Agent"].firstMatch.isHittable && back < 12 { drag(app, up: false); back += 1 }
                Thread.sleep(forTimeInterval: 2)
                shot("5-nach-wahl-bild-ergebnis-\(look)")
                app.terminate()
            }
        }
    }

    /// The variant cards sit in lazy containers: wait for the button, then scroll until it can be hit.
    private func reveal(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let button = app.buttons[label]
        guard button.waitForExistence(timeout: 30) else { return button }
        var swipes = 0
        while !button.isHittable && swipes < 60 {
            if swipes % 4 == 3 { app.scrollViews.firstMatch.swipeUp() } else { drag(app, up: true) }
            swipes += 1
        }
        return button
    }

    /// One deterministic drag over the middle of the screen (swipe gestures did not scroll the large-text detail).
    private func drag(_ app: XCUIApplication, up: Bool) {
        let from = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.75 : 0.35))
        let to = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.35 : 0.75))
        from.press(forDuration: 0.05, thenDragTo: to)
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(out)/\(prefix)-\(name).png"))
    }
}
