#if DEBUG
import Foundation
import TodoCore

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

    /// `TODO_DEBUG_SELECT`: today | upcoming | search | teams | project:<name> | task:<title>
    static func navigate(model: AppModel) async {
        guard let target = env["TODO_DEBUG_SELECT"] else { return }
        for _ in 0..<50 where model.phase != .signedIn { try? await Task.sleep(for: .milliseconds(100)) }
        await model.reload()
        await model.reloadTeams()
        defer { Task { await runActions(model: model) } }
        switch target {
        case "inbox": model.selection = .inbox
        case "today": model.selection = .today
        case "upcoming": model.selection = .upcoming
        case "search": model.selection = .search
        case "teams": model.selection = .teams
        default:
            if target.hasPrefix("project:"), let p = model.projects.first(where: { $0.name == String(target.dropFirst(8)) }) {
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
