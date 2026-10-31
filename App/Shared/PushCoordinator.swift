import Foundation
import SwiftUI
import TodoCore
import UserNotifications
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// APNs registration, notification permission and push preferences (ADR 0021, docs/PUSH.md).
/// The permission prompt is never shown automatically: only an explicit user action (settings, explainer card) asks.
@MainActor @Observable
final class PushCoordinator {
    static let shared = PushCoordinator()

    enum Authorization { case unknown, notDetermined, denied, authorized }
    enum ServerSupport { case unknown, supported, unavailable }

    private(set) var authorization: Authorization = .unknown
    private(set) var serverSupport: ServerSupport = .unknown
    /// `false` if the server answers `/health/ready` with `push.enabled == false`.
    private(set) var serverPushEnabled: Bool?
    private(set) var prefs: PushPrefs?
    private(set) var tokenHex: String?
    /// Localization key of the last registration problem (shown quietly in the settings).
    private(set) var registrationErrorKey: String?
    var prefsErrorKey: String?
    /// Link from a tapped notification that was not opened yet (cold start or signed out).
    var pendingLink: PushLink?
    /// Set by `AppModel.start()`; nil in a background launch without UI.
    weak var model: AppModel?

    private var registeredKey: String?
    private static let primerKey = "push.primerDismissed"
    var primerDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.primerKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.primerKey) }
    }

    /// True while push should be offered in the UI at all (an older server without endpoints hides everything).
    var available: Bool { serverSupport != .unavailable }

    static var environment: PushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }

    static var platform: PushPlatform {
        #if os(macOS)
        .macos
        #else
        .ios
        #endif
    }

    /// Remembers the link and opens it right away if the app is ready (otherwise `AppModel.openPendingPushLink` does later).
    func open(_ link: PushLink) {
        pendingLink = link
        model?.openPendingPushLink()
    }

    // MARK: Authorization

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: authorization = .notDetermined
        case .denied: authorization = .denied
        case .authorized, .provisional, .ephemeral: authorization = .authorized
        @unknown default: authorization = .unknown
        }
    }

    /// Shows the system prompt. Only call from an explicit user action.
    func requestAuthorization(client: APIClient?, userID: UUID?) async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
        if authorization == .authorized { registerWithSystem(); await register(client: client, userID: userID) }
    }

    private func registerWithSystem() {
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif canImport(AppKit)
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    // MARK: Token callbacks (from the application delegate)

    func didRegister(deviceToken: Data) {
        let hex = PushToken.hex(deviceToken)
        guard hex != tokenHex else { return }
        tokenHex = hex
        registeredKey = nil
        Task { await model?.pushTokenChanged() }
    }

    func didFail(error: Error) {
        // Typical causes: no network, missing push capability in the provisioning profile, simulator without token.
        registrationErrorKey = "push.error.system"
    }

    // MARK: Server

    /// On sign-in, launch and foreground: detects server support, loads preferences and (re-)registers the device.
    func sync(client: APIClient?, userID: UUID?) async {
        await refreshAuthorization()
        guard let client else { return }
        await loadServerState(client)
        guard serverSupport == .supported, authorization == .authorized else { return }
        registerWithSystem()
        await register(client: client, userID: userID)
    }

    private func loadServerState(_ client: APIClient) async {
        if let health = try? await client.ready() { serverPushEnabled = health.push?.enabled }
        do {
            prefs = try await client.pushPrefs()
            serverSupport = .supported
        } catch {
            if APIClient.isPushUnavailable(error) { serverSupport = .unavailable; prefs = nil }
            // Transport errors keep the previous state; push never blocks the app.
        }
    }

    func register(client: APIClient?, userID: UUID?) async {
        guard let client, let userID, let tokenHex, authorization == .authorized, serverSupport != .unavailable else { return }
        let key = "\(userID.uuidString)|\(tokenHex)"
        guard key != registeredKey else { return }
        let info = Bundle.main.infoDictionary
        let registration = PushRegistration(
            token: tokenHex, platform: Self.platform, environment: Self.environment,
            bundleId: Bundle.main.bundleIdentifier ?? "de.linolaske.todo",
            appVersion: info?["CFBundleShortVersionString"] as? String,
            locale: Locale.current.identifier(.bcp47))
        do {
            let device = try await client.registerPushDevice(registration)
            registeredKey = key
            registrationErrorKey = nil
            serverSupport = .supported
            Self.storeDeviceID(device.id, for: userID)
        } catch {
            if APIClient.isPushUnavailable(error) { serverSupport = .unavailable }
            else if case .invalidInput = error as? APIError { registrationErrorKey = "push.error.rejected" }
            else if case .unauthorized = error as? APIError {}
            else { registrationErrorKey = "push.error.server" }
        }
    }

    /// Revokes this device server-side before the session ends, clears the badge and local push state.
    func accountWillSignOut(client: APIClient?, userID: UUID?) async {
        if let client, let userID, let id = Self.deviceID(for: userID) {
            try? await client.revokePushDevice(id)
            Self.storeDeviceID(nil, for: userID)
        }
        registeredKey = nil; prefs = nil; registrationErrorKey = nil; prefsErrorKey = nil; serverPushEnabled = nil
        serverSupport = .unknown
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
    }

    // MARK: Preferences

    func setCategory(_ category: PushCategory, enabled: Bool, client: APIClient?) async {
        await update(PushPrefsUpdate(categories: [category: enabled]), client: client)
    }

    func setShowContent(_ on: Bool, client: APIClient?) async { await update(PushPrefsUpdate(showContent: on), client: client) }
    func setBadge(_ on: Bool, client: APIClient?) async {
        await update(PushPrefsUpdate(badge: on), client: client)
        if !on { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
    }

    private func update(_ change: PushPrefsUpdate, client: APIClient?) async {
        guard let client else { return }
        let before = prefs
        // Optimistic: the toggle follows the finger, a failure restores the previous state.
        if var p = prefs {
            for (key, value) in change.categories ?? [:] { if let c = PushCategory(rawValue: key) { p.categories[c] = value } }
            if let v = change.showContent { p.showContent = v }
            if let v = change.badge { p.badge = v }
            prefs = p
        }
        do { prefs = try await client.updatePushPrefs(change); prefsErrorKey = nil }
        catch {
            prefs = before
            if APIClient.isPushUnavailable(error) { serverSupport = .unavailable } else { prefsErrorKey = "push.error.prefs" }
        }
    }

    // MARK: Badge

    /// Mirrors the number of open questions and pending reviews while the app runs (the server sets it for pushes).
    func updateBadge(_ count: Int) {
        guard authorization == .authorized else { return }
        let value = (prefs?.badge ?? true) ? count : 0
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(value) }
    }

    // MARK: Device id per account

    private static func deviceID(for user: UUID) -> UUID? {
        UserDefaults.standard.string(forKey: "push.deviceID.\(user.uuidString)").flatMap(UUID.init(uuidString:))
    }

    private static func storeDeviceID(_ id: UUID?, for user: UUID) {
        UserDefaults.standard.set(id?.uuidString, forKey: "push.deviceID.\(user.uuidString)")
    }

    // MARK: System settings link

    func openSystemSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
        #elseif canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
        #endif
    }
}
