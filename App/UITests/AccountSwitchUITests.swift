import XCTest

/// End to end (card 346B7A6F): the real app, the real login screen and two real local backends. Anna's session expires
/// while one of her tasks is open with an unsent message, Bert signs in; Anna comes back, allows push, changes a favorite
/// whose answer is still on its way while she signs out, Bert signs in; then another server and a third account. After
/// every switch nothing of the account before may be visible, sent or received. Runs through
/// `scripts/ui-tests-accounts.sh` (needs `TODO_ACCOUNTS_*`; skipped otherwise). Only Apple's push token is replaced.
final class AccountSwitchUITests: XCTestCase {
    private struct Account: Decodable { let username: String; let password: String; let token: String }

    private var serverA = "", backendA = "", serverB = "", out: String?, look = "hell"
    private var accounts: [String: Account] = [:]
    private var app: XCUIApplication!
    private let apnsToken = String(repeating: "cd34", count: 16)
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let a = env["TODO_ACCOUNTS_PROXY"], let direct = env["TODO_ACCOUNTS_BACKEND"], let b = env["TODO_ACCOUNTS_SECOND"],
              let json = env["TODO_ACCOUNTS_JSON"]?.data(using: .utf8)
        else { throw XCTSkip("TODO_ACCOUNTS_* not set (run through scripts/ui-tests-accounts.sh)") }
        serverA = a; backendA = direct; serverB = b; out = env["TODO_TOUR_OUT"]; look = env["TODO_PROOF_LOOK"] ?? "hell"
        accounts = try JSONDecoder().decode([String: Account].self, from: json)
        XCUIDevice.shared.appearance = look == "dunkel" ? .dark : .light
    }

    override func tearDown() {
        if !serverA.isEmpty { try? control([:]) }
        XCUIDevice.shared.appearance = .light
    }

    func testTwoAccountsAndAServerSwitchLeaveNothingBehind() throws {
        let anna = try XCTUnwrap(accounts["anna"]), bert = try XCTUnwrap(accounts["bert"])
        app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_APNS_TOKEN"] = apnsToken
        app.launchArguments += ["-serverBaseURL", serverA, "-push.primerDismissed", "YES"]
        app.launch()

        // 1 Anna: her task open, a message typed but not sent, then her session is ended from outside.
        signIn("anna")
        assertPlanBadge(3)
        openTab("Projekte")
        XCTAssertTrue(text("Annas Garten").waitForExistence(timeout: 30))
        openTab("Planen")
        let task = text("Annas Rosen schneiden")
        if !task.waitForExistence(timeout: 60) { shot("fehler-planen"); XCTFail("task missing on Planen") }
        task.tap()
        // The identifier also sits on the drawn placeholder; the field itself is the editable element.
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND (elementType == %d OR elementType == %d)",
            "chat.field.task", XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue)).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("Annas geheimer Entwurf")
        shot("1-anna-aufgabe-mit-entwurf")
        try api("POST", "v1/me/sessions/revoke-others", as: anna)
        XCTAssertTrue(loginScreen.waitForExistence(timeout: 90), "the ended session signs the app out")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Sitzung ist abgelaufen")).firstMatch.waitForExistence(timeout: 10))
        shot("2-sitzung-abgelaufen")

        // 2 Bert on the same device: no open task, no draft, only his data.
        signIn("bert")
        XCTAssertFalse(field.waitForExistence(timeout: 5), "Anna's task opened again for Bert")
        XCTAssertFalse(app.alerts.firstMatch.exists, "message about Anna's task for Bert: \(app.alerts.staticTexts.firstMatch.exists ? app.alerts.staticTexts.firstMatch.label : "")")
        assertPlanBadge(1)
        assertNothing(of: "Anna", present: "Berts Werkstatt", pictures: "3-bert")
        signOut()

        // 3 Anna with push; she changes a favorite, the answer is still on its way while she signs out and Bert signs in.
        signIn("anna")
        openAccount()
        let enable = app.buttons["push.enable"]
        if reveal(enable) {
            enable.tap()
            let alert = springboard.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 20), "system permission prompt")
            alert.buttons.element(boundBy: 1).tap()
        }
        XCTAssertTrue(waitFor { (try? self.devices(anna).count) == 1 }, "Anna's device registered")
        openTab("Projekte")
        let project = text("Annas Garten")
        XCTAssertTrue(project.waitForExistence(timeout: 60))
        try control(["favorite": ["hold": true]])
        project.press(forDuration: 1.2)
        let favorite = app.buttons["Zu Favoriten"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 40))
        favorite.tap()
        signOut()
        // Anna's request has been held on its way; the session is gone on the server now, so it is answered with 401 and
        // reaches the app after the sign-out (while Bert signs in).
        XCTAssertEqual(try log("push-revoke").last?["status"] as? Int, 204, "Anna's device revoked on sign-out")
        try control([:])
        shot("4-nach-abmelden")
        signIn("bert")
        XCTAssertTrue(waitFor { (try? self.devices(bert).count) == 1 }, "the device now belongs to Bert")
        XCTAssertTrue(waitFor(80) { (try? self.log("favorite").first?["status"] as? Int) == 401 }, "late 401 of Anna: \(String(describing: try? log("favorite")))")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(loginScreen.exists, "Anna's late 401 signed Bert out")
        XCTAssertEqual(app.alerts.count, 0, "no message about Anna's request")
        assertPlanBadge(1)
        assertNothing(of: "Anna", present: "Berts Werkstatt", pictures: "5-bert-nach-spaeter-antwort")
        signOut()

        // 4 Another server, third account.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Server")).firstMatch.tap()
        let url = app.textFields.firstMatch
        XCTAssertTrue(url.waitForExistence(timeout: 10))
        url.tap()
        url.press(forDuration: 1.0)
        let all = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Alles auswählen", "Select All"])).firstMatch
        if all.waitForExistence(timeout: 5) { all.tap() }
        url.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60) + serverB)
        XCTAssertEqual(url.value as? String, serverB)
        app.buttons["Verbindung prüfen"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Verbunden")).firstMatch.waitForExistence(timeout: 20))
        app.buttons["Schließen"].tap()
        signIn("carla")
        assertPlanBadge(2)
        assertNothing(of: "Anna", present: "Carlas Kueche", pictures: "6-carla-server-b")
        assertNothing(of: "Bert", present: "Carlas Kueche", pictures: nil)
        XCTAssertEqual(try log("push-revoke").last?["status"] as? Int, 204, "Bert's device revoked on server A when he signed out")
    }

    // MARK: Steps

    private var loginScreen: XCUIElement { app.buttons["Mit Passwort anmelden"] }

    private func signIn(_ name: String) {
        XCTAssertTrue(loginScreen.waitForExistence(timeout: 30), "login screen before signing in \(name)")
        let open = loginScreen
        XCTAssertTrue(waitFor { open.isHittable })
        open.tap()
        let user = app.textFields["Benutzername"]
        XCTAssertTrue(user.waitForExistence(timeout: 15))
        user.tap(); user.typeText(name)
        let password = app.secureTextFields["Passwort"]
        password.tap(); password.typeText(accounts[name]!.password)
        app.buttons["Anmelden"].firstMatch.tap()
        // The simulator may offer to save the password.
        let later = app.buttons.matching(NSPredicate(format: "label IN %@", ["Not Now", "Nicht jetzt", "Jetzt nicht"])).firstMatch
        if later.waitForExistence(timeout: 4) { later.tap() }
        XCTAssertTrue(app.tabBars.buttons["Projekte"].waitForExistence(timeout: 30), "\(name) signed in")
    }

    private func openTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 15), name)
        tab.tap()
    }

    /// Right after a sign-in the toolbar may still settle and swallow the first tap on the avatar; try again.
    private func menuEntry(_ name: String) -> XCUIElement {
        openTab("Für dich")
        let entry = app.buttons[name], avatar = app.buttons["accountMenu"]
        // A screen pushed onto the tab (settings) hides the avatar: the second tap on the tab goes back to its root.
        if !avatar.waitForExistence(timeout: 5) { app.tabBars.buttons["Für dich"].tap() }
        for _ in 0..<3 {
            if !avatar.waitForExistence(timeout: 60) {
                shot("fehler-kein-avatar")
                XCTFail("no avatar; buttons: \(app.buttons.allElementsBoundByIndex.map(\.label)); alerts: \(app.alerts.count)")
            }
            avatar.tap()
            if entry.waitForExistence(timeout: 15) { break }
        }
        if !entry.exists { shot("fehler-menue-\(name)"); XCTFail("menu entry \(name); buttons: \(app.buttons.allElementsBoundByIndex.map(\.label))") }
        return entry
    }

    private func openAccount() { menuEntry("Einstellungen").tap() }

    private func signOut() {
        menuEntry("Abmelden").tap()
        XCTAssertTrue(loginScreen.waitForExistence(timeout: 40), "signed out")
    }

    private func text(_ value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    /// The counter on "Planen" (tasks due today) comes from the signed-in account.
    private func assertPlanBadge(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let tab = app.tabBars.buttons["Planen"]
        XCTAssertTrue(waitFor(40) { (tab.value as? String)?.hasPrefix("\(count) ") == true || tab.value as? String == "\(count)" },
                      "badge \(count), saw \(tab.value ?? "none")", file: file, line: line)
    }

    /// Walks through the tabs: no text of `owner` anywhere, the current account's project is there.
    private func assertNothing(of owner: String, present: String, pictures: String?, file: StaticString = #filePath, line: UInt = #line) {
        let foreign = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", owner, owner))
        for tab in ["Für dich", "Jetzt", "Projekte", "Planen", "Suche"] {
            openTab(tab)
            if tab == "Projekte" { XCTAssertTrue(text(present).waitForExistence(timeout: 30), present, file: file, line: line) }
            Thread.sleep(forTimeInterval: 2)
            if let pictures { shot("\(pictures)-\(tab)") }
            XCTAssertEqual(foreign.count, 0, "\(owner) visible on \(tab): \(foreign.firstMatch.exists ? foreign.firstMatch.label : "")", file: file, line: line)
        }
    }

    private func reveal(_ element: XCUIElement) -> Bool {
        _ = element.waitForExistence(timeout: 5)
        for _ in 0..<12 {
            if element.exists, element.isHittable, element.frame.maxY < app.windows.firstMatch.frame.height * 0.88 { return true }
            app.swipeUp(velocity: .slow)
        }
        return element.exists && element.isHittable
    }

    private func waitFor(_ timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat { if condition() { return true }; Thread.sleep(forTimeInterval: 0.5) } while Date() < end
        return condition()
    }

    private func shot(_ name: String) {
        guard let out else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(name)-\(look).png"))
    }

    // MARK: Server side

    @discardableResult
    private func request(_ method: String, _ url: String, token: String? = nil, body: Data? = nil) throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        if method != "GET" { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = body ?? Data("{}".utf8) }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<Data, any Error> = .failure(URLError(.timedOut))
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) { result = .success(data ?? Data()) }
            else { result = .failure(error ?? URLError(.badServerResponse)) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        return try result.get()
    }

    @discardableResult
    private func api(_ method: String, _ path: String, as account: Account) throws -> Data {
        try request(method, "\(backendA)/\(path)", token: account.token)
    }

    private func devices(_ account: Account) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: api("GET", "v1/push/devices", as: account)) as? [[String: Any]])
    }

    private func control(_ rules: [String: Any]) throws {
        try request("POST", "\(serverA)/__control", body: JSONSerialization.data(withJSONObject: rules))
    }

    private func log(_ rule: String) throws -> [[String: Any]] {
        let all = try XCTUnwrap(JSONSerialization.jsonObject(with: request("GET", "\(serverA)/__log")) as? [[String: Any]])
        return all.filter { $0["rule"] as? String == rule }
    }
}
