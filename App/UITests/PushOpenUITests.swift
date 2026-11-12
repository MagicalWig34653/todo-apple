import XCTest

/// Opening the app by tapping a notification (cold start and from the background). Regression for the TestFlight crash
/// 2611121259: the async `didReceive` delegate finished on a cooperative thread and UIKit's completion handler asserted
/// there. Needs no backend: the debug build schedules a local notification with the server's payload format
/// (`TODO_DEBUG_LOCAL_PUSH`), the test taps it on the home screen.
final class PushOpenUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let title = "UITest Erinnerung"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Same shape as `PushMessage.payload()` in the backend (PushDelivery.swift).
    private var payload: String {
        """
        {"aps":{"alert":{"title":"\(title)","body":"Eine Aufgabe ist fällig."},"badge":1,"category":"TODO_REMINDER",\
        "mutable-content":1,"sound":"default","thread-id":"reminder"},"kind":"reminder",\
        "projectID":"6F1C2D3E-4B5A-4C6D-8E7F-901A2B3C4D5E","taskID":"1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D"}
        """
    }

    private func launchSchedulingPush() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_LOCAL_PUSH"] = payload
        // Long enough for the permission prompt and leaving the app; it must fire on the home screen.
        app.launchEnvironment["TODO_DEBUG_LOCAL_PUSH_DELAY"] = "15"
        app.launch()
        // Permission prompt (first run on a fresh simulator).
        // Depending on the OS version it lives in SpringBoard or in the app's own hierarchy.
        let isAllow = NSPredicate(format: "label IN %@", ["Erlauben", "Allow"])
        for _ in 0..<8 {
            let fromSpringboard = springboard.buttons.matching(isAllow).firstMatch
            let fromApp = app.buttons.matching(isAllow).firstMatch
            if fromSpringboard.exists { fromSpringboard.tap(); break }
            if fromApp.exists { fromApp.tap(); break }
            sleep(1)
        }
        sleep(2) // the request is added right after the permission
        return app
    }

    private func tapNotification() {
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "notification banner")
        banner.tap()
    }

    private func assertStaysRunning() {
        // A fresh handle: after `terminate()` the old one does not follow a process the system launched.
        let launched = XCUIApplication(bundleIdentifier: "de.linolaske.todo")
        XCTAssertTrue(launched.wait(for: .runningForeground, timeout: 10), "app opened from the notification")
        // The crash came about two seconds after the tap, when the response handler finished.
        sleep(6)
        let now = XCUIApplication(bundleIdentifier: "de.linolaske.todo")
        XCTAssertEqual(now.state, .runningForeground, "app still running after the notification tap (no crash)")
        XCTAssertTrue(now.windows.firstMatch.exists, "app window still there")
    }

    func testColdStartFromNotificationDoesNotCrash() {
        let app = launchSchedulingPush()
        app.terminate()
        tapNotification()
        assertStaysRunning()
    }

    func testWarmStartFromNotificationDoesNotCrash() {
        _ = launchSchedulingPush()
        XCUIDevice.shared.press(.home)
        tapNotification()
        assertStaysRunning()
    }
}
