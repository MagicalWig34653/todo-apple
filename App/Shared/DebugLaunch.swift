#if DEBUG
import Foundation
import TodoCore

/// Debug builds only: lets a simulator run start signed in and on a given screen without passkey hardware
/// (`SIMCTL_CHILD_TODO_DEBUG_SERVER`, `..._TOKEN`, `..._SELECT`). Never compiled into release/TestFlight builds.
@MainActor
enum DebugLaunch {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    static func seedSession(model: AppModel) {
        guard let server = env["TODO_DEBUG_SERVER"], env["TODO_DEBUG_TOKEN"] != nil else { return }
        model.serverURL = server
        AppConfig.savedBaseURL = server
    }

    /// `TODO_DEBUG_SELECT`: today | upcoming | search | teams | project:<name> | task:<title>
    static func navigate(model: AppModel) async {
        guard let target = env["TODO_DEBUG_SELECT"] else { return }
        for _ in 0..<50 where model.phase != .signedIn { try? await Task.sleep(for: .milliseconds(100)) }
        await model.reload()
        await model.reloadTeams()
        switch target {
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
