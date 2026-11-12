#if DEBUG
import Foundation
import TodoCore
import UserNotifications
#if os(macOS)
import AppKit
import SwiftUI
#endif

/// Debug builds only: lets a simulator run start signed in and on a given screen without passkey hardware
/// (`SIMCTL_CHILD_TODO_DEBUG_SERVER`, `..._TOKEN`, `..._SELECT`). Never compiled into release/TestFlight builds.
@MainActor
enum DebugLaunch {
    /// `TODO_DEBUG_QUICKADD=1` opens the quick-add sheet on launch (screenshots).
    static var openQuickAdd: Bool { ProcessInfo.processInfo.environment["TODO_DEBUG_QUICKADD"] == "1" }

    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    static func seedSession(model: AppModel) {
        guard let server = env["TODO_DEBUG_SERVER"], env["TODO_DEBUG_TOKEN"] != nil else { return }
        model.serverURL = server
        AppConfig.savedBaseURL = server
    }

    /// `TODO_DEBUG_ACTIONS` (semicolon separated, run after the selection; they call the same model code the UI uses,
    /// there is no tap automation in the simulator): `title:<task>=><new title>`, `desc:<task>=><text>`,
    /// `status:<task>=><open|in_progress|in_review|done>`, `add:<project>=><title>`, `wait:<seconds>`.
    static func runActions(model: AppModel) async {
        guard let script = env["TODO_DEBUG_ACTIONS"] else { return }
        for step in script.split(separator: ";").map(String.init) {
            let kind = step.prefix { $0 != ":" }
            let rest = step.dropFirst(kind.count + 1)
            let parts = rest.components(separatedBy: "=>")
            let subject = parts[0], value = parts.count > 1 ? parts[1] : ""
            switch kind {
            case "wait": try? await Task.sleep(for: .seconds(Double(subject) ?? 1))
            case "add":
                if let p = model.projects.first(where: { $0.name == subject }) {
                    model.selectedProjectID = p.id
                    await model.addTask(title: value)
                }
            case "title", "desc", "status":
                guard let t = model.tasks.first(where: { $0.title == subject }) else { continue }
                let detail = TaskDetailModel(task: t)
                switch kind {
                case "title": await detail.saveText(title: value, description: t.description, model)
                case "desc": await detail.saveText(title: t.title, description: value, model)
                default: if let st = TaskStatus(rawValue: value) { await detail.setStatus(st, model) }
                }
            default: break
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// `TODO_DEBUG_LOCAL_PUSH=<userInfo JSON>` (server payload format, see PushDelivery in the backend): asks for
    /// notification permission and schedules a local notification with that payload after `TODO_DEBUG_LOCAL_PUSH_DELAY`
    /// seconds (default 6). Lets a UI test tap a notification like a server push (simctl cannot grant the permission).
    static func scheduleLocalPushIfRequested() async {
        guard let json = env["TODO_DEBUG_LOCAL_PUSH"], let data = json.data(using: .utf8),
              let userInfo = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
        let aps = userInfo["aps"] as? [String: Any]
        let alert = aps?["alert"] as? [String: Any]
        let content = UNMutableNotificationContent()
        content.title = alert?["title"] as? String ?? "Todolino"
        content.body = alert?["body"] as? String ?? ""
        content.categoryIdentifier = aps?["category"] as? String ?? ""
        content.userInfo = userInfo
        let delay = Double(env["TODO_DEBUG_LOCAL_PUSH_DELAY"] ?? "") ?? 6
        let request = UNNotificationRequest(identifier: "debug-local-push", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
        try? await center.add(request)
    }

    #if os(macOS)
    /// `TODO_DEBUG_SNAPSHOT=<png path>[:<seconds>]` (macOS): writes the main window to a PNG and quits. Exists because
    /// `screencapture` needs a screen-recording permission that headless agent runs do not have.
    static func snapshotIfRequested() {
        guard let spec = env["TODO_DEBUG_SNAPSHOT"] else { return }
        let parts = spec.components(separatedBy: ":")
        let delay = parts.count > 1 ? Double(parts[1]) ?? 8 : 8
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview ?? NSApp.windows.first?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[0]))
            exit(0)
        }
    }
    #endif

    #if os(macOS)
    /// `TODO_DEBUG_RENDER=<dir>[:<seconds>]` (macOS): renders the main view per screen and colour scheme to PNGs with
    /// `ImageRenderer` and quits. The app runs with activation policy `.prohibited` (see `AppDelegate`), so no window
    /// appears and nothing is activated. `TODO_DEBUG_RENDER_MODE=hosting` renders an `NSHostingView` in an off-screen
    /// window (never ordered front) instead, for views whose content loads in `.task`.
    static var renderRequested: Bool { env["TODO_DEBUG_RENDER"] != nil }

    static func renderIfRequested(model: AppModel) async {
        guard let spec = env["TODO_DEBUG_RENDER"] else { return }
        let parts = spec.components(separatedBy: ":")
        let dir = URL(fileURLWithPath: parts[0])
        let settle = parts.count > 1 ? Double(parts[1]) ?? 6 : 6
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for _ in 0..<100 where model.phase != .signedIn { try? await Task.sleep(for: .milliseconds(100)) }
        guard model.phase == .signedIn else { exit(3) }
        await model.reload()
        let hosting = env["TODO_DEBUG_RENDER_MODE"] == "hosting"
        let size = CGSize(width: 1280, height: 820)
        for (name, item) in [("feed", SidebarItem.feed), ("commandcenter", .commandCenter)] {
            for dark in [false, true] {
                model.selection = item
                let view = RootView().environment(model)
                    .frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let file = dir.appendingPathComponent("mac-\(name)-\(dark ? "dark" : "light").png")
                if hosting {
                    let host = NSHostingView(rootView: view.preferredColorScheme(dark ? .dark : .light))
                    host.frame = CGRect(origin: .zero, size: size)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .seconds(settle))
                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(2) }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: file)
                    window.contentView = nil
                } else {
                    try? await Task.sleep(for: .seconds(settle))
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff) else { exit(2) }
                    try? rep.representation(using: .png, properties: [:])?.write(to: file)
                }
            }
        }
        exit(0)
    }
    #endif

    /// `TODO_DEBUG_SELECT`: feed | projects | today | upcoming | inbox | search | teams | project:<name> | task:<title>
    static func navigate(model: AppModel) async {
        guard let target = env["TODO_DEBUG_SELECT"] else { return }
        for _ in 0..<50 where model.phase != .signedIn { try? await Task.sleep(for: .milliseconds(100)) }
        await model.reload()
        await model.reloadTeams()
        defer { Task { await runActions(model: model) } }
        switch target {
        case "feed": model.selection = .feed
        case "projects", "browse": model.selection = .projects
        case "inbox": model.selection = .inbox
        case "today": model.selection = .today
        case "upcoming": model.selection = .upcoming
        case "search": model.selection = .search
        case "teams": model.selection = .teams
        case "labels": model.selection = .labels
        case "account": model.selection = .account
        case "runner": model.selection = .runner
        case "activity": model.selection = .activity
        case "commandcenter": model.selection = .commandCenter
        default:
            if target.hasPrefix("cc:"), let p = model.projects.first(where: { $0.name == String(target.dropFirst(3)) }) {
                model.selection = .projectCommandCenter(p.id)
            } else if target.hasPrefix("project:"), let p = model.projects.first(where: { $0.name == String(target.dropFirst(8)) }) {
                model.selectedProjectID = p.id
            } else if target.hasPrefix("task:"), let t = model.tasks.first(where: { $0.title == String(target.dropFirst(5)) }) {
                model.selectedProjectID = t.projectID
                try? await Task.sleep(for: .milliseconds(300))
                model.path = [t]
            }
        }
    }
}
#endif
