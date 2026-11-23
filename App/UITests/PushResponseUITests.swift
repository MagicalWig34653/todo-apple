import XCTest

/// The code path behind the TestFlight crash 2611121259, exercised WITHOUT a notification banner (the simulator shows
/// none): the debug build calls the real `NotificationDelegate` (`didReceive` and `willPresent`) from a background queue
/// with a response built from the backend's payload format (`TODO_DEBUG_DELIVER_RESPONSE`). The completion handlers
/// assert the main queue like UIKit's do (`dispatchPrecondition`), so the old `async` delegate (handler called from the
/// cooperative pool) kills the app (SIGTRAP) and the probe never reports `completed`. Needs the signed-in debug session
/// against a local backend (same variables as `TodoUITests`); the ids in the payload are a real task of that backend.
final class PushResponseUITests: XCTestCase {
    private struct RealTask { let id: String, projectID: String, title: String }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// First open task the backend returns (`GET /v1/tasks`), fetched from the test process with the session token.
    private func firstBackendTask() throws -> (server: String, token: String, task: RealTask) {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"] else {
            throw XCTSkip("TODO_UITEST_SERVER / TODO_UITEST_TOKEN not set")
        }
        var request = URLRequest(url: URL(string: server + "/v1/tasks")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var result: Data?
        let done = expectation(description: "tasks")
        URLSession.shared.dataTask(with: request) { data, _, _ in result = data; done.fulfill() }.resume()
        wait(for: [done], timeout: 15)
        let list = try XCTUnwrap(result.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }, "GET /v1/tasks")
        let first = try XCTUnwrap(list.first { ($0["status"] as? String) != "done" } ?? list.first, "backend has a task")
        return (server, token, RealTask(id: first["id"] as! String, projectID: first["projectID"] as! String,
                                        title: first["title"] as! String))
    }

    private enum Kind: String, CaseIterable {
        case reminder, question, review
        var category: String { "TODO_\(rawValue.uppercased())" }
        var title: String {
            switch self {
            case .reminder: "Erinnerung"
            case .question: "Rückfrage vom Agenten"
            case .review: "Review bereit"
            }
        }
    }

    /// Same shape and key order as `PushMessage.payload()` in the backend (sorted keys, uppercase UUIDs; `thread-id` is the
    /// project, `subjectID` the question or review the push is about).
    private func payload(_ task: RealTask, kind: Kind = .reminder) -> String {
        let subject = kind == .reminder ? "" : ",\"subjectID\":\"\(UUID().uuidString)\""
        return """
        {"aps":{"alert":{"body":"Eine Aufgabe wartet.","title":"\(kind.title)"},"badge":1,"category":"\(kind.category)",\
        "mutable-content":1,"sound":"default","thread-id":"\(task.projectID.uppercased())"},"kind":"\(kind.rawValue)",\
        "projectID":"\(task.projectID.uppercased())"\(subject),"taskID":"\(task.id.uppercased())"}
        """
    }

    private func launch(delay: Int, only: String? = nil, kind: Kind = .reminder, action: String? = nil) throws -> (XCUIApplication, RealTask) {
        let (server, token, task) = try firstBackendTask()
        let app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_SERVER"] = server
        app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        app.launchEnvironment["TODO_DEBUG_SELECT"] = "today"
        app.launchEnvironment["TODO_DEBUG_DELIVER_RESPONSE"] = payload(task, kind: kind)
        app.launchEnvironment["TODO_DEBUG_DELIVER_DELAY"] = "\(delay)"
        if let only { app.launchEnvironment["TODO_DEBUG_DELIVER_ONLY"] = only }
        if let action { app.launchEnvironment["TODO_DEBUG_DELIVER_ACTION"] = action }
        app.launch()
        return (app, task)
    }

    private func assertHandlersCompleted(_ app: XCUIApplication, expecting names: [String] = ["willPresent", "didReceive"]) {
        let probe = app.otherElements["debug.pushProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 20), "probe present (app still running)")
        let all = NSPredicate(format: names.map { "label CONTAINS '\($0)'" }.joined(separator: " AND "))
        expectation(for: all, evaluatedWith: probe)
        waitForExpectations(timeout: 20)
        // The crash came a moment after the handler call; give it time, then check the app lives and still shows its UI.
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "app still running after the delegate calls (no crash)")
        XCTAssertTrue(probe.exists && names.allSatisfy { probe.label.contains($0) }, "completion handlers ran on the main queue")
    }

    /// Delivered during launch, before the UI is up (like a launch from a notification tap).
    func testDelegateCompletionOnMainQueueColdStart() throws {
        let (app, _) = try launch(delay: 0)
        assertHandlersCompleted(app)
        XCTAssertTrue(app.buttons["quickAddButton"].waitForExistence(timeout: 20) || app.windows.firstMatch.exists)
    }

    /// Delivered while the UI is up (app running, tap on a banner).
    func testDelegateCompletionOnMainQueueWarmStart() throws {
        let (app, _) = try launch(delay: 8)
        XCTAssertTrue(app.buttons["quickAddButton"].waitForExistence(timeout: 20), "UI up before the delivery")
        assertHandlersCompleted(app)
    }

    /// Exactly the callback of the TestFlight crash (tap on a notification), on its own.
    func testDidReceiveCompletionOnMainQueue() throws {
        let (app, _) = try launch(delay: 0, only: "didReceive")
        assertHandlersCompleted(app, expecting: ["didReceive"])
    }

    // MARK: Every notification kind the backend sends (card 68AB3453: crashes "when opening a notification")

    /// Tap on a reminder, a question and a review while the app starts (cold): `didReceive` only, as for a tap.
    func testTapColdStartForEveryKind() throws {
        for kind in Kind.allCases {
            let (app, _) = try launch(delay: 0, only: "didReceive", kind: kind)
            assertHandlersCompleted(app, expecting: ["didReceive"])
            XCTAssertTrue(app.buttons["quickAddButton"].waitForExistence(timeout: 20) || app.windows.firstMatch.exists, "\(kind): UI up")
            app.terminate()
        }
    }

    /// The same with the app running (warm).
    func testTapWarmStartForEveryKind() throws {
        for kind in Kind.allCases {
            let (app, _) = try launch(delay: 8, only: "didReceive", kind: kind)
            XCTAssertTrue(app.buttons["quickAddButton"].waitForExistence(timeout: 20), "\(kind): UI up before the delivery")
            assertHandlersCompleted(app, expecting: ["didReceive"])
            app.terminate()
        }
    }

    /// Action buttons that open the app ("Antworten" on a question, "Öffnen" on a review), cold and warm.
    func testActionButtonsThatOpenTheApp() throws {
        for (kind, action) in [(Kind.question, "TODO_ANSWER"), (Kind.review, "TODO_OPEN")] {
            for delay in [0, 8] {
                let (app, _) = try launch(delay: delay, only: "didReceive", kind: kind, action: action)
                assertHandlersCompleted(app, expecting: ["didReceive"])
                app.terminate()
            }
        }
    }
}
