import XCTest

/// Registration, permission and settings of push (card D97C4918), real app against the local backend. Only Apple's part is
/// replaced: `TODO_DEBUG_APNS_TOKEN` hands the app a token through the real application delegate callback. The app talks to
/// the backend through `scripts/selection-proxy.py`, whose log shows what was really sent. Needs `TODO_UITEST_SERVER`,
/// `TODO_UITEST_TOKEN`, `TODO_UITEST_DELAY_PROXY` (all set by `scripts/ui-tests.sh`). The permission is per installation,
/// so the numbered order matters; `TODO_UITEST_PERMISSION=deny` answers the system prompt with "no" (default: allow).
/// Optional `TODO_TOUR_OUT` writes screenshots.
final class PushAccountUITests: XCTestCase {
    private var server = "", token = "", proxy = "", out: String?
    private let apnsToken = String(repeating: "ab12", count: 16)

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"], let proxy = env["TODO_UITEST_DELAY_PROXY"] else {
            throw XCTSkip("TODO_UITEST_SERVER / _TOKEN / _DELAY_PROXY not set (run through scripts/ui-tests.sh)")
        }
        self.server = server; self.token = token; self.proxy = proxy; out = env["TODO_TOUR_OUT"]
        try control([:])
    }

    override func tearDown() {
        if !proxy.isEmpty { try? control([:]) }
    }

    private var deny: Bool { ProcessInfo.processInfo.environment["TODO_UITEST_PERMISSION"] == "deny" }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    // MARK: 1 Explainer card

    /// The first start asks nothing. The explainer card in the command center comes once; "Nicht jetzt" is remembered.
    func test1PrimerCardAsksOnlyOnRequestAndStaysDismissed() throws {
        var app = launch(select: "commandcenter", extra: ["-push.primerDismissed", "NO"])
        let later = app.buttons["push.primer.later"]
        if !later.waitForExistence(timeout: 30) {
            // Only an installation whose permission is already decided may be without the card.
            app.terminate()
            app = launch(select: "account")
            try XCTSkipUnless(app.buttons["push.enable"].waitForExistence(timeout: 20), "permission already decided on this installation")
            XCTFail("permission undecided, open questions in the seed, but no explainer card")
        }
        XCTAssertEqual(springboard.alerts.count, 0, "no system prompt on its own")
        XCTAssertEqual(try log("push-register").count, 0, "nothing registered without permission")
        shot("primer-hell")
        app.terminate()
        app = launch(select: "commandcenter", dark: true, extra: ["-push.primerDismissed", "NO"])
        XCTAssertTrue(app.buttons["push.primer.later"].waitForExistence(timeout: 30))
        shot("primer-dunkel")
        app.buttons["push.primer.later"].tap()
        XCTAssertTrue(app.buttons["push.primer.later"].waitForNonExistence(timeout: 10))
        app.terminate()
        // Without the launch argument the stored choice counts.
        app = launch(select: "commandcenter")
        XCTAssertTrue(app.staticTexts["cc.scope.account"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["push.primer.later"].waitForExistence(timeout: 8), "card stays away after \"Nicht jetzt\"")
        XCTAssertEqual(springboard.alerts.count, 0)
    }

    // MARK: 2 Older server

    /// A server without push endpoints (404): no push controls, no registration.
    func test2OlderServerHidesPushControls() throws {
        try control(["push-prefs-get": ["status": 404]])
        let app = launch(select: "account")
        XCTAssertTrue(reveal(app, app.buttons["Abmelden"]), "account screen")
        XCTAssertTrue(waitForLog("push-prefs-get", count: 1), "the app asked the server")
        XCTAssertFalse(app.descendants(matching: .any)["push.status"].exists)
        XCTAssertFalse(app.buttons["push.enable"].exists)
        XCTAssertFalse(app.switches["push.cat.reminders"].exists)
        XCTAssertEqual(try log("push-register").count, 0)
        shot("alter-server-hell")
    }

    // MARK: 3 Permission and registration

    func test3PermissionRegistrationAndSignOut() throws {
        let before = Set(try devices().compactMap { $0["id"] as? String })
        var app = launch(select: "account")
        let enable = app.buttons["push.enable"]
        let asked = !enable.waitForExistence(timeout: 20) && !reveal(app, enable)
        if !asked {
            XCTAssertEqual(springboard.alerts.count, 0, "no system prompt before the person asks for it")
            XCTAssertEqual(try log("push-register").count, 0, "no registration without permission")
            assertStatus(app, "Noch nicht aktiviert")
            shot("berechtigung-1-vorher-hell")
            enable.tap()
            let alert = springboard.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 20), "system permission prompt after the tap")
            shot("berechtigung-2-systemdialog-hell")
            let buttons = alert.buttons
            XCTAssertEqual(buttons.count, 2)
            // Order of the system prompt: "don't allow" first, "allow" second (independent of the language).
            buttons.element(boundBy: deny ? 0 : 1).tap()
        } else {
            try XCTSkipIf(deny, "permission already decided on this installation")
        }
        if deny {
            assertStatus(app, "Nicht erlaubt")
            XCTAssertTrue(app.buttons["push.openSettings"].waitForExistence(timeout: 10), "way into the system settings")
            XCTAssertFalse(app.buttons["push.enable"].exists)
            XCTAssertEqual(try log("push-register").count, 0, "a refusal registers nothing")
            shot("berechtigung-3-nicht-erlaubt-hell")
            app.terminate()
            app = launch(select: "account", dark: true)
            XCTAssertTrue(reveal(app, app.buttons["push.openSettings"]))
            shot("berechtigung-3-nicht-erlaubt-dunkel")
            return
        }
        assertStatus(app, "Erlaubt")
        XCTAssertTrue(waitForLog("push-register", count: 1), "device registered after the permission")
        XCTAssertTrue([200, 201].contains(try log("push-register").first?["status"] as? Int ?? 0), "server accepted the registration")
        let mine = try devices().filter { ($0["platform"] as? String) == "ios" && ($0["environment"] as? String) == "sandbox" }
        let device = try XCTUnwrap(mine.first { ($0["bundleId"] as? String) == "de.linolaske.todo" }, "server lists the device: \(mine)")
        let id = try XCTUnwrap(device["id"] as? String)
        XCTAssertTrue(!before.contains(id) || asked)
        shot("berechtigung-3-erlaubt-hell")

        // Back to the foreground: the same token is not sent again in this session.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(try log("push-register").count, 1, "once per session and token")

        // The next start registers again (token may have changed), the server keeps one device per token.
        app.terminate()
        try control([:])
        app = launch(select: "account", dark: true)
        XCTAssertTrue(waitForLog("push-register", count: 1), "registered again on the next start")
        XCTAssertEqual(try devices().filter { ($0["id"] as? String) == id }.count, 1, "same device")
        assertStatus(app, "Erlaubt")
        shot("berechtigung-3-erlaubt-dunkel")

        // Signing out revokes the device. The server session itself is kept alive (forced error on the logout request),
        // the other tests of the run use the same one.
        try control(["logout": ["status": 500]])
        let logout = app.buttons["Abmelden"]
        XCTAssertTrue(reveal(app, logout), "sign out button")
        logout.tap()
        XCTAssertTrue(waitForLog("push-revoke", count: 1), "device revoked on sign-out")
        XCTAssertEqual(try log("push-revoke").first?["status"] as? Int, 204)
        XCTAssertFalse(try devices().contains { ($0["id"] as? String) == id }, "server no longer lists it")
    }

    // MARK: 4 Settings

    /// Every switch reaches the account's preferences on the server; a failed save snaps back and says so.
    func test4SettingsSwitchesReachTheServer() throws {
        let app = launch(select: "account")
        let switches: [(String, (([String: Any]) -> Bool?))] = [
            ("push.cat.reminders", { Self.category($0, "reminders") }),
            ("push.cat.questions", { Self.category($0, "agent_questions") }),
            ("push.cat.reviews", { Self.category($0, "agent_reviews") }),
            ("push.cat.comments", { Self.category($0, "comments") }),
            ("push.cat.confirmations", { Self.category($0, "confirmations") }),
            ("push.cat.dailyBrief", { Self.category($0, "daily_brief") }),
            ("push.showContent", { $0["showContent"] as? Bool }),
            ("push.badge", { $0["badge"] as? Bool }),
        ]
        for (identifier, read) in switches {
            let toggle = app.switches[identifier]
            XCTAssertTrue(reveal(app, toggle), identifier)
            let start = try XCTUnwrap(read(try prefs()), identifier)
            XCTAssertEqual(toggle.value as? String, start ? "1" : "0", "\(identifier) shows the server value")
            flip(toggle)
            XCTAssertTrue(waitFor { (try? read(self.prefs())) == !start }, "\(identifier) saved as \(!start)")
            XCTAssertTrue(waitFor { toggle.value as? String == (start ? "0" : "1") }, "\(identifier) stays switched")
            XCTAssertTrue(reveal(app, toggle), identifier)
            flip(toggle)
            XCTAssertTrue(waitFor { (try? read(self.prefs())) == start }, "\(identifier) switched back")
        }
        XCTAssertTrue(reveal(app, app.switches["push.badge"]))
        shot("einstellungen-ende-hell")

        try control(["push-prefs-set": ["status": 500]])
        let reminders = app.switches["push.cat.reminders"]
        XCTAssertTrue(reveal(app, reminders, down: false), "reminders")
        let start = reminders.value as? String
        flip(reminders)
        XCTAssertTrue(waitForLog("push-prefs-set", count: 1))
        let error = app.descendants(matching: .any)["push.prefs.error"]
        XCTAssertTrue(reveal(app, error), "error text")
        XCTAssertTrue(waitFor { reminders.value as? String == start }, "switch snaps back")
        shot("einstellungen-fehler-hell")
    }

    // MARK: Helpers

    private func launch(select: String, dark: Bool = false, extra: [String] = ["-push.primerDismissed", "YES"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_SERVER"] = proxy
        app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        app.launchEnvironment["TODO_DEBUG_SELECT"] = select
        app.launchEnvironment["TODO_DEBUG_APNS_TOKEN"] = apnsToken
        app.launchArguments += extra + ["-appearance.colorScheme", dark ? "dark" : "light"]
        app.launch()
        return app
    }

    private func assertStatus(_ app: XCUIApplication, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let status = app.descendants(matching: .any).matching(identifier: "push.status").firstMatch
        _ = reveal(app, status, down: false)
        XCTAssertTrue(waitFor { status.label.contains(text) || (status.value as? String)?.contains(text) == true },
                      "status \(text), saw \(status.exists ? status.label : "nothing")", file: file, line: line)
    }

    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    /// Scrolls the lazy settings list until the element is on screen.
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, down: Bool = true) -> Bool {
        _ = element.waitForExistence(timeout: 3)
        let height = app.windows.firstMatch.frame.height
        for pass in 0..<2 {
            let forward = pass == 0 ? down : !down
            for _ in 0..<14 {
                if element.exists, element.isHittable, element.frame.maxY < height * 0.88, element.frame.minY > height * 0.1 { return true }
                // The list of the account screen sits right of the middle on iPad (sidebar on the left).
                let from = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: forward ? 0.7 : 0.4))
                from.press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: forward ? 0.4 : 0.7)))
            }
            // The last rows of the list cannot be scrolled any higher.
            if element.exists, element.isHittable { return true }
        }
        return element.exists && element.isHittable
    }

    private func waitFor(_ timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < end
        return false
    }

    private func waitForLog(_ rule: String, count: Int) -> Bool {
        waitFor { ((try? self.log(rule).count) ?? 0) >= count }
    }

    private func shot(_ name: String) {
        guard let out else { return }
        Thread.sleep(forTimeInterval: 1.5)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(device)-\(name).png"))
    }

    private static func category(_ prefs: [String: Any], _ key: String) -> Bool? { (prefs["categories"] as? [String: Any])?[key] as? Bool }

    private func prefs() throws -> [String: Any] { try XCTUnwrap(send(server + "/v1/me/push-prefs") as? [String: Any]) }
    private func devices() throws -> [[String: Any]] { try XCTUnwrap(send(server + "/v1/push/devices") as? [[String: Any]]) }

    private func log(_ rule: String) throws -> [[String: Any]] {
        try XCTUnwrap(send(proxy + "/__log") as? [[String: Any]]).filter { $0["rule"] as? String == rule }
    }

    /// Replaces the proxy rules and clears its log.
    private func control(_ rules: [String: Any]) throws {
        _ = try send(proxy + "/__control", body: JSONSerialization.data(withJSONObject: rules))
    }

    private func send(_ url: String, body: Data? = nil) throws -> Any {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { request.httpMethod = "POST"; request.httpBody = body }
        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in box.data = data; done.signal() }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 15), .success, url)
        return try XCTUnwrap(box.data.flatMap { try? JSONSerialization.jsonObject(with: $0) }, "answer of \(url)")
    }
}
