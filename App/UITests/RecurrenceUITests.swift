import XCTest

/// Extended recurrence rules in the card detail (card A18F3FF7, contract planning-ext 1.3.0): weekdays, what the next date
/// counts from and the day of the month. Real app against a real backend; every change is read back over REST.
/// Needs `TODO_UITEST_SERVER` / `TODO_UITEST_TOKEN` like `TodoUITests` (skipped without). The screenshot test also needs
/// `TODO_UITEST_HELPER` (set by `scripts/ui-tests.sh`); its PNGs land in `<scratch>/shots`.
@MainActor
final class RecurrenceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server = ""
    private var token = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"] else {
            throw XCTSkip("TODO_UITEST_SERVER / TODO_UITEST_TOKEN not set")
        }
        self.server = server; self.token = token
    }

    // MARK: Server helpers

    @discardableResult
    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: server + path)!)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertTrue((200..<300).contains(code), "\(method) \(path) -> \(code): \(String(data: data, encoding: .utf8) ?? "")")
        let json = try? JSONSerialization.jsonObject(with: data)
        if let list = json as? [Any] { return ["items": list] }
        return json as? [String: Any] ?? [:]
    }

    /// A card due today at noon (so it is listed under "Heute"), optionally already repeating.
    private func createCard(_ name: String, rule: [String: Any]? = nil) async throws -> (id: String, title: String) {
        let projects = try await request("GET", "/v1/projects")["items"] as? [[String: Any]] ?? []
        let projectID = try XCTUnwrap(projects.first?["id"] as? String, "seeded project")
        let title = "\(name) \(Int(Date().timeIntervalSince1970 * 10) % 1000000)"
        let created = try await request("POST", "/v1/tasks", body: ["projectID": projectID, "title": title])
        let id = try XCTUnwrap(created["id"] as? String, "created task")
        let noon = try XCTUnwrap(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
        var body: [String: Any] = ["dueAt": ISO8601DateFormatter().string(from: noon), "priority": 0, "reminders": [String]()]
        if let rule { body["recurrence"] = rule }
        try await request("PUT", "/v1/planning/tasks/\(id)", body: body)
        return (id, title)
    }

    private func storedPlanning(_ id: String) async throws -> [String: Any] { try await request("GET", "/v1/planning/tasks/\(id)") }

    /// Waits until the server holds a rule that satisfies `check` (the app saves in the background).
    private func expectRule(_ id: String, _ what: String, file: StaticString = #filePath, line: UInt = #line,
                            _ check: ([String: Any]) -> Bool) async throws {
        var last: [String: Any] = [:]
        for _ in 0..<40 {
            last = try await storedPlanning(id)["recurrence"] as? [String: Any] ?? [:]
            if check(last) { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("server rule: \(what), is \(last)", file: file, line: line)
    }

    // MARK: App helpers

    private func launch() {
        app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_SERVER"] = server
        app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        app.launchEnvironment["TODO_DEBUG_SELECT"] = "today"
        app.launchEnvironment["TODO_DEBUG_NOW"] = "12:00"
        app.launch()
        XCTAssertTrue(app.buttons["quickAddButton"].waitForExistence(timeout: 30))
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func weekday(_ iso: Int) -> XCUIElement { app.buttons["repeat.weekday.\(iso)"] }

    /// The row has to stand still and end above the floating tab bar before the tap (see `TodoUITests`).
    private func openCard(_ title: String) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        for _ in 0..<25 where !row.waitForExistence(timeout: 1) { app.swipeUp() }
        XCTAssertTrue(row.exists, "row \(title) in Heute")
        let bar = app.tabBars.firstMatch
        let limit = bar.exists ? bar.frame.minY : app.frame.maxY
        for _ in 0..<8 where !(row.isHittable && row.frame.maxY <= limit) { app.swipeUp(velocity: .slow) }
        var last = CGRect.zero
        for _ in 0..<15 where row.frame != last {
            last = row.frame
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 0.3)
        }
        row.tap()
        if !app.buttons["Fertig"].waitForExistence(timeout: 3) { row.tap() }
        XCTAssertTrue(element("task.repeat.menu").waitForExistence(timeout: 15), "detail with the repeat row")
    }

    /// Opens a menu of the detail and picks an entry; long menus (day of the month) are scrolled until the entry is there.
    private func pick(_ menu: String, _ entry: String, file: StaticString = #filePath, line: UInt = #line) {
        let control = element(menu)
        reveal(control)
        XCTAssertTrue(control.waitForExistence(timeout: 5), "menu \(menu)", file: file, line: line)
        control.tap()
        let item = app.collectionViews.buttons[entry].firstMatch
        for _ in 0..<12 where !(item.exists && item.isHittable) {
            let list = app.collectionViews.containing(NSPredicate(format: "label MATCHES %@", "[0-9]+[.]")).firstMatch
            if list.exists { list.swipeUp(velocity: .slow) } else { _ = item.waitForExistence(timeout: 1) }
        }
        XCTAssertTrue(item.exists, "entry \(entry) in \(menu)", file: file, line: line)
        item.tap()
    }

    private func reveal(_ e: XCUIElement) {
        for _ in 0..<8 where !(e.exists && e.frame.maxY < app.frame.maxY - 140 && e.frame.minY > 100) {
            if e.exists && e.frame.minY <= 100 { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
    }

    /// iPad: the detail is a small centred sheet at large text, so the chips can sit under the message field although they are
    /// inside the window. Drags the sheet in small steps until the last day ends above that field and can be tapped.
    private func scrollSheetToLastWeekday() {
        let composer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chat.field.'")).firstMatch
        let window = app.windows.firstMatch
        for _ in 0..<12 where !(weekday(7).isHittable && weekday(7).frame.maxY < composer.frame.minY - 16) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50)))
        }
        XCTAssertTrue(weekday(7).isHittable, "last weekday can be tapped at large text")
        XCTAssertLessThan(weekday(7).frame.maxY, composer.frame.minY, "last weekday above the message field")
    }

    private func expectValue(_ id: String, contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        let e = element(id)
        let shows = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [shows], timeout: 10), .completed, "\(id) shows \(text), is \"\(e.exists ? e.label : "missing")\"", file: file, line: line)
    }

    // MARK: Tests

    func testWeekdaysBasisAndMonthDayAreSetInTheDetail() async throws {
        let card = try await createCard("Wiederholung")
        launch()
        openCard(card.title)
        XCTAssertFalse(weekday(1).exists, "no weekday row without a weekly rule")
        XCTAssertFalse(element("task.repeat.basis").exists, "no basis row without a rule")

        pick("task.repeat.menu", "Wöchentlich")
        XCTAssertTrue(weekday(1).waitForExistence(timeout: 5), "weekday row for weekly")
        for day in 1...7 { XCTAssertTrue(weekday(day).exists, "weekday \(day)") }
        XCTAssertFalse(element("task.repeat.monthDay").exists, "no day of the month for weekly")
        XCTAssertEqual(weekday(4).label, "Donnerstag", "spoken name, not the abbreviation")
        XCTAssertGreaterThanOrEqual(weekday(4).frame.width, 43.5, "tap target")
        XCTAssertGreaterThanOrEqual(weekday(4).frame.height, 43.5, "tap target")
        reveal(weekday(7))
        weekday(4).tap()
        weekday(1).tap()
        try await expectRule(card.id, "weekdays [1, 4]") { $0["weekdays"] as? [Int] == [1, 4] }
        XCTAssertTrue(weekday(1).isSelected && weekday(4).isSelected, "chosen days are marked")
        XCTAssertFalse(weekday(2).isSelected)

        expectValue("task.repeat.basis", contains: "Fälligkeit")
        pick("task.repeat.basis", "Ab Erledigung")
        try await expectRule(card.id, "basis completion, weekdays kept") { $0["basis"] as? String == "completion" && $0["weekdays"] as? [Int] == [1, 4] }

        // Closed and opened again: the app shows what is stored.
        app.buttons["Fertig"].tap()
        XCTAssertTrue(app.buttons["Fertig"].waitForNonExistence(timeout: 5))
        app.terminate()
        launch()
        openCard(card.title)
        XCTAssertTrue(weekday(1).waitForExistence(timeout: 10))
        reveal(weekday(7))
        XCTAssertTrue(weekday(1).isSelected && weekday(4).isSelected, "weekdays after a restart")
        expectValue("task.repeat.basis", contains: "Erledigung")

        weekday(1).tap()
        try await expectRule(card.id, "weekdays [4]") { $0["weekdays"] as? [Int] == [4] }
        weekday(4).tap()
        try await expectRule(card.id, "no empty list") { $0["weekdays"] == nil && $0["frequency"] as? String == "weekly" }

        pick("task.repeat.menu", "Monatlich")
        XCTAssertTrue(element("task.repeat.monthDay").waitForExistence(timeout: 5), "day of the month for monthly")
        XCTAssertFalse(weekday(1).exists, "no weekdays for monthly")
        expectValue("task.repeat.monthDay", contains: "Wie Fälligkeit")
        pick("task.repeat.monthDay", "31.")
        try await expectRule(card.id, "monthDay 31, basis kept") {
            $0["monthDay"] as? Int == 31 && $0["frequency"] as? String == "monthly" && $0["basis"] as? String == "completion" && $0["weekdays"] == nil
        }
        expectValue("task.repeat.monthDay", contains: "31.")
        XCTAssertTrue(element("task.repeat.monthEnd").waitForExistence(timeout: 5), "hint: short months are shortened")

        pick("task.repeat.basis", "Ab Fälligkeit")
        try await expectRule(card.id, "default basis is not stored") { $0["basis"] == nil && $0["monthDay"] as? Int == 31 }
        pick("task.repeat.monthDay", "Wie Fälligkeit")
        try await expectRule(card.id, "no day of the month") { $0["monthDay"] == nil && $0["frequency"] as? String == "monthly" }
    }

    /// `PUT` replaces the whole planning: changing something else in the app must not lose the rule's new fields.
    func testChangingThePriorityKeepsTheExtendedRule() async throws {
        let card = try await createCard("Regel bleibt", rule: [
            "frequency": "weekly", "interval": 2, "timeZone": "Europe/Berlin", "weekdays": [2, 5], "basis": "completion",
        ])
        launch()
        openCard(card.title)
        XCTAssertTrue(weekday(2).waitForExistence(timeout: 10))
        XCTAssertTrue(weekday(2).isSelected && weekday(5).isSelected)
        pick("task.priority.menu", "Priorität 1")
        for _ in 0..<40 {
            if try await storedPlanning(card.id)["priority"] as? Int == 3 { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        let stored = try await storedPlanning(card.id)
        XCTAssertEqual(stored["priority"] as? Int, 3, "the change arrived")
        let rule = try XCTUnwrap(stored["recurrence"] as? [String: Any])
        XCTAssertEqual(rule["weekdays"] as? [Int], [2, 5])
        XCTAssertEqual(rule["basis"] as? String, "completion")
        XCTAssertEqual(rule["interval"] as? Int, 2)
        // Picking the frequency that is already set changes nothing (interval 2 stays).
        pick("task.repeat.menu", "Wöchentlich")
        try await Task.sleep(for: .seconds(2))
        let reread = try await storedPlanning(card.id)
        let again = try XCTUnwrap(reread["recurrence"] as? [String: Any])
        XCTAssertEqual(again["interval"] as? Int, 2)
        XCTAssertEqual(again["weekdays"] as? [Int], [2, 5])
    }

    // MARK: Screenshots (light, dark, large text)

    /// Synchronous on purpose (like `TodoUITests`): an async teardown block on the main actor hangs the test runner.
    private func helper(_ path: String) throws {
        guard let base = ProcessInfo.processInfo.environment["TODO_UITEST_HELPER"], let url = URL(string: base + path) else {
            throw XCTSkip("TODO_UITEST_HELPER not set (run through scripts/ui-tests.sh)")
        }
        final class Box: @unchecked Sendable { var status = 0 }
        let box = Box(), done = expectation(description: "helper \(path)")
        URLSession.shared.dataTask(with: url) { _, response, _ in box.status = (response as? HTTPURLResponse)?.statusCode ?? 0; done.fulfill() }.resume()
        wait(for: [done], timeout: 90)
        XCTAssertEqual(box.status, 200, "helper call \(path)")
    }

    private func shot(_ name: String) async throws {
        try await Task.sleep(for: .seconds(2))
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        try helper("/shot/\(name)")
    }

    func testRecurrenceScreenshotsLightAndDark() async throws {
        let weekly = try await createCard("Sport", rule: [
            "frequency": "weekly", "interval": 1, "timeZone": "Europe/Berlin", "weekdays": [1, 4], "basis": "completion",
        ])
        let monthly = try await createCard("Miete", rule: ["frequency": "monthly", "interval": 1, "timeZone": "Europe/Berlin", "monthDay": 31])
        try helper("/appearance/light")
        addTeardownBlock { @MainActor in
            try? self.helper("/appearance/light")
            try? self.helper("/size/large")
        }
        for (card, kind) in [(weekly, "woche"), (monthly, "monat")] {
            launch()
            openCard(card.title)
            reveal(element("task.repeat.basis"))
            for look in ["light", "dark"] {
                try helper("/appearance/\(look)")
                try await shot("\(kind)-\(look)")
            }
            if kind == "monat" {
                element("task.repeat.monthDay").tap()
                try await shot("\(kind)-menue-dark")
                try helper("/appearance/light")
                try await shot("\(kind)-menue-light")
            } else {
                try helper("/appearance/light")
                try helper("/size/accessibility-extra-large")
                reveal(weekday(1))
                if UIDevice.current.userInterfaceIdiom == .pad { scrollSheetToLastWeekday() }
                try await shot("\(kind)-grosse-schrift-light")
                for day in 1...7 { XCTAssertTrue(weekday(day).exists, "weekday \(day) at large text") }
                try helper("/appearance/dark")
                try await shot("\(kind)-grosse-schrift-dark")
                try helper("/size/large")
                try helper("/appearance/light")
            }
            app.terminate()
        }
    }
}
