import XCTest

/// Pipeline stage 3 in the card detail (card BEE2417E, contract pipeline 1.2.0): the section "Ausführung" with start, state per
/// step, device, progress, budget brake, continue, stop and retry, like the PWA. Real app against a real backend; the test plays
/// the Mac runner over the runner API (pair, poll with `pipeline=1`, hold, claim, progress, submit) and reads every action back
/// over REST. Every test uses its own project and runner device, so other tests never see a binding. Needs `TODO_UITEST_SERVER` /
/// `TODO_UITEST_TOKEN` (skipped without); with `TODO_UITEST_HELPER` (scripts/ui-tests.sh) the states are also taken as pictures in
/// light and dark (`<scratch>/shots/<device>-ausfuehrung-…`). The sending state needs `TODO_UITEST_DELAY_PROXY`
/// (`scripts/selection-proxy.py` in front of the backend, started by `scripts/ui-tests.sh`).
@MainActor
final class PipelineExecutionUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server = ""
    private var token = ""
    private var devices: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"] else {
            throw XCTSkip("TODO_UITEST_SERVER / TODO_UITEST_TOKEN not set")
        }
        self.server = server; self.token = token
    }

    override func tearDownWithError() throws {
        // Revoke the test's runner devices, so the settings of other tests stay as they were.
        for id in devices { try? sync("DELETE", "/v1/agents/devices/\(id)") }
        if ProcessInfo.processInfo.environment["TODO_UITEST_HELPER"] != nil { try? helper("/appearance/light") }
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var device: String { isPad ? "ipad" : "iphone" }

    // MARK: Server helpers

    @discardableResult
    private func request(_ method: String, _ path: String, body: [String: Any]? = nil, as bearer: String? = nil,
                         expect: ClosedRange<Int> = 200...299) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: server + path)!)
        r.httpMethod = method
        if bearer != "" { r.setValue("Bearer \(bearer ?? token)", forHTTPHeaderField: "Authorization") }
        if let body { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertTrue(expect.contains(code), "\(method) \(path) -> \(code): \(String(data: data, encoding: .utf8) ?? "")")
        let json = try? JSONSerialization.jsonObject(with: data)
        if let list = json as? [Any] { return ["items": list] }
        return json as? [String: Any] ?? [:]
    }

    /// Synchronous on purpose, for the teardown (an async teardown on the main actor hangs the test runner).
    private func sync(_ method: String, _ path: String) throws {
        var r = URLRequest(url: URL(string: server + path)!)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let done = expectation(description: "\(method) \(path)")
        URLSession.shared.dataTask(with: r) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 30)
    }

    private struct Runner { let projectID: String; let deviceID: String; let token: String; let label: String }

    /// Own project, a paired runner device and its binding to the project (like `scripts/pipeline-e2e.py` in the main repository).
    private func pairRunner(_ name: String) async throws -> Runner {
        let stamp = Int(Date().timeIntervalSince1970 * 10) % 1000000
        let project = try await request("POST", "/v1/projects", body: ["name": "Ausführung \(name) \(stamp)"])
        let projectID = try XCTUnwrap(project["id"] as? String, "project")
        let pairing = try await request("POST", "/v1/agents/devices", body: ["label": "Linos Mac"])
        let deviceID = try XCTUnwrap(pairing["deviceID"] as? String, "device")
        let code = try XCTUnwrap(pairing["code"] as? String, "pairing code")
        devices.append(deviceID)
        let paired = try await request("POST", "/v1/runner/pair", body: ["code": code], as: "")
        let runnerToken = try XCTUnwrap(paired["token"] as? String, "runner token")
        try await request("POST", "/v1/agents/bindings", body: ["projectID": projectID, "deviceID": deviceID,
                                                                "repositoryKey": UUID().uuidString.lowercased(), "label": "todo-apple"])
        return Runner(projectID: projectID, deviceID: deviceID, token: runnerToken, label: "Linos Mac · todo-apple")
    }

    /// A card due today at noon (listed under "Heute"), with an approved plan (the next step is the developer) or without one.
    private func createCard(_ name: String, in projectID: String, plan: Bool = true) async throws -> (id: String, title: String) {
        let title = "\(name) \(Int(Date().timeIntervalSince1970 * 10) % 1000000)"
        let created = try await request("POST", "/v1/tasks", body: ["projectID": projectID, "title": title])
        let id = try XCTUnwrap(created["id"] as? String, "created task")
        let noon = try XCTUnwrap(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
        try await request("PUT", "/v1/planning/tasks/\(id)", body: ["dueAt": ISO8601DateFormatter().string(from: noon), "priority": 0, "reminders": [String]()])
        guard plan else { return (id, title) }
        try await request("PUT", "/v1/tasks/\(id)/plan", body: ["body": "# Ziel\nAusführung in der App zeigen.\n\n- Test zuerst\n- Umsetzung", "expectedVersion": 0])
        try await request("POST", "/v1/tasks/\(id)/plan/decision", body: ["decision": "approve", "version": 1])
        return (id, title)
    }

    private func pipeline(_ id: String) async throws -> [String: Any] { try await request("GET", "/v1/tasks/\(id)/pipeline") }
    private func execution(_ p: [String: Any]) -> [String: Any] { p["execution"] as? [String: Any] ?? [:] }
    private func stepState(_ p: [String: Any], _ step: String) -> String? {
        (p["steps"] as? [[String: Any]])?.first { $0["step"] as? String == step }?["state"] as? String
    }

    /// Waits until the server's pipeline satisfies `check`.
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

    // Runner side (runner token).

    /// The one queued pipeline job (polling with `pipeline=1` also tells the server that this runner can run pipelines).
    private func queuedJob(_ runner: Runner, step: String, file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        for _ in 0..<20 {
            let jobs = try await request("GET", "/v1/runner/jobs?pipeline=1", as: runner.token)["items"] as? [[String: Any]] ?? []
            if let job = jobs.first(where: { $0["pipelineStep"] as? String == step }), let id = job["id"] as? String { return id }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("no queued job for \(step)", file: file, line: line)
        return ""
    }

    private func claim(_ runner: Runner, _ job: String) async throws -> String {
        let run = try await request("POST", "/v1/runner/jobs/\(job)/claim?pipeline=1", as: runner.token)
        return try XCTUnwrap(run["id"] as? String, "run")
    }

    private func submit(_ runner: Runner, _ run: String, _ outcome: String) async throws {
        try await request("POST", "/v1/runner/runs/\(run)/submit", body: [
            "generation": 1, "outcome": outcome,
            "result": ["summary": outcome == "passed" ? "erledigt" : "1 Test rot", "references": [String](), "checks": [String](), "limitations": [String]()],
        ], as: runner.token)
    }

    // MARK: App helpers

    private func launch(through appServer: String? = nil) {
        app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_SERVER"] = appServer ?? server
        app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        app.launchEnvironment["TODO_DEBUG_SELECT"] = "today"
        app.launchEnvironment["TODO_DEBUG_NOW"] = "12:00"
        app.launch()
        XCTAssertTrue(app.buttons["quickAddButton"].waitForExistence(timeout: 30))
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// The row has to stand still and end above the floating tab bar before the tap (see `TodoUITests`).
    private func openCard(_ title: String, waitFor id: String) {
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

    private func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let e = element(id)
        XCTAssertTrue(e.waitForExistence(timeout: 15), "\(id) exists", file: file, line: line)
        reveal(e)
        e.tap()
    }

    private func expectLabel(_ id: String, contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        let e = element(id)
        let shows = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [shows], timeout: 20), .completed,
                       "\(id) shows \(text), is \"\(e.exists ? e.label : "missing")\" / \"\(e.exists ? "\(e.value ?? "")" : "")\"", file: file, line: line)
    }

    /// Gone, or no longer showing `text`.
    private func expectNoLabel(_ id: String, contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        let e = element(id)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR NOT (label CONTAINS %@)", text), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed, "\(id) no longer shows \(text), is \"\(e.label)\"", file: file, line: line)
    }

    private func expectGone(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(id))
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed, "\(id) disappears", file: file, line: line)
    }

    // MARK: Pictures (only through scripts/ui-tests.sh)

    private func helper(_ path: String) throws {
        guard let base = ProcessInfo.processInfo.environment["TODO_UITEST_HELPER"], let url = URL(string: base + path) else { return }
        final class Box: @unchecked Sendable { var status = 0 }
        let box = Box(), done = expectation(description: "helper \(path)")
        URLSession.shared.dataTask(with: url) { _, response, _ in box.status = (response as? HTTPURLResponse)?.statusCode ?? 0; done.fulfill() }.resume()
        wait(for: [done], timeout: 90)
        XCTAssertEqual(box.status, 200, "helper call \(path)")
    }

    /// The state in light and dark, with `id` in view.
    private func pictures(_ name: String, showing id: String) async throws {
        guard ProcessInfo.processInfo.environment["TODO_UITEST_HELPER"] != nil else { return }
        reveal(element(id))
        for look in ["light", "dark"] {
            try helper("/appearance/\(look)")
            try await Task.sleep(for: .seconds(2))
            let a = XCTAttachment(screenshot: app.screenshot()); a.name = "\(device)-ausfuehrung-\(name)-\(look)"; a.lifetime = .keepAlways; add(a)
            try helper("/shot/\(device)-ausfuehrung-\(name)-\(look)")
        }
        try helper("/appearance/light")
    }

    // MARK: Tests

    /// Start in the app, then the runner: poll (old-runner warning goes), budget brake, claim with progress (the brake notice goes),
    /// a failed validation blocks, "Wiederholen" runs the step again, "Stoppen" ends it and the live line goes.
    func testStartHoldProgressBlockedRetryAndStop() async throws {
        let runner = try await pairRunner("Lauf")
        let card = try await createCard("Ausführung Lauf", in: runner.projectID)
        launch()
        openCard(card.title, waitFor: "execution.start")
        expectLabel("execution.binding", contains: runner.label)
        try await pictures("lauf-1-start", showing: "execution.start")

        tap("execution.start")
        try await expectPipeline(card.id, "started at the developer") {
            self.execution($0)["state"] as? String == "running" && self.execution($0)["step"] as? String == "developer"
        }
        expectLabel("execution.state", contains: "Läuft")
        expectLabel("execution.step", contains: "Umsetzung")
        expectLabel("execution.device", contains: runner.label)
        expectLabel("execution.feedback", contains: "Pipeline gestartet.")
        expectLabel("execution.unsupported", contains: "noch keinen Pipeline-Auftrag")
        expectLabel("pipeline.step.developer", contains: "Wartet auf den Runner")
        XCTAssertFalse(element("execution.start").exists, "no second start while it runs")
        try await pictures("lauf-2-gestartet", showing: "execution.device")

        // The runner polls (it can run pipelines) and holds the job back.
        let developer = try await queuedJob(runner, step: "developer")
        try await request("POST", "/v1/runner/jobs/\(developer)/hold", body: ["reason": "Kontingent-Bremse: Ampel rot bis 14:00"], as: runner.token)
        expectLabel("execution.hold", contains: "Kontingent-Bremse: Ampel rot bis 14:00")
        expectLabel("pipeline.step.developer", contains: "Der Runner wartet")
        expectGone("execution.unsupported")
        try await pictures("lauf-3-bremse", showing: "execution.hold")

        // Claimed with progress: the brake notice goes, the progress shows in the section and at the step.
        let run = try await claim(runner, developer)
        try await request("POST", "/v1/runner/runs/\(run)/progress", body: ["generation": 1, "progress": "Schreibe die Tests"], as: runner.token)
        expectLabel("execution.progress", contains: "Schreibe die Tests")
        expectLabel("pipeline.step.developer", contains: "Läuft auf dem Runner: Schreibe die Tests")
        expectGone("execution.hold")
        try await pictures("lauf-4-fortschritt", showing: "execution.progress")
        try await submit(runner, run, "passed")

        // A failed validation blocks the execution; the retry is offered at the step.
        let validation = try await queuedJob(runner, step: "validation")
        try await submit(runner, try await claim(runner, validation), "failed")
        expectLabel("execution.state", contains: "Blockiert")
        expectLabel("execution.hint", contains: "„Validierung“ ist fehlgeschlagen")
        expectLabel("execution.rounds", contains: "0 von 3")
        expectLabel("pipeline.step.validation", contains: "Fehlgeschlagen")
        expectLabel("pipeline.retry.hint", contains: "erneut auf dem Runner")
        expectNoLabel("execution.feedback", contains: "gestartet")
        try await pictures("lauf-5-blockiert", showing: "pipeline.retry.validation")

        tap("pipeline.retry.validation")
        try await expectPipeline(card.id, "validation runs again") {
            self.execution($0)["state"] as? String == "running" && self.execution($0)["step"] as? String == "validation"
                && self.stepState($0, "validation") == "pending" && ($0["fixRounds"] as? [String: Any])?["used"] as? Int == 1
        }
        expectLabel("execution.state", contains: "Läuft")
        expectLabel("pipeline.step.validation", contains: "Wartet auf den Runner")
        try await pictures("lauf-6-wiederholt", showing: "pipeline.step.validation")

        tap("execution.stop")
        try await expectPipeline(card.id, "stopped") { self.execution($0)["state"] as? String == "stopped" }
        expectLabel("execution.state", contains: "Gestoppt")
        expectLabel("execution.hint", contains: "wurde gestoppt")
        expectNoLabel("pipeline.step.validation", contains: "Runner")
        expectGone("execution.stop")
        XCTAssertTrue(element("execution.start").waitForExistence(timeout: 10), "a stopped execution can be started again")
        try await pictures("lauf-7-gestoppt", showing: "execution.hint")
    }

    /// The card changed while the job waited: the runner's claim pauses the execution (shown in the open card without reopening);
    /// "Fortsetzen" goes on with the shown plan.
    func testPausedAfterCardChangeContinues() async throws {
        let runner = try await pairRunner("Pause")
        let card = try await createCard("Ausführung Pause", in: runner.projectID)
        let bindingID = try await bindingID(runner)
        try await request("POST", "/v1/tasks/\(card.id)/pipeline/execution", body: ["id": UUID().uuidString.lowercased(), "bindingID": bindingID])
        let job = try await queuedJob(runner, step: "developer")

        launch()
        openCard(card.title, waitFor: "execution.stop")
        expectLabel("execution.state", contains: "Läuft")
        XCTAssertFalse(element("execution.continue").exists, "no continue while it runs")
        try await pictures("pause-1-laeuft", showing: "execution.stop")

        let task = try await request("GET", "/v1/planning/tasks/\(card.id)")["task"] as? [String: Any] ?? [:]
        try await request("PATCH", "/v1/tasks/\(card.id)", body: ["description": "Neu: auch iPad", "version": task["version"] as? Int ?? 1])
        try await request("POST", "/v1/runner/jobs/\(job)/claim?pipeline=1", as: runner.token, expect: 200...499)
        try await expectPipeline(card.id, "paused, task changed") {
            self.execution($0)["state"] as? String == "paused" && self.execution($0)["reason"] as? String == "task_changed"
        }
        expectLabel("execution.state", contains: "Angehalten")
        expectLabel("execution.hint", contains: "Titel oder Beschreibung der Karte wurden geändert")
        XCTAssertTrue(element("execution.continue").waitForExistence(timeout: 10), "continue offered")
        try await pictures("pause-2-angehalten", showing: "execution.continue")

        tap("execution.continue")
        try await expectPipeline(card.id, "running again") { self.execution($0)["state"] as? String == "running" }
        expectLabel("execution.state", contains: "Läuft")
        expectLabel("execution.feedback", contains: "Ausführung fortgesetzt.")
        expectGone("execution.continue")
        try await pictures("pause-3-fortgesetzt", showing: "execution.feedback")
    }

    /// The device was revoked after the card opened: the start is refused, the message says why, the start goes away.
    func testRefusedStartShowsTheErrorAndTheStartGoes() async throws {
        let runner = try await pairRunner("Fehler")
        let card = try await createCard("Ausführung Fehler", in: runner.projectID)
        launch()
        openCard(card.title, waitFor: "execution.start")
        try await pictures("fehler-1-start", showing: "execution.start")
        try await request("DELETE", "/v1/agents/devices/\(runner.deviceID)")
        tap("execution.start")
        expectLabel("execution.feedback", contains: "Gerätefreigabe wurde nicht gefunden")
        expectGone("execution.start")
        let p = try await pipeline(card.id)
        XCTAssertNil(p["execution"], "nothing was started")
        try await pictures("fehler-2-abgelehnt", showing: "execution.feedback")

        // Opened again: without a binding and without an execution the card looks like before (plan and steps only).
        app.buttons["Fertig"].tap()
        openCard(card.title, waitFor: "plan.state")
        XCTAssertFalse(element("execution.start").exists, "no start without a binding")
        XCTAssertFalse(element("execution.feedback").exists, "the message belonged to the closed card")
        try await pictures("fehler-3-wieder-geoeffnet", showing: "plan.state")
    }

    /// A plain to-do (no plan): the card offers only the start; the runner plans, the person approves in the app, all steps run.
    func testPlainCardPlannerApprovalAndCompletion() async throws {
        let runner = try await pairRunner("Planung")
        let card = try await createCard("Ausführung Planung", in: runner.projectID, plan: false)
        launch()
        openCard(card.title, waitFor: "execution.start")
        XCTAssertFalse(element("pipeline.step.planner").exists, "no empty list of steps on a plain card")
        try await pictures("planung-1-nur-start", showing: "execution.start")
        tap("execution.start")
        try await expectPipeline(card.id, "planner queued") { self.execution($0)["step"] as? String == "planner" }
        expectLabel("pipeline.step.planner", contains: "Wartet auf den Runner")

        let planner = try await queuedJob(runner, step: "planner")
        let run = try await claim(runner, planner)
        try await request("POST", "/v1/runner/runs/\(run)/submit", body: [
            "generation": 1, "outcome": "passed", "plan": "# Plan vom Runner\n\n- Test zuerst",
            "result": ["summary": "geplant", "references": [String](), "checks": [String](), "limitations": [String]()]], as: runner.token)
        expectLabel("execution.state", contains: "Wartet auf Freigabe")
        expectLabel("execution.hint", contains: "Nach der Freigabe geht es automatisch weiter")
        try await pictures("planung-2-freigabe", showing: "execution.hint")

        tap("plan.approve")
        try await expectPipeline(card.id, "developer after the approval") {
            self.execution($0)["state"] as? String == "running" && self.execution($0)["step"] as? String == "developer"
        }
        expectLabel("execution.state", contains: "Läuft")
        for step in ["developer", "validation", "tester", "review"] {
            let job = try await queuedJob(runner, step: step)
            try await submit(runner, try await claim(runner, job), "passed")
        }
        expectLabel("execution.state", contains: "Abgeschlossen")
        expectLabel("execution.hint", contains: "Das Ergebnis wartet im Review")
        expectGone("execution.stop")
        XCTAssertFalse(element("execution.start").exists, "nothing left to run")
        try await pictures("planung-3-abgeschlossen", showing: "execution.hint")
    }

    /// A new plan version arrives while the card is open: the first tap only says "read first", the second one starts.
    func testNewPlanVersionNeedsASecondTap() async throws {
        let runner = try await pairRunner("Fassung")
        let card = try await createCard("Ausführung Fassung", in: runner.projectID)
        launch()
        openCard(card.title, waitFor: "execution.start")
        try await request("PUT", "/v1/tasks/\(card.id)/plan", body: ["body": "# Ziel\nZweite Fassung.", "expectedVersion": 1])
        try await request("POST", "/v1/tasks/\(card.id)/plan/decision", body: ["decision": "approve", "version": 2])
        XCTAssertTrue(app.staticTexts["Zweite Fassung."].waitForExistence(timeout: 30), "the open card shows the new version")
        tap("execution.start")
        expectLabel("execution.feedback", contains: "bitte erst lesen")
        expectLabel("execution.start", contains: "mit Version 2 starten")
        let before = try await pipeline(card.id)
        XCTAssertNil(before["execution"], "nothing was sent")
        try await pictures("fassung-1-erst-lesen", showing: "execution.feedback")
        tap("execution.start")
        try await expectPipeline(card.id, "started after the second tap") { self.execution($0)["state"] as? String == "running" }
        expectLabel("execution.feedback", contains: "Pipeline gestartet.")
    }

    /// The project switched to the classic view keeps the short to-do detail, also with a runner binding.
    func testClassicProjectKeepsThePlainDetail() async throws {
        let runner = try await pairRunner("Klassisch")
        let prefs = try await request("GET", "/v1/me/project-prefs/\(runner.projectID)")
        try await request("PATCH", "/v1/me/project-prefs/\(runner.projectID)",
                          body: ["revision": prefs["revision"] as? Int ?? 0, "mode": "classic"])
        let card = try await createCard("Ausführung Klassisch", in: runner.projectID, plan: false)
        launch()
        openCard(card.title, waitFor: "task.title")
        XCTAssertFalse(element("execution.start").waitForExistence(timeout: 8), "no pipeline card on a plain to-do")
        XCTAssertFalse(element("pipeline.step.planner").exists)
        try await pictures("klassisch", showing: "task.title")
    }

    /// "Wird gesendet …" while start or stop are on their way (button locked), gone after success and after a failure; closing the
    /// card while sending leaves nothing stuck.
    func testSendingStateOnSuccessFailureAndClose() async throws {
        guard let proxy = ProcessInfo.processInfo.environment["TODO_UITEST_DELAY_PROXY"] else {
            throw XCTSkip("TODO_UITEST_DELAY_PROXY not set (run through scripts/ui-tests.sh)")
        }
        let runner = try await pairRunner("Senden")
        let card = try await createCard("Ausführung Senden", in: runner.projectID)
        launch(through: proxy)
        openCard(card.title, waitFor: "execution.start")
        // Start fails: the sending label goes, the message says so, nothing started.
        try await control(proxy, ["exec-start": ["delay": 45, "status": 500]])
        try await pictures("senden-1-start-vorher", showing: "execution.start")
        tap("execution.start")
        try await sending("execution.start", "senden-2-start-fehler-waehrend")
        expectLabel("execution.feedback", contains: "Das hat nicht geklappt")
        expectLabel("execution.start", contains: "Pipeline starten")
        XCTAssertTrue(element("execution.start").isEnabled, "free again after the failure")
        let failed = try await pipeline(card.id)
        XCTAssertNil(failed["execution"], "nothing started")
        try await pictures("senden-3-start-fehler-nachher", showing: "execution.start")

        // Start succeeds.
        try await control(proxy, ["exec-start": ["delay": 45]])
        tap("execution.start")
        try await sending("execution.start", "senden-4-start-waehrend")
        expectLabel("execution.state", contains: "Läuft")
        expectLabel("execution.feedback", contains: "Pipeline gestartet.")
        expectGone("execution.start")
        try await pictures("senden-5-start-nachher", showing: "execution.stop")

        // Stop fails, then succeeds.
        try await control(proxy, ["exec-stop": ["delay": 45, "status": 500]])
        tap("execution.stop")
        try await sending("execution.stop", "senden-6-stopp-fehler-waehrend")
        expectLabel("execution.feedback", contains: "Das hat nicht geklappt")
        expectLabel("execution.stop", contains: "Stoppen")
        XCTAssertTrue(element("execution.stop").isEnabled)
        expectLabel("execution.state", contains: "Läuft")
        try await pictures("senden-7-stopp-fehler-nachher", showing: "execution.stop")
        try await control(proxy, ["exec-stop": ["delay": 45]])
        tap("execution.stop")
        try await sending("execution.stop", "senden-8-stopp-waehrend")
        expectLabel("execution.state", contains: "Gestoppt")
        expectGone("execution.stop")
        try await pictures("senden-9-stopp-nachher", showing: "execution.hint")

        // Closed while sending: reopened, the card shows the stored state and no leftover sending label.
        try await control(proxy, ["exec-start": ["delay": 6]])
        tap("execution.start")
        expectLabel("execution.start", contains: "Wird gesendet")
        app.buttons["Fertig"].tap()
        try await expectPipeline(card.id, "the request goes on after closing") { self.execution($0)["state"] as? String == "running" }
        openCard(card.title, waitFor: "execution.stop")
        expectLabel("execution.stop", contains: "Stoppen")
        XCTAssertTrue(element("execution.stop").isEnabled)
        XCTAssertFalse(element("execution.start").exists)
        XCTAssertFalse(element("execution.feedback").exists, "the message belonged to the closed card")
        try await control(proxy, [:])
    }

    /// The same for "Wiederholen" at a failed step and for "Fortsetzen" of a paused execution.
    func testSendingStateOfRetryAndContinue() async throws {
        guard let proxy = ProcessInfo.processInfo.environment["TODO_UITEST_DELAY_PROXY"] else {
            throw XCTSkip("TODO_UITEST_DELAY_PROXY not set (run through scripts/ui-tests.sh)")
        }
        let runner = try await pairRunner("Erneut")
        let card = try await createCard("Ausführung Erneut", in: runner.projectID)
        let bindingID = try await bindingID(runner)
        try await request("POST", "/v1/tasks/\(card.id)/pipeline/execution", body: ["id": UUID().uuidString.lowercased(), "bindingID": bindingID])
        let first = try await queuedJob(runner, step: "developer")
        try await submit(runner, try await claim(runner, first), "failed")
        try await control(proxy, [:])
        launch(through: proxy)
        openCard(card.title, waitFor: "pipeline.retry.developer")

        try await control(proxy, ["exec-retry": ["delay": 45, "status": 500]])
        try await pictures("erneut-1-wiederholen-vorher", showing: "pipeline.retry.developer")
        tap("pipeline.retry.developer")
        try await sending("pipeline.retry.developer", "erneut-2-wiederholen-fehler-waehrend")
        expectLabel("execution.feedback", contains: "Das hat nicht geklappt")
        XCTAssertTrue(element("execution.feedback").isHittable, "the message is in view, next to the retried step")
        XCTAssertGreaterThan(element("execution.feedback").frame.minY, element("pipeline.retry.developer").frame.minY)
        XCTAssertTrue(element("pipeline.retry.developer").isEnabled, "free again after the failure")
        try await pictures("erneut-3-wiederholen-fehler-nachher", showing: "pipeline.retry.developer")
        try await control(proxy, ["exec-retry": ["delay": 45]])
        tap("pipeline.retry.developer")
        try await sending("pipeline.retry.developer", "erneut-4-wiederholen-waehrend")
        expectLabel("execution.feedback", contains: "wiederholt: der Schritt läuft erneut")
        expectGone("pipeline.retry.developer")
        try await pictures("erneut-5-wiederholen-nachher", showing: "execution.feedback")

        // Paused by a card change before the claim of the repeated step.
        let job = try await queuedJob(runner, step: "developer")
        let task = try await request("GET", "/v1/planning/tasks/\(card.id)")["task"] as? [String: Any] ?? [:]
        try await request("PATCH", "/v1/tasks/\(card.id)", body: ["description": "Neu: auch iPad", "version": task["version"] as? Int ?? 1])
        try await request("POST", "/v1/runner/jobs/\(job)/claim?pipeline=1", as: runner.token, expect: 200...499)
        XCTAssertTrue(element("execution.continue").waitForExistence(timeout: 30), "continue offered")
        try await control(proxy, ["exec-continue": ["delay": 45, "status": 500]])
        try await pictures("erneut-6-fortsetzen-vorher", showing: "execution.continue")
        tap("execution.continue")
        try await sending("execution.continue", "erneut-7-fortsetzen-fehler-waehrend")
        expectLabel("execution.feedback", contains: "Das hat nicht geklappt")
        XCTAssertTrue(element("execution.continue").isEnabled)
        expectLabel("execution.state", contains: "Angehalten")
        try await pictures("erneut-8-fortsetzen-fehler-nachher", showing: "execution.continue")
        try await control(proxy, ["exec-continue": ["delay": 45]])
        tap("execution.continue")
        try await sending("execution.continue", "erneut-9-fortsetzen-waehrend")
        expectLabel("execution.state", contains: "Läuft")
        expectLabel("execution.feedback", contains: "Ausführung fortgesetzt.")
        expectGone("execution.continue")
        try await pictures("erneut-a-fortsetzen-nachher", showing: "execution.feedback")
        try await control(proxy, [:])
    }

    /// Replaces the proxy's rules (delay or forced status per request kind).
    private func control(_ proxy: String, _ rules: [String: Any]) async throws {
        var r = URLRequest(url: URL(string: proxy + "/__control")!)
        r.httpMethod = "POST"; r.httpBody = try JSONSerialization.data(withJSONObject: rules)
        _ = try await URLSession.shared.data(for: r)
    }

    /// The sending state of `id`: label, locked, pictures in both looks that still show it, then waits until the answer is there.
    private func sending(_ id: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        expectLabel(id, contains: "Wird gesendet", file: file, line: line)
        XCTAssertFalse(element(id).isEnabled, "\(id) is locked while sending", file: file, line: line)
        try await pictures(name, showing: id)
        XCTAssertTrue(element(id).exists && element(id).label.contains("Wird gesendet"), "still sending after both pictures", file: file, line: line)
        let answered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR NOT (label CONTAINS 'Wird gesendet')"),
                                                 object: element(id))
        XCTAssertEqual(XCTWaiter.wait(for: [answered], timeout: 60), .completed, "\(id) is answered", file: file, line: line)
    }

    private func bindingID(_ runner: Runner) async throws -> String {
        let devices = try await request("GET", "/v1/agents/devices")["items"] as? [[String: Any]] ?? []
        let bindings = devices.first { $0["id"] as? String == runner.deviceID }?["bindings"] as? [[String: Any]] ?? []
        return try XCTUnwrap(bindings.first?["id"] as? String, "binding")
    }
}
