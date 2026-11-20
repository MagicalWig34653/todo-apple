import XCTest

/// Local helper, not part of the regular suite (card 8CECAD24, phase 2): the real app against a scratch backend with the account
/// of `LiveEtappe2Tests.testLiveSeedCalendarTourAccount`. Needs `TODO_UITEST_SERVER`, `TODO_UITEST_TOKEN`, `TODO_TOUR_OUT`. iPad only
/// (drag and drop in the week grid). One real drag, a quit, a fresh start that must show the same plan; the server is checked afterwards
/// by the caller (`GET /v1/planning/schedule`).
final class CalendarLiveTour: XCTestCase {
    func testDragPersistsAfterFreshStart() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"], let out = env["TODO_TOUR_OUT"] else { throw XCTSkip("tour variables not set") }
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        continueAfterFailure = false

        func launch() -> XCUIApplication {
            let app = XCUIApplication()
            app.launchEnvironment["TODO_DEBUG_SERVER"] = server
            app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
            app.launchEnvironment["TODO_DEBUG_SELECT"] = "calendar"
            app.launchArguments += ["-appearance.colorScheme", "light", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
            app.launch()
            return app
        }
        func block(_ app: XCUIApplication, _ title: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        }

        // Absorb the first-request 401 after an install.
        let warm = launch(); Thread.sleep(forTimeInterval: 8); warm.terminate()

        let app = launch()
        let b = block(app, "Termin B")
        XCTAssertTrue(b.waitForExistence(timeout: 30), "seeded block in the grid")
        Thread.sleep(forTimeInterval: 2)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/live-vorher.png"))
        let before = b.frame.minY
        let from = b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        from.press(forDuration: 0.5, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 156)), withVelocity: .slow, thenHoldForDuration: 1.0)
        Thread.sleep(forTimeInterval: 4)
        let moved = block(app, "Termin B")
        XCTAssertTrue(moved.waitForExistence(timeout: 10))
        let after = moved.frame.minY
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/live-nachher.png"))
        let notice = app.descendants(matching: .any)["calendar.notice"]
        XCTAssertFalse(notice.exists, "hint: \(notice.label)")
        XCTAssertGreaterThan(after, before + 100, "the block moved down (frame \(b.frame) -> \(moved.frame))")
        app.terminate()

        // Fresh start: the plan comes from the server, the block stays where it was dropped.
        let again = launch()
        let b2 = block(again, "Termin B")
        XCTAssertTrue(b2.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(b2.frame.minY, after, accuracy: 3, "persisted on the server")
        try? again.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/live-neustart.png"))
        again.terminate()
    }
}
