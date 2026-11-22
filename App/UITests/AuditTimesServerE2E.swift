import XCTest

/// Local helper, not part of the regular suite (card 330C57F8, Apple parity): the real app against a native backend shows the
/// creation/audit times of a card with the exact Berlin moment of the server's instant. Seed: `LiveReviewVariantsTests.testSeedVariantReviews`
/// (task "Wetterdaten-Anbieter" with a pending review). Needs `TODO_UITEST_SERVER`, `TODO_UITEST_TOKEN`, optional `TODO_TOUR_OUT`.
final class AuditTimesServerE2E: XCTestCase {
    private let title = "Wetterdaten-Anbieter"

    func testTaskCardShowsServerTimesInBerlinTime() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"] else { throw XCTSkip("server variables not set") }
        continueAfterFailure = false

        // What the server says about the card (real HTTP, account token).
        let (createdAt, updatedAt) = try serverTimes(server: server, token: token)
        XCTAssertLessThanOrEqual(createdAt, updatedAt)

        // The first launch after an install answers 401 to its first requests; absorb it.
        let warm = launch(server, token, "feed"); Thread.sleep(forTimeInterval: 8); warm.terminate()

        let app = launch(server, token, "task:\(title)")
        let created = element(app, "audit.created")
        XCTAssertTrue(created.waitForExistence(timeout: 30), "'erstellt' line in the card header")
        XCTAssertTrue(created.label.hasPrefix("erstellt"), "label says 'erstellt': \(created.label)")
        XCTAssertEqual(created.value as? String, berlin(createdAt), "exact Berlin moment of createdAt")
        let updated = element(app, "audit.updated")
        XCTAssertTrue(updated.exists, "'zuletzt geändert' line")
        XCTAssertTrue(updated.label.hasPrefix("zuletzt geändert"), "label: \(updated.label)")
        XCTAssertEqual(updated.value as? String, berlin(updatedAt), "exact Berlin moment of updatedAt")
        XCTAssertTrue(created.isHittable, "line is visible, not clipped")
        if let out = env["TODO_TOUR_OUT"] { try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/audit-task-card.png")) }

        // The pending review of this card shows when it was requested (card header of the agent section).
        let requested = element(app, "audit.requested")
        XCTAssertTrue(requested.waitForExistence(timeout: 20), "'angefragt' line of the review")
        XCTAssertTrue(requested.label.hasPrefix("angefragt"), "label: \(requested.label)")
        XCTAssertEqual((requested.value as? String)?.range(of: #"^\d{2}\.\d{2}\.\d{4}, \d{2}:\d{2}:\d{2} GMT\+[12]$"#, options: .regularExpression) != nil, true, "exact moment shape: \(String(describing: requested.value))")
        app.terminate()
    }

    // MARK: helpers

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func berlin(_ date: Date) -> String {
        let zone = TimeZone(identifier: "Europe/Berlin")!
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.dateFormat = "dd.MM.yyyy, HH:mm:ss"
        let hours = zone.secondsFromGMT(for: date) / 3600
        return "\(f.string(from: date)) GMT\(hours >= 0 ? "+" : "-")\(abs(hours))"
    }

    private func serverTimes(server: String, token: String) throws -> (Date, Date) {
        func get(_ path: String) throws -> Any {
            var req = URLRequest(url: URL(string: "\(server)\(path)")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            var data: Data?; var status = 0
            let done = expectation(description: path)
            URLSession.shared.dataTask(with: req) { d, r, _ in data = d; status = (r as? HTTPURLResponse)?.statusCode ?? 0; done.fulfill() }.resume()
            wait(for: [done], timeout: 20)
            XCTAssertEqual(status, 200, path)
            return try JSONSerialization.jsonObject(with: data ?? Data())
        }
        let list = try XCTUnwrap(try get("/v1/tasks") as? [[String: Any]])
        let id = try XCTUnwrap(list.first { $0["title"] as? String == title }?["id"] as? String, "seeded task")
        let ctx = try XCTUnwrap(try get("/v1/tasks/\(id)/context") as? [String: Any])
        let task = try XCTUnwrap(ctx["task"] as? [String: Any])
        let f = ISO8601DateFormatter()
        func date(_ key: String) throws -> Date { try XCTUnwrap(f.date(from: try XCTUnwrap(task[key] as? String, "server task has \(key)"))) }
        return (try date("createdAt"), try date("updatedAt"))
    }

    private func launch(_ server: String, _ token: String, _ select: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_SERVER"] = server
        app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        app.launchEnvironment["TODO_DEBUG_SELECT"] = select
        app.launchArguments += ["-push.primerDismissed", "YES", "-appearance.colorScheme", "light", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()
        return app
    }
}
