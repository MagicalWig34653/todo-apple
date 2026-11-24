import XCTest

/// Rename and delete labels in the app (card 9E4572D1), against the real backend: the test creates its own labels over REST,
/// drives the labels screen (swipe actions, rename sheet, confirmation dialog) and checks the server afterwards.
/// Needs `TODO_UITEST_SERVER` / `TODO_UITEST_TOKEN` like `TodoUITests` (skipped without). With `TODO_TOUR_OUT=<dir>` and
/// `TODO_TOUR_LOOK=light|dark` it also writes PNGs of the list, the rename sheet with its error and the delete dialog.
@MainActor
final class LabelManagementUITests: XCTestCase {
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

    // MARK: Server helpers

    private struct Label: Decodable { let id: String; let name: String }
    private struct LabelPage: Decodable { let items: [Label] }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        var r = URLRequest(url: URL(string: server + path)!)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertTrue((200..<300).contains(code), "\(method) \(path) -> \(code)")
        return data
    }

    private func serverLabels() async throws -> [Label] {
        try JSONDecoder().decode(LabelPage.self, from: try await request("GET", "/v1/labels?limit=100")).items
    }

    private func createLabel(_ name: String) async throws {
        _ = try await request("POST", "/v1/labels", body: ["name": name])
    }

    /// Polls the server until the label list satisfies `check` (the app sends its queued edits asynchronously).
    private func waitForServer(_ what: String, timeout: TimeInterval = 30, _ check: ([Label]) -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if check(try await serverLabels()) { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("server never showed: \(what)")
    }

    // MARK: App helpers

    private func launch(dark: Bool) {
        app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_SERVER"] = server
        app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        app.launchEnvironment["TODO_DEBUG_SELECT"] = "labels"
        app.launchEnvironment["TODO_DEBUG_NOW"] = "12:00"
        app.launchArguments += ["-AppleInterfaceStyle", dark ? "Dark" : "Light"]
        app.launch()
    }

    private func row(_ name: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch }

    /// The row's trailing swipe actions are the way in on iPhone (and a VoiceOver custom action).
    private func revealActions(of name: String) {
        let r = row(name)
        XCTAssertTrue(r.waitForExistence(timeout: 20), "row \(name)")
        r.swipeLeft()
    }

    private func clearAndType(_ field: XCUIElement, _ text: String) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)) }
        if !text.isEmpty { field.typeText(text) }
    }

    private func shot(_ name: String) {
        guard let out = ProcessInfo.processInfo.environment["TODO_TOUR_OUT"] else { return }
        Thread.sleep(forTimeInterval: 1)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }

    private var look: String { ProcessInfo.processInfo.environment["TODO_TOUR_LOOK"] ?? "light" }

    // MARK: Tests

    func testRenameRejectsInvalidNamesThenRenamesAndTheServerFollows() async throws {
        let old = "UTAlt\(stamp)", new = "UTNeu\(stamp)"
        try await createLabel(old)
        launch(dark: look == "dark")
        revealActions(of: old)
        shot("labels-\(look)-1-liste")
        app.buttons["labelRenameAction"].tap()

        let field = app.textFields["labelRenameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "rename sheet")
        XCTAssertEqual(field.value as? String, old, "the field starts with the current name")

        // Empty name: the error is visible, the sheet stays, nothing reaches the server.
        clearAndType(field, "")
        app.buttons["labelRenameSave"].tap()
        let error = app.staticTexts["labelRenameError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5), "error for the empty name")
        XCTAssertTrue(error.label.contains("leer"), error.label)
        shot("labels-\(look)-2-umbenennen-fehler")
        XCTAssertTrue(field.exists, "sheet stays open")

        // Too long (201 characters): another error text.
        clearAndType(field, String(repeating: "x", count: 201))
        app.buttons["labelRenameSave"].tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("200"), error.label)

        // Cancel leaves the label alone.
        app.buttons["labelRenameCancel"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "sheet closed by cancel")
        XCTAssertTrue(row(old).exists, "name unchanged after cancel")
        let afterCancel = try await serverLabels()
        XCTAssertFalse(afterCancel.contains { $0.name.hasPrefix("xxxx") }, "the invalid name never reached the server")

        // A valid name (with surrounding blanks) renames: the list shows it at once, the server gets the trimmed name.
        revealActions(of: old)
        app.buttons["labelRenameAction"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        clearAndType(field, "  \(new)  ")
        app.buttons["labelRenameSave"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "sheet closes on success")
        XCTAssertTrue(row(new).waitForExistence(timeout: 10), "the list shows the new name")
        XCTAssertFalse(row(old).exists, "the old name is gone from the list")
        try await waitForServer("renamed label \(new)") { labels in labels.contains { $0.name == new } && !labels.contains { $0.name == old } }
        shot("labels-\(look)-3-nach-umbenennen")
    }

    func testDeleteAsksFirstCancelKeepsTheLabelConfirmRemovesIt() async throws {
        let name = "UTWeg\(stamp)"
        try await createLabel(name)
        launch(dark: look == "dark")
        revealActions(of: name)
        app.buttons["labelDeleteAction"].tap()

        // The dialog names the label; cancelling keeps everything.
        let confirm = app.buttons["labelDeleteConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirmation dialog")
        shot("labels-\(look)-4-loeschen-dialog")
        app.buttons["labelDeleteCancel"].tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), "dialog closed")
        XCTAssertTrue(row(name).exists, "label still listed after cancel")
        let afterCancel = try await serverLabels()
        XCTAssertTrue(afterCancel.contains { $0.name == name }, "label still on the server after cancel")

        // Confirming removes it from the list and from the server.
        revealActions(of: name)
        app.buttons["labelDeleteAction"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(row(name).waitForNonExistence(timeout: 10), "label gone from the list")
        try await waitForServer("label \(name) deleted") { labels in !labels.contains { $0.name == name } }
        shot("labels-\(look)-5-nach-loeschen")
    }
}
