import XCTest

/// Local helper, not part of the regular suite (card 8CECAD24, phase 2, app evidence): the real app on the iPad simulator against a
/// scratch backend (account of `LiveEtappe2Tests.testLiveSeedCalendarTourAccount`), a second client (plain HTTP from the test) and the
/// server checked with `GET /v1/planning/schedule`. Needs `TODO_UITEST_SERVER`, `TODO_UITEST_TOKEN`, `TODO_TOUR_OUT`; the offline
/// scenarios also need the watcher script of the caller, which answers `cmd-pause` / `cmd-resume` files in `TODO_TOUR_OUT`
/// (stops and restarts the backend on the same database; the simulator cannot do that itself).
final class CalendarScenarioTour: XCTestCase {
    private var server = "", token = "", out = ""
    private let iso = ISO8601DateFormatter()

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["TODO_UITEST_SERVER"], let t = env["TODO_UITEST_TOKEN"], let o = env["TODO_TOUR_OUT"] else { throw XCTSkip("tour variables not set") }
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        server = s; token = t; out = o
        continueAfterFailure = false
    }

    // MARK: A) Real 409 in the app

    /// The app shows "Termin B" (live refresh off, so it really is stale), a second client moves the same card, the drop in the app
    /// carries the old version: 409 `version_conflict`, hint, the block jumps to the server's state, the server is unchanged by the
    /// app. A second drag with the current version then succeeds and the hint is gone.
    func testStaleDropGetsVersionConflictThenSucceeds() throws {
        try arrange(movingCardAt: 12)
        let app = launch(liveOff: true)
        let b = block(app, "Termin B"), a = block(app, "Termin A")
        XCTAssertTrue(b.waitForExistence(timeout: 30), "seeded block in the grid")
        Thread.sleep(forTimeInterval: 2)
        let hour = (b.frame.minY - a.frame.minY) / 2  // points per hour (A 10:00, B 12:00)
        shot(app, "kalender-409-1-vorher")
        let start = try entry("Termin B")
        XCTAssertEqual(start.plannedAt, at(12))

        // Second client: same card, 16:00, valid version.
        let theirs = try patch(start.id, version: start.version, plannedAt: at(16))
        XCTAssertEqual(theirs.status, 200, "second client write: \(theirs.body)")
        let theirsEntry = try entry("Termin B")
        XCTAssertEqual(theirsEntry.version, start.version + 1)
        XCTAssertFalse(noticeElement(app).exists)
        XCTAssertEqual(b.frame.minY, a.frame.minY + 2 * hour, accuracy: 4, "the app still shows the old plan (stale)")

        // Drop in the app: 12:00 -> about 14:00 with the old version.
        drag(b, by: 2 * hour)
        let notice = noticeElement(app)
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "version conflict hint")
        XCTAssertTrue(noticeText(app).contains("inzwischen geändert"), "hint text: \(noticeText(app))")
        Thread.sleep(forTimeInterval: 3)  // rollback and reload
        let jumped = block(app, "Termin B")
        XCTAssertTrue(jumped.waitForExistence(timeout: 10))
        XCTAssertEqual(jumped.frame.minY, block(app, "Termin A").frame.minY + 6 * hour, accuracy: 4, "block is at the server's state (16:00)")
        shot(app, "kalender-409-2-hinweis")
        let afterConflict = try entry("Termin B")
        XCTAssertEqual(afterConflict.plannedAt, at(16), "the rejected drop did not change the server")
        XCTAssertEqual(afterConflict.version, theirsEntry.version, "version not touched by the app")
        // The same stale PATCH by hand: the server's own answer.
        let replay = try patch(start.id, version: start.version, plannedAt: at(14))
        XCTAssertEqual(replay.status, 409, "stale version is refused: \(replay.body)")
        XCTAssertTrue(replay.body.contains("version_conflict"), replay.body)

        // Follow-up with the current version: 16:00 -> about 14:00 again (the drop position is the finger, so it lands near, not on, 14:00).
        drag(jumped, by: -2 * hour)
        try waitFor("server has the new plan") { (try? self.entry("Termin B"))?.version == theirsEntry.version + 1 }
        let final = try entry("Termin B")
        let landed = minutes(final.plannedAt)
        XCTAssertEqual(Double(landed), 14 * 60, accuracy: 30, "landed near 14:00, got \(landed / 60):\(landed % 60)")
        XCTAssertTrue(waitUntilGone(notice), "hint is gone after the successful write")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(block(app, "Termin B").frame.minY, block(app, "Termin A").frame.minY + (CGFloat(landed) / 60 - 10) * hour, accuracy: 4, "block matches the server")
        shot(app, "kalender-409-3-nachher")
        app.terminate()
    }

    // MARK: B) Offline queue, replay on reconnect

    /// Backend off, drag in the app: saved offline with the clock mark; backend on again (same database): the queue replays, the
    /// server has the new time (version + 1), mark and hint are gone.
    func testOfflineDragReplaysAfterReconnect() throws {
        try arrange(movingCardAt: 12)
        let app = launch(liveOff: false)
        let b = block(app, "Termin B"), a = block(app, "Termin A")
        XCTAssertTrue(b.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 2)
        let hour = (b.frame.minY - a.frame.minY) / 2
        shot(app, "kalender-offline-1-vorher")
        let start = try entry("Termin B")

        try command("pause")
        drag(b, by: 2 * hour)
        let notice = noticeElement(app)
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "offline hint")
        XCTAssertTrue(noticeText(app).contains("Ohne Verbindung gespeichert"), "hint text: \(noticeText(app))")
        Thread.sleep(forTimeInterval: 2)
        let moved = block(app, "Termin B")
        let shown = Int(((moved.frame.minY - block(app, "Termin A").frame.minY) / hour + 10) * 60)  // minutes of the day at the block's top
        XCTAssertEqual(Double(shown), 14 * 60, accuracy: 40, "block stays where it was dropped (about 14:00), shows \(shown)")
        XCTAssertTrue(moved.label.contains("Wird gesendet"), "clock mark: \(moved.label)")
        shot(app, "kalender-offline-2-gespeichert")

        try command("resume")
        let began = Date()
        try waitFor("replay reached the server", timeout: 120) { (try? self.entry("Termin B"))?.version == start.version + 1 }
        let replayAfter = Date().timeIntervalSince(began)
        let replayed = try entry("Termin B")
        XCTAssertEqual(Double(minutes(replayed.plannedAt)), Double(shown), accuracy: 8, "server has what the block showed")
        XCTAssertTrue(waitUntilGone(notice, timeout: 60), "hint is gone after the replay (\(Int(replayAfter)) s after reconnect)")
        let settled = block(app, "Termin B")
        XCTAssertTrue(settled.waitForExistence(timeout: 10))
        XCTAssertFalse(settled.label.contains("Wird gesendet"), "clock mark is gone: \(settled.label)")
        shot(app, "kalender-offline-3-nachher")
        app.terminate()
    }

    /// The second client changes the card while the app is offline: the replay is refused (409), the app must say so.
    func testOfflineReplayConflictIsVisible() throws {
        try arrange(movingCardAt: 12)
        let app = launch(liveOff: false)
        let b = block(app, "Termin B"), a = block(app, "Termin A")
        XCTAssertTrue(b.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 2)
        let hour = (b.frame.minY - a.frame.minY) / 2
        let start = try entry("Termin B")

        try command("pause")
        drag(b, by: 2 * hour)
        let notice = noticeElement(app)
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "offline hint")
        try command("resume")
        let theirs = try patch(start.id, version: start.version, plannedAt: at(16))  // right after the restart, before the app's next sync
        XCTAssertEqual(theirs.status, 200, "second client write: \(theirs.body)")
        shot(app, "kalender-konflikt-1-offline-gespeichert")
        Thread.sleep(forTimeInterval: 45)  // sync loop (30 s) replays the queue
        XCTAssertTrue(app.staticTexts["Konflikt bei einer Änderung"].waitForExistence(timeout: 20), "the refused replay is shown as a conflict dialog")
        shot(app, "kalender-konflikt-2-nach-replay")
        let server = try entry("Termin B")
        XCTAssertEqual(server.plannedAt, at(16), "the refused replay did not overwrite the second client's value")
        XCTAssertEqual(server.version, start.version + 1)
        app.terminate()
    }

    // MARK: Helpers

    private func launch(liveOff: Bool) -> XCUIApplication {
        func make() -> XCUIApplication {
            let app = XCUIApplication()
            app.launchEnvironment["TODO_DEBUG_SERVER"] = server
            app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
            app.launchEnvironment["TODO_DEBUG_SELECT"] = "calendar"
            if liveOff { app.launchEnvironment["TODO_DEBUG_LIVE_OFF"] = "1" }
            app.launchArguments += ["-appearance.colorScheme", "light", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
            app.launch()
            return app
        }
        // Absorb the first-request 401 after an install.
        let warm = make(); Thread.sleep(forTimeInterval: 8); warm.terminate()
        return make()
    }

    /// The banner's identifier sits on several elements; the first one is enough for existence, the labels together are the text.
    private func noticeElement(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "calendar.notice").firstMatch
    }

    private func noticeText(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any).matching(identifier: "calendar.notice").allElementsBoundByIndex.map(\.label).joined(separator: " | ")
    }

    private func block(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// Press 0.5 s (a longer press opens the context menu), then drag; the finger moves like a real drag.
    private func drag(_ element: XCUIElement, by dy: CGFloat) {
        let from = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        from.press(forDuration: 0.5, thenDragTo: from.withOffset(CGVector(dx: 0, dy: dy)), withVelocity: .slow, thenHoldForDuration: 1.0)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 30, _ condition: () -> Bool) throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return }; Thread.sleep(forTimeInterval: 1) }
        XCTFail("timeout: \(what)")
        throw XCTSkip("stopped after timeout: \(what)")
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if !element.exists { return true }; Thread.sleep(forTimeInterval: 1) }
        return !element.exists
    }

    /// File handshake with the caller's watcher script.
    private func command(_ name: String) throws {
        let cmd = "\(out)/cmd-\(name)", ack = "\(out)/ack-\(name)"
        try? FileManager.default.removeItem(atPath: ack)
        FileManager.default.createFile(atPath: cmd, contents: Data())
        try waitFor("watcher answered \(name)", timeout: 60) { FileManager.default.fileExists(atPath: ack) }
        Thread.sleep(forTimeInterval: 1)
    }

    // MARK: Plan and second client (plain HTTP)

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        let c = Calendar.current
        return c.date(bySettingHour: hour, minute: minute, second: 0, of: c.startOfDay(for: Date()))!
    }

    private func minutes(_ date: Date?) -> Int {
        guard let date else { return -1 }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private struct PlanEntry { var id: String; var version: Int; var plannedAt: Date?; var minutes: Int? }

    /// Termin A 10:00 and Termin B at the given hour (60 minutes each), written by the second client before the app starts.
    private func arrange(movingCardAt hour: Int) throws {
        for (title, h) in [("Termin A", 10), ("Termin B", hour)] {
            let e = try entry(title)
            if e.plannedAt != at(h) || e.minutes != 60 {
                let r = try patch(e.id, version: e.version, plannedAt: at(h), minutes: 60)
                XCTAssertEqual(r.status, 200, "arrange \(title): \(r.body)")
            }
        }
    }

    private func entry(_ title: String) throws -> PlanEntry {
        let from = Calendar.current.startOfDay(for: Date()), to = from.addingTimeInterval(2 * 86_400)
        let r = try request("GET", "/v1/planning/schedule?from=\(iso.string(from: from))&to=\(iso.string(from: to))", nil)
        let items = (r.json?["items"] as? [[String: Any]]) ?? []
        guard let e = items.first(where: { $0["title"] as? String == title }) else { throw XCTSkip("\(title) not in the plan: \(r.body)") }
        return PlanEntry(id: e["taskID"] as! String, version: e["version"] as! Int,
                         plannedAt: (e["plannedAt"] as? String).flatMap { iso.date(from: $0) }, minutes: e["plannedMinutes"] as? Int)
    }

    private func patch(_ id: String, version: Int, plannedAt: Date, minutes: Int? = nil) throws -> (status: Int, body: String) {
        var body: [String: Any] = ["version": version, "plannedAt": iso.string(from: plannedAt)]
        if let minutes { body["plannedMinutes"] = minutes }
        let r = try request("PATCH", "/v1/tasks/\(id)/schedule", body)
        return (r.status, r.body)
    }

    private func request(_ method: String, _ path: String, _ body: [String: Any]?) throws -> (status: Int, body: String, json: [String: Any]?) {
        var req = URLRequest(url: URL(string: server + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        var result: (Int, Data)?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()); done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        let (status, data) = result ?? (0, Data())
        return (status, String(data: data, encoding: .utf8) ?? "", (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }
}
