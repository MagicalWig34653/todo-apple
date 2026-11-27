import XCTest

/// Where a tap on each push kind lands (card D97C4918), iPhone and iPad. No real push is sent: the debug build calls the
/// real `NotificationDelegate` with a response built from the backend's payload format (`TODO_DEBUG_DELIVER_RESPONSE`).
/// Every kind is tapped once during launch ("cold", light) and once with the app already up ("warm", dark). Needs
/// `TODO_UITEST_SERVER`, `TODO_UITEST_TOKEN` and the demo seed; `action_request` also needs pending confirmations
/// (`TODO_UITEST_CONFIRMATIONS=1` for `scripts/ui-tests.sh`). Optional: `TODO_TOUR_OUT` (directory for the screenshots),
/// `TODO_UITEST_DELAY_PROXY` for the project the app has not synced yet.
final class PushDeepLinkUITests: XCTestCase {
    private struct Target { let taskID: String, taskTitle: String, projectID: String, projectName: String }

    private enum Kind: String, CaseIterable {
        case reminder, question, review, comment
        case actionRequest = "action_request"
        case dailyBrief = "daily_brief"

        var category: String {
            switch self {
            case .actionRequest: "TODO_CONFIRMATION"
            case .dailyBrief: "TODO_DAILY_BRIEF"
            default: "TODO_\(rawValue.uppercased())"
            }
        }
    }

    private static let largeText = "UICTContentSizeCategoryAccessibilityXL"
    private var server = "", token = "", out: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"] else {
            throw XCTSkip("TODO_UITEST_SERVER / TODO_UITEST_TOKEN not set")
        }
        self.server = server; self.token = token; out = env["TODO_TOUR_OUT"]
    }

    // MARK: Tests

    func testReminderOpensTheTaskInItsProject() throws { try coldAndWarm(.reminder) }
    func testCommentOpensTheTaskInItsProject() throws { try coldAndWarm(.comment) }
    func testQuestionOpensTheProjectCommandCenterWithTheTask() throws { try coldAndWarm(.question) }
    func testReviewOpensTheProjectCommandCenterWithTheTask() throws { try coldAndWarm(.review) }
    func testDailyBriefOpensTheCommandCenterWithoutATask() throws { try coldAndWarm(.dailyBrief) }
    func testActionRequestOpensForYouWithTheRequestCard() throws { try coldAndWarm(.actionRequest) }

    /// Largest accessibility sizes: the iPad shows the detail as a sheet, the destination stays the same.
    func testLargeTextReachesTheSameDestinations() throws {
        let target = try seededTarget()
        for (kind, dark) in [(Kind.reminder, false), (Kind.reminder, true), (Kind.question, false), (Kind.question, true)] {
            let app = launch(payload(kind, target), delay: 0, dark: dark, large: true)
            assertDestination(app, kind, target, shot: "gross-\(kind.rawValue)-\(look(dark))")
            app.terminate()
        }
    }

    /// A push about a project the app has not synced yet (created by an agent a moment ago, live refresh not through):
    /// the app fetches it and lands there instead of on the account-wide fallback.
    func testPushForAProjectNotSyncedYetStillOpensIt() throws {
        guard let proxy = ProcessInfo.processInfo.environment["TODO_UITEST_DELAY_PROXY"] else {
            throw XCTSkip("TODO_UITEST_DELAY_PROXY not set (run through scripts/ui-tests.sh)")
        }
        try control(proxy, ["live": ["status": 500], "live-head": ["status": 500]])
        addTeardownBlock { [self] in try control(proxy, [:]) }
        let file = NSTemporaryDirectory() + "push-\(UUID().uuidString).json"
        let app = launch("@" + file, delay: 14, dark: false, server: proxy, select: "search")
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 30), "app up")
        Thread.sleep(forTimeInterval: 4)   // the first sync is through, the next one is 30 s away
        let name = "Neu vom Agenten \(UUID().uuidString.prefix(4))"
        let projectID = try XCTUnwrap(post("/v1/projects", ["name": name])["id"] as? String)
        let task = try post("/v1/tasks", ["projectID": projectID, "title": "Frisch angelegte Aufgabe"])
        let target = Target(taskID: try XCTUnwrap(task["id"] as? String), taskTitle: "Frisch angelegte Aufgabe",
                            projectID: projectID, projectName: name)
        try payload(.question, target).write(toFile: file, atomically: true, encoding: .utf8)
        assertDestination(app, .question, target, shot: nil)
    }

    /// "Erledigen" on a reminder with the app running: the real delegate completes the task, the server has it as done.
    func testDoneActionOfAReminderCompletesTheTaskOnTheServer() throws {
        let seeded = try seededTarget()
        let title = "Per Mitteilung erledigen \(UUID().uuidString.prefix(4))"
        let created = try post("/v1/tasks", ["projectID": seeded.projectID, "title": title])
        let id = try XCTUnwrap(created["id"] as? String)
        let target = Target(taskID: id, taskTitle: title, projectID: seeded.projectID, projectName: seeded.projectName)
        let app = launch(payload(.reminder, target), delay: 10, dark: false, select: "search", action: "TODO_DONE")
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 30), "app up")
        let probe = app.otherElements["debug.pushProbe"]
        expectation(for: NSPredicate(format: "label CONTAINS 'didReceive'"), evaluatedWith: probe)
        waitForExpectations(timeout: 25)
        var status = ""
        for _ in 0..<30 where status != "done" {
            let tasks = try XCTUnwrap(get("/v1/tasks") as? [[String: Any]])
            status = tasks.first { ($0["id"] as? String) == id }?["status"] as? String ?? ""
            if status != "done" { Thread.sleep(forTimeInterval: 1) }
        }
        XCTAssertEqual(status, "done", "server state after \"Erledigen\"")
        XCTAssertFalse(app.textFields["task.title"].exists, "\"Erledigen\" does not open the task")
    }

    // MARK: Flow

    private func coldAndWarm(_ kind: Kind) throws {
        let target = try seededTarget()
        let request = kind == .actionRequest ? try pendingConfirmation() : nil
        // Cold: the response arrives while the app is still signing in and loading.
        var app = launch(payload(kind, target, subject: request?.id), delay: 0, dark: false)
        assertDestination(app, kind, target, summary: request?.summary, shot: "kalt-\(kind.rawValue)-hell")
        app.terminate()
        // Warm: the app is up on another screen ("Suche") when the tap arrives.
        app = launch(payload(kind, target, subject: request?.id), delay: 10, dark: true, select: "search")
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 30), "on the search screen before the tap")
        XCTAssertFalse(app.textFields["task.title"].exists, "no task open before the tap")
        assertDestination(app, kind, target, summary: request?.summary, shot: "warm-\(kind.rawValue)-dunkel")
        app.terminate()
    }

    private func assertDestination(_ app: XCUIApplication, _ kind: Kind, _ target: Target, summary: String? = nil, shot name: String?,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let probe = app.otherElements["debug.pushProbe"]
        let delivered = NSPredicate(format: "label CONTAINS 'didReceive'")
        switch kind {
        case .reminder, .comment, .question, .review:
            // The task is on top (sheet on iPhone, column on iPad) and shows its real title.
            let title = app.descendants(matching: .any).matching(identifier: "task.title").firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 45), "\(kind): task detail open", file: file, line: line)
            wait(title, NSPredicate(format: "value == %@", target.taskTitle), "\(kind): title of the pushed task", file: file, line: line)
            settleAndShoot(name)
            if app.launchArguments.contains(Self.largeText) {
                let created = app.descendants(matching: .any).matching(identifier: "audit.created").firstMatch
                let updated = app.descendants(matching: .any).matching(identifier: "audit.updated").firstMatch
                XCTAssertTrue(created.waitForExistence(timeout: 10) && updated.exists, "\(kind): timestamps", file: file, line: line)
                let screen = app.windows.firstMatch.frame
                if !isPad {
                    // "zuletzt geändert vor 3 Min." does not fit one line on an iPhone at this size: it has to wrap
                    // instead of ending in "geä…" (the combined accessibility label keeps the full text either way).
                    XCTAssertGreaterThan(updated.frame.height, created.frame.height * 1.5,
                                         "\(kind): 'zuletzt geändert' wraps instead of being cut off (\(updated.frame) vs \(created.frame))",
                                         file: file, line: line)
                }
                for (name, element) in [("created", created), ("updated", updated)] {
                    XCTAssertGreaterThanOrEqual(element.frame.minX, screen.minX, "\(kind): \(name) not cut off on the left", file: file, line: line)
                    XCTAssertLessThanOrEqual(element.frame.maxX, screen.maxX + 1, "\(kind): \(name) not cut off on the right", file: file, line: line)
                    XCTAssertLessThanOrEqual(element.frame.maxY, screen.maxY, "\(kind): \(name) on screen", file: file, line: line)
                }
                XCTAssertGreaterThanOrEqual(updated.frame.minY, created.frame.maxY - 1,
                                            "\(kind): at accessibility sizes the two timestamps stand one below the other, not squeezed side by side",
                                            file: file, line: line)
            }
            // iPhone and large text: close the sheet to see what lies underneath. iPad column: both are visible.
            if !isPad || app.launchArguments.contains(Self.largeText) {
                app.buttons["Fertig"].firstMatch.tap()
                XCTAssertTrue(title.waitForNonExistence(timeout: 10), "\(kind): detail closed", file: file, line: line)
            }
            if kind == .reminder || kind == .comment {
                let header = app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", target.projectName)).firstMatch
                XCTAssertTrue(header.waitForExistence(timeout: 15), "\(kind): project page of \(target.projectName)", file: file, line: line)
                XCTAssertFalse(app.buttons["cc.scope.project"].exists, "\(kind): not the command center", file: file, line: line)
            } else {
                let scope = app.buttons["cc.scope.project"]
                XCTAssertTrue(scope.waitForExistence(timeout: 15), "\(kind): command center of the project", file: file, line: line)
                XCTAssertTrue(scope.label.contains(target.projectName), "\(kind): scope is \(scope.label)", file: file, line: line)
            }
            if !isPad || app.launchArguments.contains(Self.largeText) { settleAndShoot(name.map { $0 + "-ziel" }) }
        case .dailyBrief:
            let scope = app.staticTexts["cc.scope.account"]
            XCTAssertTrue(scope.waitForExistence(timeout: 45), "account-wide command center", file: file, line: line)
            expectation(for: delivered, evaluatedWith: probe)
            waitForExpectations(timeout: 15)
            XCTAssertFalse(app.textFields["task.title"].exists, "no task opened", file: file, line: line)
            settleAndShoot(name)
        case .actionRequest:
            let card = app.otherElements["confirm.card.highlighted"]
            XCTAssertTrue(card.waitForExistence(timeout: 45), "the card of the request is outlined", file: file, line: line)
            XCTAssertEqual(app.otherElements.matching(identifier: "confirm.card.highlighted").count, 1, "exactly one card", file: file, line: line)
            if let summary {
                XCTAssertTrue(card.staticTexts.matching(NSPredicate(format: "label == %@", summary)).count > 0,
                              "the outlined card is the one of the payload: \(summary)", file: file, line: line)
            }
            XCTAssertTrue(card.isHittable, "card in view", file: file, line: line)
            settleAndShoot(name)
        }
        XCTAssertEqual(app.alerts.count, 0, "\(kind): no error alert", file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
    }

    private func wait(_ element: XCUIElement, _ predicate: NSPredicate, _ message: String, file: StaticString, line: UInt) {
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 20)
        XCTAssertEqual(result, .completed, "\(message), saw \(String(describing: element.value))", file: file, line: line)
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private func look(_ dark: Bool) -> String { dark ? "dunkel" : "hell" }

    private func settleAndShoot(_ name: String?) {
        guard let out, let name else { return }
        Thread.sleep(forTimeInterval: 1.5)
        let device = isPad ? "ipad" : "iphone"
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(device)-\(name).png"))
    }

    private func launch(_ payload: String, delay: Int, dark: Bool, large: Bool = false, server override: String? = nil,
                        select: String? = nil, action: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        if let action { app.launchEnvironment["TODO_DEBUG_DELIVER_ACTION"] = action }
        app.launchEnvironment["TODO_DEBUG_SERVER"] = override ?? server
        app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        if let select { app.launchEnvironment["TODO_DEBUG_SELECT"] = select }
        app.launchEnvironment["TODO_DEBUG_DELIVER_RESPONSE"] = payload
        app.launchEnvironment["TODO_DEBUG_DELIVER_DELAY"] = "\(delay)"
        app.launchEnvironment["TODO_DEBUG_DELIVER_ONLY"] = "didReceive"
        app.launchArguments += ["-push.primerDismissed", "YES", "-appearance.colorScheme", dark ? "dark" : "light"]
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", large ? Self.largeText : "UICTContentSizeCategoryL"]
        app.launch()
        return app
    }

    /// Same shape and key order as `PushMessage.payload()` in the backend (sorted keys, uppercase UUIDs).
    private func payload(_ kind: Kind, _ target: Target, subject: String? = nil) -> String {
        let aps = "\"aps\":{\"alert\":{\"body\":\"Etwas wartet.\",\"title\":\"Todolino\"},\"badge\":1,\"category\":\"\(kind.category)\",\"mutable-content\":1,\"sound\":\"default\""
        let id = (subject ?? UUID().uuidString).uppercased()
        switch kind {
        case .dailyBrief: return "{\(aps)},\"kind\":\"daily_brief\"}"
        case .actionRequest: return "{\(aps)},\"kind\":\"action_request\",\"subjectID\":\"\(id)\"}"
        default:
            let subjectPart = kind == .reminder ? "" : ",\"subjectID\":\"\(id)\""
            return "{\(aps),\"thread-id\":\"\(target.projectID.uppercased())\"},\"kind\":\"\(kind.rawValue)\",\"projectID\":\"\(target.projectID.uppercased())\"\(subjectPart),\"taskID\":\"\(target.taskID.uppercased())\"}"
        }
    }

    // MARK: Backend (from the test process, with the session token)

    private func seededTarget() throws -> Target {
        let projects = try XCTUnwrap(get("/v1/projects") as? [[String: Any]], "GET /v1/projects")
        let project = try XCTUnwrap(projects.first { ($0["name"] as? String) == "Website-Relaunch" }, "demo seed")
        let projectID = try XCTUnwrap(project["id"] as? String)
        let tasks = try XCTUnwrap(get("/v1/tasks") as? [[String: Any]], "GET /v1/tasks")
        let task = try XCTUnwrap(tasks.first {
            ($0["projectID"] as? String) == projectID && ($0["title"] as? String) == "Design-Review vorbereiten"
        }, "demo seed task")
        return Target(taskID: try XCTUnwrap(task["id"] as? String), taskTitle: "Design-Review vorbereiten",
                      projectID: projectID, projectName: "Website-Relaunch")
    }

    private func pendingConfirmation() throws -> (id: String, summary: String) {
        let feed = try XCTUnwrap(get("/v1/feed") as? [String: Any], "GET /v1/feed")
        let last = (feed["confirmations"] as? [[String: Any]])?.last
        try XCTSkipIf(last == nil, "needs a pending confirmation request (TODO_UITEST_CONFIRMATIONS=1)")
        return (try XCTUnwrap(last?["id"] as? String), try XCTUnwrap(last?["summary"] as? String))
    }

    private func get(_ path: String) throws -> Any { try send(URLRequest(url: URL(string: server + path)!)) }

    private func post(_ path: String, _ body: [String: Any]) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: server + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try XCTUnwrap(send(request) as? [String: Any], path)
    }

    private func control(_ proxy: String, _ rules: [String: Any]) throws {
        var request = URLRequest(url: URL(string: proxy + "/__control")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: rules)
        _ = try send(request)
    }

    private func send(_ original: URLRequest) throws -> Any {
        var request = original
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        let done = expectation(description: request.url!.path)
        URLSession.shared.dataTask(with: request) { data, _, _ in box.data = data; done.fulfill() }.resume()
        wait(for: [done], timeout: 15)
        return try XCTUnwrap(box.data.flatMap { try? JSONSerialization.jsonObject(with: $0) }, "answer of \(request.url!.path)")
    }
}
