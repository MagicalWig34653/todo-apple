import Foundation
import SwiftUI
import TodoCore
import UserNotifications
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Notification categories with actions (identifiers match `aps.category` of the server, ADR 0021).
enum NotificationCategorySetup {
    static func register() {
        func action(_ id: String, _ key: String.LocalizationValue, foreground: Bool, destructive: Bool = false) -> UNNotificationAction {
            UNNotificationAction(identifier: id, title: String(localized: key), options: foreground ? [.foreground] : [])
        }
        let reminder = UNNotificationCategory(
            identifier: PushIdentifiers.reminder,
            actions: [action(PushIdentifiers.actionDone, "push.action.done", foreground: false),
                      action(PushIdentifiers.actionSnooze, "push.action.snooze", foreground: false)],
            intentIdentifiers: [], options: [])
        let question = UNNotificationCategory(
            identifier: PushIdentifiers.question,
            actions: [action(PushIdentifiers.actionAnswer, "push.action.answer", foreground: true)],
            intentIdentifiers: [], options: [])
        let review = UNNotificationCategory(
            identifier: PushIdentifiers.review,
            actions: [action(PushIdentifiers.actionOpen, "push.action.open", foreground: true)],
            intentIdentifiers: [], options: [])
        let comment = UNNotificationCategory(identifier: PushIdentifiers.comment, actions: [], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([reminder, question, review, comment])
    }
}

/// Foreground presentation and taps. Created once by the platform application delegate.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func install() {
        UNUserNotificationCenter.current().delegate = self
        NotificationCategorySetup.register()
    }

    // Completion-handler variants on purpose, not the `async` ones: the compiler thunk of an `async` delegate method
    // calls UIKit's completion handler from a cooperative thread, and UIKit asserts the main thread there
    // (`_performBlockAfterCATransactionCommitSynchronizes`), which crashed every launch from a notification tap
    // (TestFlight 2611121259). Here the handler is always called on the main actor.

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let payload = PushPayload(userInfo: notification.request.content.userInfo)
        Task { @MainActor in
            // Foreground push: show it and refresh what it is about; the badge follows the payload.
            if let badge = payload.badge, PushCoordinator.shared.prefs?.badge ?? true {
                Task { try? await UNUserNotificationCenter.current().setBadgeCount(badge) }
            }
            if let model = PushCoordinator.shared.model, model.phase == .signedIn {
                Task { await model.syncNow(); await model.refreshCommandSummary() }
            }
            completionHandler([.banner, .list, .sound, .badge])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let payload = PushPayload(userInfo: content.userInfo)
        let action = PushResponseAction.resolve(actionIdentifier: response.actionIdentifier, payload: payload)
        Task { @MainActor in
            await Self.handle(action, payload: payload, content: content)
            completionHandler()
        }
    }

    @MainActor private static func handle(_ action: PushResponseAction, payload: PushPayload, content: UNNotificationContent) async {
        switch action {
        case .none: break
        case .open(let link): PushCoordinator.shared.open(link)
        case .snooze(let taskID): await snooze(content, taskID: taskID)
        case .markDone(let taskID, let projectID):
            let done = await PushActions.markDone(taskID: taskID, projectID: projectID)
            // If it could not be done (offline, signed out), bring the task up instead of losing the tap.
            if !done, let link = payload.link { PushCoordinator.shared.open(link) }
        }
    }

    /// "Später": a local copy of the reminder in one hour (nothing is sent to the server).
    private static func snooze(_ content: UNNotificationContent, taskID: UUID) async {
        guard let copy = content.mutableCopy() as? UNMutableNotificationContent else { return }
        let request = UNNotificationRequest(
            identifier: "snooze-\(taskID.uuidString)", content: copy,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false))
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// "Erledigen" from a notification. With a running, signed-in model it goes through the sync queue; in a background
/// launch (no UI yet) it uses REST with the stored session.
enum PushActions {
    @MainActor static func markDone(taskID: UUID, projectID: UUID?) async -> Bool {
        if let model = PushCoordinator.shared.model, model.phase == .signedIn {
            return await model.markDoneFromPush(taskID: taskID, projectID: projectID)
        }
        guard let projectID, let url = URL(string: AppConfig.savedBaseURL) else { return false }
        let client = APIClient(baseURL: url, tokenStore: KeychainTokenStore())
        guard client.hasStoredSession() else { return false }
        do {
            guard let task = try await client.tasks(projectID: projectID).first(where: { $0.id == taskID }) else { return false }
            if task.isDone { return true }
            _ = try await client.updateTask(taskID, version: task.version, TaskUpdate(status: .done))
            return true
        } catch { return false }
    }
}

#if canImport(UIKit)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationDelegate.shared.install()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushCoordinator.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushCoordinator.shared.didFail(error: error) }
    }
}
#elseif canImport(AppKit)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Offscreen rendering run (TODO_DEBUG_RENDER): no window, no activation, no Dock icon.
        if ProcessInfo.processInfo.environment["TODO_DEBUG_RENDER"] != nil { NSApp.setActivationPolicy(.prohibited) }
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationDelegate.shared.install()
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushCoordinator.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushCoordinator.shared.didFail(error: error) }
    }
}
#endif
