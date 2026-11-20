import XCTest

/// Local helper, not part of the regular suite (card 1D9C8B0C, review with variants): the smallest real end-to-end proof that the
/// app's choose and undo taps change the SERVER (native backend with its database, no mocks) and that the result survives a fresh
/// app start. The test itself asks the backend (`GET /v1/reviews`) with the account token between the taps; the Core tests only prove
/// the client against the backend, the tour only looks at the UI. Seed: `LiveReviewVariantsTests.testSeedVariantReviews` (task
/// "Wetterdaten-Anbieter", variants a "Open-Meteo" and b "Wetterdienst A"). Needs `TODO_UITEST_SERVER`, `TODO_UITEST_TOKEN`,
/// optional `TODO_TOUR_OUT` (directory for PNGs).
final class ReviewVariantsServerE2E: XCTestCase {
    private var server = "", token = "", out: String?
    private let title = "Wetterdaten-Anbieter"
    private let choose = "Wählen: Variante B, Wetterdienst A"

    func testChooseUndoPersistOnServer() throws {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["TODO_UITEST_SERVER"], let t = env["TODO_UITEST_TOKEN"] else { throw XCTSkip("server variables not set") }
        server = s; token = t; out = env["TODO_TOUR_OUT"]
        continueAfterFailure = false

        // The first launch after an install answers 401 to its first requests; absorb it.
        let warm = launch("feed"); Thread.sleep(forTimeInterval: 8); warm.terminate()

        // Start: the review waits for a choice, nothing chosen on the server.
        var before = try serverReview()
        XCTAssertEqual(before?.state, "pending", "seeded review is pending"); XCTAssertNil(before?.chosen)

        // Feed ("Für dich"): a review with variants offers "Variante wählen", not "Annehmen".
        var app = launch("feed")
        XCTAssertTrue(app.buttons["Variante wählen"].firstMatch.waitForExistence(timeout: 30), "feed offers 'Variante wählen'")
        shot("feed-variante-waehlen")
        app.terminate()

        // Real tap on "Wählen": accepted with exactly that variant on the server, undo window open.
        app = launch("task:\(title)")
        let button = reveal(app, choose)
        XCTAssertTrue(button.isHittable, "choose button")
        button.tap()
        XCTAssertTrue(app.otherElements["review.undo.bar"].waitForExistence(timeout: 20), "undo bar after the choice")
        before = try waitForServer { $0?.state == "accepted" }
        XCTAssertEqual(before?.chosen, "b", "server stores the chosen variant")
        let until = try XCTUnwrap(before?.undoUntil, "server opens the undo window")
        XCTAssertEqual(until.timeIntervalSinceNow, 300, accuracy: 30, "undo window about 5 minutes")
        shot("nach-wahl-server-angenommen")

        // Real tap on "Rückgängig" (same session: the app offers the undo only for a decision made in this session): the server
        // is back to pending without a choice, the bar is gone, the choice is possible again.
        let undo = app.buttons["Rückgängig"]
        XCTAssertTrue(undo.waitForExistence(timeout: 20), "undo button")
        undo.tap()
        XCTAssertTrue(waitForGone(app.otherElements["review.undo.bar"]), "undo bar disappears")
        before = try waitForServer { $0?.state == "pending" }
        XCTAssertNil(before?.chosen, "server forgot the choice")
        XCTAssertNil(before?.undoUntil, "no undo window on a pending review")
        let again = reveal(app, choose)
        XCTAssertTrue(again.isHittable, "choose button is back after the undo")
        shot("nach-rueckgaengig")

        // Fresh start after the undo: still undecided (persisted); a second choice works as follow-up action.
        app.terminate()
        app = launch("task:\(title)")
        let second = reveal(app, "Wählen: Variante A, Open-Meteo")
        XCTAssertTrue(second.isHittable, "choose A after a fresh start")
        second.tap()
        XCTAssertTrue(app.otherElements["review.undo.bar"].waitForExistence(timeout: 20))
        before = try waitForServer { $0?.state == "accepted" }
        XCTAssertEqual(before?.chosen, "a", "second choice stored")
        app.terminate()

        // Fresh start after the choice: the result comes from the server, the choose buttons are gone. The undo offer is
        // session-only (AppModel.offerReviewUndo), so there is no undo bar after a restart even though the server window is open.
        app = launch("task:\(title)")
        XCTAssertTrue(app.staticTexts["Variante A gewählt: Open-Meteo"].firstMatch.waitForExistence(timeout: 30), "chosen text after a fresh start")
        XCTAssertFalse(app.buttons[choose].exists, "no choose button after the choice")
        XCTAssertFalse(app.otherElements["review.undo.bar"].exists, "undo offer does not survive a restart (known, session-only)")
        shot("neustart-nach-wahl")
        app.terminate()
    }

    // MARK: server (real HTTP, bearer token of the app's account)

    private struct Row: Decodable { let taskTitle: String?; let state: String; let chosenVariantID: String?; let undoUntil: Date? }
    private struct Seen { let state: String; let chosen: String?; let undoUntil: Date? }

    private func serverReview() throws -> Seen? {
        for state in ["pending", "accepted"] {
            var comps = URLComponents(string: "\(server)/v1/reviews")!
            comps.queryItems = [.init(name: "state", value: state), .init(name: "includeSubprojects", value: "true"), .init(name: "limit", value: "100")]
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            var data: Data?; var status = 0
            let done = expectation(description: "GET /v1/reviews")
            URLSession.shared.dataTask(with: req) { d, r, _ in data = d; status = (r as? HTTPURLResponse)?.statusCode ?? 0; done.fulfill() }.resume()
            wait(for: [done], timeout: 20)
            XCTAssertEqual(status, 200, "GET /v1/reviews?state=\(state)")
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .custom { d in
                let s = try d.singleValueContainer().decode(String.self)
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let v = f.date(from: s) { return v }
                f.formatOptions = [.withInternetDateTime]
                return f.date(from: s) ?? Date.distantPast
            }
            let rows = try dec.decode([Row].self, from: data ?? Data())
            if let r = rows.first(where: { $0.taskTitle == title }) { return Seen(state: r.state, chosen: r.chosenVariantID, undoUntil: r.undoUntil) }
        }
        return nil
    }

    private func waitForServer(_ ok: (Seen?) -> Bool) throws -> Seen? {
        var last: Seen?
        for _ in 0..<20 { last = try serverReview(); if ok(last) { return last }; Thread.sleep(forTimeInterval: 1) }
        return last
    }

    // MARK: app

    private func launch(_ select: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_SERVER"] = server
        app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        app.launchEnvironment["TODO_DEBUG_SELECT"] = select
        app.launchArguments += ["-push.primerDismissed", "YES", "-appearance.colorScheme", "light", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()
        return app
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func reveal(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let button = app.buttons[label]
        guard button.waitForExistence(timeout: 30) else { return button }
        var swipes = 0
        while !button.isHittable && swipes < 60 {
            let from = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let to = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            from.press(forDuration: 0.05, thenDragTo: to)
            swipes += 1
        }
        return button
    }

    private func shot(_ name: String) {
        guard let out else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/e2e-\(name).png"))
    }
}
