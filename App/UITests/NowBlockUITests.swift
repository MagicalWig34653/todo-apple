import XCTest

/// Block "Jetzt" (card 9F41292D, contract session-status 1.4.0): the screen opens from the tab bar (iPhone) or the sidebar (iPad),
/// shows the empty state and the groups Läuft gerade / Wartet auf dich / Zuletzt fertig / Ohne Lebenszeichen (n, collapsed).
/// Needs `TODO_UITEST_SERVER` / `TODO_UITEST_TOKEN` like `TodoUITests` (skipped without).
/// - `testFilledGroupsFromRealBackend`: the test reports a session and finishes a card over REST; the app must show both.
/// - `testEmptyAndFullStub`: fixed sample data inside the real app shell (`TODO_DEBUG_NOW_STUB=empty|full`), because "silent"
///   (no sign of life for 30 minutes) and an empty backend cannot be produced live.
/// With `TODO_TOUR_OUT=<dir>` it writes PNGs; `TODO_TOUR_LOOK=light|dark` only names them (the appearance is set on the simulator
/// with `simctl ui <udid> appearance dark`, run with `TODO_UITEST_DEVICE`).
@MainActor
final class NowBlockUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server = ""
    private var token = ""
    private let stamp = Int(Date().timeIntervalSince1970) % 100000

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"] else {
            throw XCTSkip("TODO_UITEST_SERVER / TODO_UITEST_TOKEN not set")
        }
        self.server = server; self.token = token
    }

    private var look: String { ProcessInfo.processInfo.environment["TODO_TOUR_LOOK"] ?? "light" }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    // MARK: Server helpers

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        var r = URLRequest(url: URL(string: server + path)!)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertTrue((200..<300).contains(code), "\(method) \(path) -> \(code): \(String(data: data, encoding: .utf8) ?? "")")
        return data
    }

    private func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    // MARK: App helpers

    private func launch(stub: String? = nil) {
        app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_SERVER"] = server
        app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        app.launchEnvironment["TODO_DEBUG_SELECT"] = "today"
        app.launchEnvironment["TODO_DEBUG_NOW"] = "12:00"
        if let stub { app.launchEnvironment["TODO_DEBUG_NOW_STUB"] = stub }
        app.launch()
    }

    /// iPhone: the "Jetzt" tab; iPad and Mac: the sidebar row. Never the debug shortcut: the entry itself is under test.
    private func openNow() {
        if isPad {
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Jetzt")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 30), "sidebar row Jetzt")
            row.tap()
        } else {
            let tab = app.tabBars.buttons["Jetzt"]
            XCTAssertTrue(tab.waitForExistence(timeout: 30), "tab Jetzt")
            tab.tap()
        }
        XCTAssertTrue(element("now.screen").waitForExistence(timeout: 20), "Jetzt screen appears")
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ name: String) {
        guard let out = ProcessInfo.processInfo.environment["TODO_TOUR_OUT"] else { return }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        Thread.sleep(forTimeInterval: 1)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }

    // MARK: Tests

    func testEmptyAndFullStub() {
        // Empty: no running card, nothing waiting, nothing done, nothing silent.
        launch(stub: "empty")
        openNow()
        XCTAssertTrue(element("now.empty").waitForExistence(timeout: 10), "empty state")
        XCTAssertFalse(element("now.block.running.item").exists)
        shot("jetzt-\(look)-1-leer")
        app.terminate()

        // Full: all four groups; the silent group is collapsed until opened.
        launch(stub: "full")
        openNow()
        XCTAssertTrue(element("now.block.running").waitForExistence(timeout: 10), "block")
        shot("jetzt-\(look)-2-gefuellt")
        XCTAssertTrue(heading("Läuft gerade").exists, "Läuft gerade")
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(identifier: "now.block.running.item").count, 2)
        XCTAssertTrue(heading("Wartet auf dich").exists, "Wartet auf dich")
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(identifier: "now.block.waiting.item").count, 1)
        app.terminate()

        // Tail: nothing running or waiting; done and silent on one screen. The silent group starts collapsed and opens on tap.
        launch(stub: "tail")
        openNow()
        XCTAssertTrue(element("now.block.running.empty").waitForExistence(timeout: 10), "Läuft gerade says nothing runs")
        XCTAssertTrue(heading("Zuletzt fertig").waitForExistence(timeout: 5), "Zuletzt fertig")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "now.block.done.item").count, 2)
        XCTAssertFalse(heading("Wartet auf dich").exists, "no waiting group without entries")
        let silent = element("now.block.silent")
        XCTAssertTrue(silent.waitForExistence(timeout: 5), "Ohne Lebenszeichen")
        XCTAssertTrue(silent.label.contains("Ohne Lebenszeichen (3)"), "count in the heading: \(silent.label)")
        XCTAssertFalse(element("now.block.silent.item").exists, "silent group starts collapsed")
        shot("jetzt-\(look)-3-ohne-lebenszeichen-zu")
        silent.tap()
        XCTAssertTrue(element("now.block.silent.item").waitForExistence(timeout: 5), "silent group opens")
        shot("jetzt-\(look)-4-ohne-lebenszeichen-offen")
    }

    private func heading(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    func testFilledGroupsFromRealBackend() async throws {
        // A running session (running = sign of life within 30 minutes) and a card finished just now (recentlyDone = last 6 hours).
        let list = json(try await request("GET", "/v1/projects"))
        let projects = (list as? [String: Any])?["items"] as? [[String: Any]] ?? list as? [[String: Any]] ?? []
        let projectID = try XCTUnwrap(projects.first?["id"] as? String, "seeded project")
        let session = "jetzt-ui-\(stamp)"
        _ = try await request("PUT", "/v1/projects/\(projectID)/session-status", body: ["sessionName": session, "activity": "Prüft den Block Jetzt in der App"])
        let title = "Jetzt erledigt \(stamp)"
        let created = json(try await request("POST", "/v1/tasks", body: ["projectID": projectID, "title": title])) as? [String: Any]
        let taskID = try XCTUnwrap(created?["id"] as? String, "created task")
        _ = try await request("PATCH", "/v1/tasks/\(taskID)", body: ["status": "done", "version": created?["version"] ?? 1])

        launch()
        openNow()
        let running = element("now.block.running.item")
        XCTAssertTrue(running.waitForExistence(timeout: 20), "the reported session shows under Läuft gerade")
        XCTAssertTrue(app.staticTexts[session].exists, "session name visible")
        let done = element("now.block.done.item")
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the finished card shows under Zuletzt fertig")
        XCTAssertTrue(app.staticTexts[title].exists, "card title visible")
        shot("jetzt-\(look)-5-echtes-backend")

        // Ending the session removes it again (contract 1.4.0: ended true deletes the row).
        _ = try await request("PUT", "/v1/projects/\(projectID)/session-status", body: ["sessionName": session, "ended": true])
        app.swipeDown()
        XCTAssertTrue(app.staticTexts[session].waitForNonExistence(timeout: 15), "ended session disappears after a refresh")
    }
}
