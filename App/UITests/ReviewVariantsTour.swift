import XCTest

/// Local helper, not part of the regular suite (card 1D9C8B0C, review with variants): launches the real app against a seeded
/// backend (`LiveReviewVariantsTests.testSeedVariantReviews`) and writes PNGs of the real screens, including real taps on
/// "Wählen" and the undo bar. Needs `TODO_UITEST_SERVER`, `TODO_UITEST_TOKEN`, `TODO_TOUR_OUT` (directory), optional
/// `TODO_TOUR_PREFIX` (default "iphone") and `TODO_TOUR_LOOKS` (default `light,dark,light-ax`).
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
        let looks = (env["TODO_TOUR_LOOKS"] ?? "light,dark,light-ax").split(separator: ",").map(String.init)

        for look in looks {
            let dark = look.hasPrefix("dark"), ax = look.hasSuffix("ax")
            func launch(_ select: String, mode: String? = nil) -> XCUIApplication {
                let app = XCUIApplication()
                app.launchEnvironment["TODO_DEBUG_SERVER"] = server
                app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
                app.launchEnvironment["TODO_DEBUG_SELECT"] = select
                if let mode { app.launchEnvironment["TODO_DEBUG_CC_MODE"] = mode }
                app.launchArguments += ["-AppleInterfaceStyle", dark ? "Dark" : "Light"]
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", ax ? "UICTContentSizeCategoryAccessibilityXL" : "UICTContentSizeCategoryL"]
                app.launch()
                return app
            }

            // 1. Review with three picture variants (task detail) and the same review in the command center list.
            var app = launch("task:Kartenwahl ShowerNow")
            XCTAssertTrue(app.buttons["Wählen: Variante B, Radarkarte"].waitForExistence(timeout: 30), "choose button B with picture")
            Thread.sleep(forTimeInterval: 3) // pictures load through the authenticated preview route
            shot("1-bilder-varianten-\(look)")
            app.terminate()

            // 2. Text-only variants: no picture area.
            app = launch("task:Wetterdaten-Anbieter")
            XCTAssertTrue(app.buttons["Wählen: Variante A, Open-Meteo"].waitForExistence(timeout: 30), "choose button A text only")
            shot("2-text-varianten-\(look)")
            app.terminate()

            // 3. Command center with the review cards (a plain review without variants stays as before).
            app = launch("commandcenter", mode: "list")
            XCTAssertTrue(app.staticTexts["Wahl nötig"].firstMatch.waitForExistence(timeout: 30), "badge in the command center")
            shot("3-steuerzentrale-\(look)")
            app.terminate()

            // 4. A real tap on "Wählen": the review is accepted with that variant, the undo bar names the choice and the time.
            let (task, button) = dark ? ("Anbieter Dunkel", "Wählen: Variante B, Wetterdienst A") : ("Anbieter Hell", "Wählen: Variante B, Wetterdienst A")
            guard look == "light" || look == "dark" else { continue }
            app = launch("task:\(task)")
            let choose = app.buttons[button]
            XCTAssertTrue(choose.waitForExistence(timeout: 30), "choose button before tapping")
            choose.tap()
            let bar = app.otherElements["review.undo.bar"]
            XCTAssertTrue(bar.waitForExistence(timeout: 20), "undo bar after the choice")
            XCTAssertTrue(app.staticTexts["Variante B gewählt: Wetterdienst A"].firstMatch.waitForExistence(timeout: 10), "choice text")
            XCTAssertTrue(app.buttons["Rückgängig"].exists, "undo button")
            Thread.sleep(forTimeInterval: 2)
            shot("4-nach-wahl-text-\(look)")
            app.terminate()

            // 5. Same with a picture variant.
            if dark {
                app = launch("task:Karte Wahl Bild")
                let pictureChoose = app.buttons["Wählen: Variante B, Radarkarte"]
                XCTAssertTrue(pictureChoose.waitForExistence(timeout: 30))
                pictureChoose.tap()
                XCTAssertTrue(app.otherElements["review.undo.bar"].waitForExistence(timeout: 20))
                Thread.sleep(forTimeInterval: 3)
                shot("5-nach-wahl-bild-\(look)")
                app.terminate()
            }
        }
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(out)/\(prefix)-\(name).png"))
    }
}
