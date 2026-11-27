import XCTest

/// The daily brief time survives an app start (card 9B691C3A): the test process stores hour and switch through the REST API
/// (as another client would), the app is launched fresh and settings > notifications must show the same local time again,
/// with the switch on. Needs `TODO_UITEST_SERVER`, `TODO_UITEST_TOKEN` of an account on a server from contract push.yaml 1.1.0;
/// optional `TODO_TOUR_OUT` (directory) writes `tagesbericht-gespeichert-<hell|dunkel>.png`.
final class PushBriefPersistenceUITests: XCTestCase {
    private var server = "", token = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"] else {
            throw XCTSkip("TODO_UITEST_SERVER / TODO_UITEST_TOKEN not set")
        }
        self.server = server; self.token = token
    }

    /// `POST /v1/me/push-prefs` with the given JSON body (partial update), returns the parsed answer.
    @discardableResult
    private func storePrefs(_ body: [String: Any]) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: server + "/v1/me/push-prefs")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var result: Data?
        let done = expectation(description: "prefs")
        URLSession.shared.dataTask(with: request) { data, _, _ in result = data; done.fulfill() }.resume()
        wait(for: [done], timeout: 15)
        return try XCTUnwrap(result.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }, "push-prefs answer")
    }

    /// The same text the app shows for a UTC hour: today's offset of this time zone, short time style.
    private func localText(utcHour: Int) -> String {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = utc.date(bySettingHour: utcHour, minute: 0, second: 0, of: Date())!
        return instant.formatted(date: .omitted, time: .shortened)
    }

    func testStoredHourIsShownAgainAfterAFreshStart() throws {
        let env = ProcessInfo.processInfo.environment
        let utcHour = 17
        let answer = try storePrefs(["categories": ["daily_brief": true], "dailyBriefHour": utcHour])
        XCTAssertEqual(answer["dailyBriefHour"] as? Int, utcHour, "server stored the UTC hour")
        defer { _ = try? storePrefs(["categories": ["daily_brief": false], "dailyBriefHour": 8]) }

        // The first launch after an install is not reliable with the debug session; a throw-away launch absorbs that.
        let warm = XCUIApplication()
        warm.launchEnvironment["TODO_DEBUG_SERVER"] = server
        warm.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        warm.launch()
        Thread.sleep(forTimeInterval: 8)
        warm.terminate()

        for dark in [false, true] {
            let app = XCUIApplication()
            app.launchEnvironment["TODO_DEBUG_SERVER"] = server
            app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
            app.launchEnvironment["TODO_DEBUG_SELECT"] = "account"
            app.launchArguments += ["-appearance.colorScheme", dark ? "dark" : "light"]
            app.launch()

            let brief = app.switches["push.cat.dailyBrief"]
            XCTAssertTrue(brief.waitForExistence(timeout: 30) || scroll(app, until: brief), "daily brief switch")
            // Bring the switch into the upper part so the picker row below it is on screen too.
            let height = app.windows.firstMatch.frame.height
            for _ in 0..<20 where brief.frame.maxY > height * 0.45 {
                let window = app.windows.firstMatch
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                    .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
            }
            XCTAssertEqual(brief.value as? String, "1", "switch is on after a fresh start")
            let time = app.descendants(matching: .any)["push.dailyBrief.time"]
            XCTAssertTrue(time.waitForExistence(timeout: 15), "time picker")
            let expected = localText(utcHour: utcHour)
            // The picker shows its current choice as value or label text, depending on the OS version.
            let shown = [time.value as? String, time.label].compactMap { $0 } + time.staticTexts.allElementsBoundByIndex.map(\.label)
            XCTAssertTrue(shown.contains { $0.contains(expected) }, "picker shows \(expected) (saw \(shown))")
            if let out = env["TODO_TOUR_OUT"] {
                try? XCUIScreen.main.screenshot().pngRepresentation
                    .write(to: URL(fileURLWithPath: "\(out)/tagesbericht-gespeichert-\(dark ? "dunkel" : "hell").png"))
            }
            app.terminate()
        }
    }

    private func scroll(_ app: XCUIApplication, until element: XCUIElement) -> Bool {
        for _ in 0..<25 where !element.exists {
            let from = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            from.press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        return element.exists
    }
}
