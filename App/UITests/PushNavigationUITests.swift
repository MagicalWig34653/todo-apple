import XCTest

/// Tap on a confirmation push (`kind` action_request, card 9B691C3A): "Für dich" opens and the card of the request named by
/// `subjectID` is outlined. No real push is sent: the debug build calls the real `NotificationDelegate` with a response built
/// from the backend's payload format (`TODO_DEBUG_DELIVER_RESPONSE`, see `PushResponseUITests`). Needs a backend with at least
/// two pending confirmation requests of the signed-in account (`LiveWelle3Tests.testSeedConfirmationRequests`) and
/// `TODO_UITEST_SERVER`, `TODO_UITEST_TOKEN`; optional `TODO_TOUR_OUT` (directory) writes PNGs named by what they show.
final class PushNavigationUITests: XCTestCase {
    private struct Confirmation { let id: String; let summary: String }
    private var server = "", token = "", out: String?
    private var confirmations: [Confirmation] = []
    nonisolated(unsafe) private static var warmedUp = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"] else {
            throw XCTSkip("TODO_UITEST_SERVER / TODO_UITEST_TOKEN not set")
        }
        self.server = server; self.token = token; out = env["TODO_TOUR_OUT"]
        confirmations = try fetchConfirmations()
        if !Self.warmedUp {
            // The first launch after an install may answer 401 to its first requests; a throw-away launch absorbs that.
            Self.warmedUp = true
            let warm = XCUIApplication()
            warm.launchEnvironment["TODO_DEBUG_SERVER"] = server
            warm.launchEnvironment["TODO_DEBUG_TOKEN"] = token
            warm.launch()
            Thread.sleep(forTimeInterval: 8)
            warm.terminate()
        }
        try XCTSkipIf(confirmations.count < 2, "needs two pending confirmation requests")
    }

    /// Pending confirmations of the account (`GET /v1/feed`), fetched from the test process with the session token.
    private func fetchConfirmations() throws -> [Confirmation] {
        var request = URLRequest(url: URL(string: server + "/v1/feed")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var result: Data?
        let done = expectation(description: "feed")
        URLSession.shared.dataTask(with: request) { data, _, _ in result = data; done.fulfill() }.resume()
        wait(for: [done], timeout: 15)
        let feed = try XCTUnwrap(result.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }, "GET /v1/feed")
        let list = (feed["confirmations"] as? [[String: Any]]) ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? String, let summary = item["summary"] as? String else { return nil }
            return Confirmation(id: id, summary: summary)
        }
    }

    /// Same shape and key order as `deliverConfirmation` / `PushMessage.payload()` in the backend (sorted keys, uppercase UUID).
    private func payload(subject: String?) -> String {
        let subjectPart = subject.map { ",\"subjectID\":\"\($0.uppercased())\"" } ?? ""
        return """
        {"aps":{"alert":{"body":"Ein Agent wartet auf deine Bestätigung.","title":"Bestätigung nötig"},"badge":1,\
        "category":"TODO_CONFIRMATION","mutable-content":1,"sound":"default"},"kind":"action_request"\(subjectPart)}
        """
    }

    private func launch(subject: String?, select: String?, delay: Int, dark: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_SERVER"] = server
        app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        if let select { app.launchEnvironment["TODO_DEBUG_SELECT"] = select }
        app.launchEnvironment["TODO_DEBUG_DELIVER_RESPONSE"] = payload(subject: subject)
        app.launchEnvironment["TODO_DEBUG_DELIVER_DELAY"] = "\(delay)"
        app.launchEnvironment["TODO_DEBUG_DELIVER_ONLY"] = "didReceive"
        app.launchArguments += ["-push.primerDismissed", "YES", "-appearance.colorScheme", dark ? "dark" : "light"]
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        guard let out else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }

    private func assertOnlyTargetHighlighted(_ app: XCUIApplication, target: Confirmation, file: StaticString = #filePath, line: UInt = #line) {
        let card = app.otherElements["confirm.card.highlighted"]
        XCTAssertTrue(card.waitForExistence(timeout: 40), "the target card is outlined", file: file, line: line)
        XCTAssertEqual(app.otherElements.matching(identifier: "confirm.card.highlighted").count, 1, "exactly one card", file: file, line: line)
        XCTAssertTrue(card.staticTexts[target.summary].exists || card.staticTexts.matching(NSPredicate(format: "label == %@", target.summary)).count > 0,
                      "the outlined card shows the summary of the request in the payload: \(target.summary)", file: file, line: line)
        XCTAssertTrue(card.isHittable, "the card is scrolled into view", file: file, line: line)
    }

    /// Cold start: the response arrives while the app is still signing in; the link is kept and opened afterwards.
    func testColdStartOpensForYouWithTheRequestCard() throws {
        let target = try XCTUnwrap(confirmations.last)
        let app = launch(subject: target.id, select: nil, delay: 0, dark: false)
        assertOnlyTargetHighlighted(app, target: target)
        XCTAssertEqual(app.alerts.count, 0)
        Thread.sleep(forTimeInterval: 2)
        shot("tap-bestaetigung-kaltstart-hell")
    }

    /// Foreground tap while another screen ("Heute") is open: it switches to "Für dich" and outlines the card.
    func testForegroundTapSwitchesFromTodayToTheRequestCard() throws {
        let target = try XCTUnwrap(confirmations.last)
        let app = launch(subject: target.id, select: "today", delay: 12, dark: true)
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(app.otherElements["confirm.card.highlighted"].exists, "nothing outlined before the tap")
        assertOnlyTargetHighlighted(app, target: target)
        Thread.sleep(forTimeInterval: 2)
        shot("tap-bestaetigung-vordergrund-dunkel")
    }

    /// Unknown request id: "Für dich" opens, no card is outlined, no error alert; the real cards stay as they are.
    func testUnknownRequestIDShowsForYouWithoutError() throws {
        for dark in [false, true] {
            let app = launch(subject: UUID().uuidString, select: "today", delay: 12, dark: dark)
            XCTAssertTrue(app.otherElements["confirm.card"].firstMatch.waitForExistence(timeout: 60), "Für dich with the pending cards")
            Thread.sleep(forTimeInterval: 4)
            XCTAssertFalse(app.otherElements["confirm.card.highlighted"].exists, "no card outlined")
            XCTAssertEqual(app.alerts.count, 0, "no error")
            shot("tap-unbekannte-anfrage-\(dark ? "dunkel" : "hell")")
            app.terminate()
        }
    }

    /// No `subjectID` at all (older data): the same, "Für dich" only.
    func testMissingRequestIDShowsForYouOnly() throws {
        let app = launch(subject: nil, select: "today", delay: 12, dark: false)
        XCTAssertTrue(app.otherElements["confirm.card"].firstMatch.waitForExistence(timeout: 60))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(app.otherElements["confirm.card.highlighted"].exists)
        XCTAssertEqual(app.alerts.count, 0)
    }
}
