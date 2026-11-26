import XCTest

/// Card B6D004D4: rejecting the second confirmation in "Für dich" keeps every card where it was and the outcome line in view
/// (it used to jump to the top, above the visible part). Real app against a real backend with at least three pending
/// confirmation requests of the signed-in account (`LiveWelle3Tests.testSeedConfirmationRequests`). Rejects one request per
/// run, which other tests still need: runs only with `TODO_UITEST_DECIDE=1`. Env: `TODO_UITEST_SERVER`, `TODO_UITEST_TOKEN`;
/// optional `TODO_TOUR_LOOK` (`dunkel` = dark) and `TODO_TOUR_OUT` (directory for the before/after PNGs).
final class ConfirmationOrderUITests: XCTestCase {
    private var server = "", token = "", out: String?, dark = false
    private var summaries: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["TODO_UITEST_DECIDE"] == "1", "consumes a request: TODO_UITEST_DECIDE=1")
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"] else {
            throw XCTSkip("TODO_UITEST_SERVER / TODO_UITEST_TOKEN not set")
        }
        self.server = server; self.token = token; out = env["TODO_TOUR_OUT"]; dark = env["TODO_TOUR_LOOK"] == "dunkel"
        summaries = try pendingSummaries()
        try XCTSkipIf(summaries.count < 3, "needs three pending confirmation requests")
    }

    /// Summaries of the pending confirmations (`GET /v1/feed`), fetched from the test process with the session token.
    private func pendingSummaries() throws -> [String] {
        var request = URLRequest(url: URL(string: server + "/v1/feed")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var result: Data?
        let done = expectation(description: "feed")
        URLSession.shared.dataTask(with: request) { data, _, _ in result = data; done.fulfill() }.resume()
        wait(for: [done], timeout: 15)
        let feed = try XCTUnwrap(result.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }, "GET /v1/feed")
        return ((feed["confirmations"] as? [[String: Any]]) ?? []).compactMap { $0["summary"] as? String }
    }

    private func shot(_ name: String) {
        guard let out else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "\(out)/\(device)-\(dark ? "dunkel" : "hell")-\(name).png"))
    }

    /// The element showing a summary (the card's combined header).
    private func header(_ app: XCUIApplication, _ summary: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", summary)).firstMatch
    }

    /// Summaries in the order the cards stand on screen, top to bottom.
    private func shownOrder(_ app: XCUIApplication) -> [String] {
        summaries.sorted { header(app, $0).frame.minY < header(app, $1).frame.minY }
    }

    func testRejectingTheSecondCardKeepsItInPlace() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_SERVER"] = server
        app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        app.launchEnvironment["TODO_DEBUG_SELECT"] = "feed"
        app.launchArguments += ["-push.primerDismissed", "YES", "-appearance.colorScheme", dark ? "dark" : "light"]
        app.launch()

        let cards = app.otherElements.matching(identifier: "confirm.card")
        let all = NSPredicate(format: "count >= %d", summaries.count)
        expectation(for: all, evaluatedWith: cards)
        waitForExpectations(timeout: 60)
        for s in summaries { XCTAssertTrue(header(app, s).waitForExistence(timeout: 10), "card shown: \(s)") }
        Thread.sleep(forTimeInterval: 2)
        let before = shownOrder(app)
        shot("1-vorher")

        let second = before[1]
        let card = cards.allElementsBoundByIndex.first { $0.frame.contains(header(app, second).frame) }
        try XCTUnwrap(card, "card of \(second)").buttons["confirm.reject"].tap()

        let outcome = app.descendants(matching: .any)["confirm.outcome"].firstMatch
        XCTAssertTrue(outcome.waitForExistence(timeout: 20), "rejected outcome")
        Thread.sleep(forTimeInterval: 2)
        shot("2-nachher")

        XCTAssertEqual(shownOrder(app), before, "the decided card stays in its place")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(outcome.frame), "the outcome line is in view: \(outcome.frame) in \(window)")
        XCTAssertGreaterThan(outcome.frame.minY, header(app, before[1]).frame.minY, "outcome below the second card's header")
        XCTAssertLessThan(outcome.frame.maxY, header(app, before[2]).frame.minY, "outcome above the third card")
    }
}
