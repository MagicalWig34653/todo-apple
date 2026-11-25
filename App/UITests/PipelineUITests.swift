import XCTest

/// Plan approval and pipeline status in the card detail (card B6FC965A, contract pipeline 1.0.0): the plan is shown, "Plan freigeben"
/// and "Änderungen" decide it, the six steps show their state, and the new activity kinds have names. Real app against a real
/// backend; every decision is read back over REST. Needs `TODO_UITEST_SERVER` / `TODO_UITEST_TOKEN` like `TodoUITests` (skipped
/// without). The screenshot test also needs `TODO_UITEST_HELPER` (set by `scripts/ui-tests.sh`); its PNGs land in `<scratch>/shots`.
@MainActor
final class PipelineUITests: XCTestCase {
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

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

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

    private static let planText = "# Ziel\nPlan und Schritte je Karte zeigen.\n\n## Schritte\n- Dekodierung in TodoCore\n- Karte im Detail\n  - Freigabe und Änderungen\n1. Test zuerst\n2. Umsetzung\n\n```\nswift test\n```\nAbschluss mit **Bildern**."

    /// A card due today at noon (so it is listed under "Heute"), optionally with a plan (version 1, proposed).
    private func createCard(_ name: String, plan: String? = nil) async throws -> (id: String, title: String) {
        let projects = try await request("GET", "/v1/projects")["items"] as? [[String: Any]] ?? []
        let projectID = try XCTUnwrap(projects.first?["id"] as? String, "seeded project")
        let title = "\(name) \(Int(Date().timeIntervalSince1970 * 10) % 1000000)"
        let created = try await request("POST", "/v1/tasks", body: ["projectID": projectID, "title": title])
        let id = try XCTUnwrap(created["id"] as? String, "created task")
        let noon = try XCTUnwrap(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
        try await request("PUT", "/v1/planning/tasks/\(id)", body: ["dueAt": ISO8601DateFormatter().string(from: noon), "priority": 0, "reminders": [String]()])
        if let plan { try await request("PUT", "/v1/tasks/\(id)/plan", body: ["body": plan, "expectedVersion": 0]) }
        return (id, title)
    }

    private func pipeline(_ id: String) async throws -> [String: Any] { try await request("GET", "/v1/tasks/\(id)/pipeline") }

    private func stepState(_ pipeline: [String: Any], _ step: String) -> String? {
        (pipeline["steps"] as? [[String: Any]])?.first { $0["step"] as? String == step }?["state"] as? String
    }

    /// Waits until the server's pipeline satisfies `check` (the app decides in the background).
    private func expectPipeline(_ id: String, _ what: String, file: StaticString = #filePath, line: UInt = #line,
                                _ check: ([String: Any]) -> Bool) async throws {
        var last: [String: Any] = [:]
        for _ in 0..<40 {
            last = try await pipeline(id)
            if check(last) { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("server pipeline: \(what), is \(last)", file: file, line: line)
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

    /// The row has to stand still and end above the floating tab bar before the tap (see `TodoUITests`).
    private func openCard(_ title: String, waitFor id: String = "plan.state") {
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
        XCTAssertTrue(element(id).waitForExistence(timeout: 20), "detail with \(id)")
    }

    private func reveal(_ e: XCUIElement) {
        for _ in 0..<10 where !(e.exists && e.frame.maxY < app.frame.maxY - 140 && e.frame.minY > 100) {
            if e.exists && e.frame.minY <= 100 { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
    }

    private func expectLabel(_ id: String, contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        let e = element(id)
        let shows = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [shows], timeout: 15), .completed,
                       "\(id) shows \(text), is \"\(e.exists ? e.label : "missing")\" / \"\(e.exists ? "\(e.value ?? "")" : "")\"", file: file, line: line)
    }

    // MARK: Tests

    func testApprovingThePlanInTheDetail() async throws {
        let card = try await createCard("Plan freigeben", plan: Self.planText)
        launch()
        openCard(card.title)
        expectLabel("plan.state", contains: "Wartet auf dich")
        XCTAssertTrue(app.staticTexts["Plan und Schritte je Karte zeigen."].waitForExistence(timeout: 5), "plan text is shown")
        XCTAssertTrue(app.staticTexts["Test zuerst"].exists || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Test zuerst'")).firstMatch.exists, "list item")
        expectLabel("pipeline.step.planner", contains: "Erledigt")
        expectLabel("pipeline.step.approval", contains: "Wartet auf Freigabe")
        expectLabel("pipeline.step.developer", contains: "Offen")
        XCTAssertTrue(element("plan.approve").exists && element("plan.changes").exists, "both actions while the plan waits")

        reveal(element("plan.approve"))
        element("plan.approve").tap()
        try await expectPipeline(card.id, "plan approved, approval done") {
            ($0["plan"] as? [String: Any])?["state"] as? String == "approved" && self.stepState($0, "approval") == "done"
        }
        expectLabel("plan.state", contains: "Freigegeben")
        expectLabel("pipeline.step.approval", contains: "Erledigt")
        XCTAssertFalse(element("plan.approve").exists, "no actions after the decision")
        XCTAssertFalse(element("plan.changes").exists)
    }

    func testRequestingChangesNeedsAComment() async throws {
        let card = try await createCard("Plan ablehnen", plan: Self.planText)
        launch()
        openCard(card.title)
        reveal(element("plan.changes"))
        element("plan.changes").tap()
        XCTAssertTrue(element("plan.changes.comment").waitForExistence(timeout: 5), "comment field")
        XCTAssertFalse(element("plan.changes.send").isEnabled, "no sending without a comment")
        element("plan.changes.comment").tap()
        element("plan.changes.comment").typeText("Bitte Tests zuerst")
        XCTAssertTrue(element("plan.changes.send").isEnabled)
        element("plan.changes.send").tap()
        try await expectPipeline(card.id, "changes requested with comment") {
            let plan = $0["plan"] as? [String: Any]
            return plan?["state"] as? String == "changes_requested" && plan?["decisionComment"] as? String == "Bitte Tests zuerst"
                && self.stepState($0, "approval") == "changes_requested" && self.stepState($0, "planner") == "pending"
        }
        expectLabel("plan.state", contains: "Änderungen verlangt")
        expectLabel("plan.decision.comment", contains: "Bitte Tests zuerst")
        XCTAssertFalse(element("plan.approve").exists)
    }

    func testStepStatesAndActivityNamesAreShown() async throws {
        let card = try await createCard("Schritte", plan: Self.planText)
        try await request("POST", "/v1/tasks/\(card.id)/plan/decision", body: ["decision": "approve", "version": 1])
        try await request("PUT", "/v1/tasks/\(card.id)/pipeline/steps/developer", body: ["state": "running", "note": "Baut die Karte"])
        try await request("PUT", "/v1/tasks/\(card.id)/pipeline/steps/validation", body: ["state": "failed", "note": "1 Test rot"])
        launch()
        openCard(card.title)
        expectLabel("pipeline.step.planner", contains: "Erledigt")
        expectLabel("pipeline.step.approval", contains: "Erledigt")
        expectLabel("pipeline.step.developer", contains: "Läuft")
        expectLabel("pipeline.step.developer", contains: "Baut die Karte")
        expectLabel("pipeline.step.validation", contains: "Fehlgeschlagen")
        expectLabel("pipeline.step.tester", contains: "Offen")

        // The new activity kinds have names, not raw kinds.
        let activity = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Aktivität'")).firstMatch
        for _ in 0..<12 where !activity.isHittable { app.swipeUp(velocity: .slow) }
        activity.tap()
        for name in ["Plan geschrieben", "Plan freigegeben", "Pipeline-Schritt gemeldet"] {
            let text = app.staticTexts[name].firstMatch
            for _ in 0..<8 where !text.exists { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(text.exists, "activity \(name)")
        }
        for raw in ["plan.written", "plan.approved", "pipeline.step"] { XCTAssertFalse(app.staticTexts[raw].exists, "no raw kind \(raw)") }

        // Live: a step reported while the detail is open shows up without reopening.
        try await request("PUT", "/v1/tasks/\(card.id)/pipeline/steps/tester", body: ["state": "running", "note": "Läuft gerade"])
        reveal(element("pipeline.step.tester"))
        expectLabel("pipeline.step.tester", contains: "Läuft")
    }

    func testNewKindsAreNamedInTheNowOverview() async throws {
        let card = try await createCard("Jetzt Plan", plan: Self.planText)
        try await request("POST", "/v1/tasks/\(card.id)/plan/decision", body: ["decision": "approve", "version": 1])
        launch()
        XCTAssertTrue(app.buttons["quickAddButton"].exists)
        if isPad {
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Jetzt")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 30), "sidebar row Jetzt")
            row.tap()
        } else {
            let tab = app.tabBars.buttons["Jetzt"]
            XCTAssertTrue(tab.waitForExistence(timeout: 30), "tab Jetzt")
            tab.tap()
        }
        XCTAssertTrue(element("now.screen").waitForExistence(timeout: 20))
        let named = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Plan freigegeben: \(card.title)")).firstMatch
        for _ in 0..<25 where !named.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(named.exists, "the overview names plan.approved")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'plan.approved'")).firstMatch.exists, "no raw kind")
    }

    // MARK: Screenshots (light, dark)

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

    func testPlanScreenshotsLightAndDark() async throws {
        let device = isPad ? "ipad" : "iphone"
        let waiting = try await createCard("Bild Plan wartet", plan: Self.planText)
        let running = try await createCard("Bild Plan laeuft", plan: Self.planText)
        try await request("POST", "/v1/tasks/\(running.id)/plan/decision", body: ["decision": "approve", "version": 1])
        try await request("PUT", "/v1/tasks/\(running.id)/pipeline/steps/developer", body: ["state": "running", "note": "Baut die Karte"])
        try await request("PUT", "/v1/tasks/\(running.id)/pipeline/steps/validation", body: ["state": "failed", "note": "1 Test rot"])
        try helper("/appearance/light")
        addTeardownBlock { @MainActor in try? self.helper("/appearance/light") }
        for (card, kind) in [(waiting, "wartet"), (running, "laeuft")] {
            launch()
            openCard(card.title)
            reveal(element("plan.state"))
            for look in ["light", "dark"] {
                try helper("/appearance/\(look)")
                try await shot("\(device)-\(kind)-\(look)-1-plan")
                reveal(element("pipeline.step.review"))
                try await shot("\(device)-\(kind)-\(look)-2-schritte")
                reveal(element("plan.state"))
            }
            try helper("/appearance/light")
            app.terminate()
        }
    }
}
