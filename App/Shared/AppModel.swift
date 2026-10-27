import Foundation
import Observation
import TodoCore

enum SidebarItem: Hashable {
    case today, upcoming, search, teams
    case project(UUID)
}

@MainActor @Observable
final class AppModel {
    enum Phase { case launching, signedOut, signedIn }

    var phase: Phase = .launching
    var user: User?
    var capabilities: Capabilities?
    var errorKey: String?
    var busy = false
    var serverURL = AppConfig.savedBaseURL

    // Data
    var projects: [Project] = []
    var tasks: [TodoTask] = []
    var selection: SidebarItem? = nil
    var today: [PlanningTask] = []
    var upcoming: [PlanningTask] = []
    var teams: [Team] = []
    var teamInvitations: [TeamMembership] = []
    /// Localization key of a transient notice (for example after a version conflict).
    var noticeKey: String?

    private let tokenStore = KeychainTokenStore()
    private let passkey = PlatformPasskey()

    var client: APIClient? {
        guard let url = URL(string: serverURL), url.scheme != nil, url.host != nil else { return nil }
        return APIClient(baseURL: url, session: Self.session, tokenStore: tokenStore)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    var selectedProjectID: UUID? {
        get { if case .project(let id) = selection { id } else { nil } }
        set { selection = newValue.map(SidebarItem.project) }
    }

    var tree: [ProjectNode] { ProjectTree.build(projects) }
    var visibleTasks: [TodoTask] { tasks.filter { $0.projectID == selectedProjectID } }

    func start() async {
        guard let client, client.hasStoredSession() else { phase = .signedOut; await refreshCapabilities(); return }
        do {
            user = try await client.me()
            phase = .signedIn
            await reload()
        } catch APIError.unauthorized {
            try? await client.logout()
            phase = .signedOut
            await refreshCapabilities()
        } catch {
            // Offline at launch: keep the token, show login with the error.
            phase = .signedOut
            errorKey = "error.network"
        }
    }

    func refreshCapabilities() async {
        errorKey = nil
        guard let client else { errorKey = "error.invalidServer"; return }
        AppConfig.savedBaseURL = serverURL
        do { capabilities = try await client.capabilities() }
        catch { capabilities = nil; errorKey = "error.network" }
    }

    private func run(_ work: (APIClient) async throws -> User) async {
        guard let client else { errorKey = "error.invalidServer"; return }
        busy = true; errorKey = nil
        defer { busy = false }
        do {
            user = try await work(client)
            phase = .signedIn
            await reload()
        } catch { errorKey = Self.key(for: error) }
    }

    func loginWithPasskey() async { await run { try await $0.loginWithPasskey(authenticator: passkey) } }

    func register(token: String, displayName: String) async {
        await run { try await $0.registerWithPasskey(token: token, displayName: displayName, authenticator: passkey) }
    }

    func loginWithPassword(username: String, password: String) async {
        await run { try await $0.passwordLogin(username: username, password: password) }
    }

    func logout() async {
        try? await client?.logout()
        user = nil; projects = []; tasks = []; today = []; upcoming = []; teams = []; teamInvitations = []; selection = nil
        phase = .signedOut
        await refreshCapabilities()
    }

    // MARK: Data

    func reload() async {
        guard let client else { return }
        do {
            async let p = client.projects()
            async let t = client.tasks()
            (projects, tasks) = try await (p, t)
            if selection == nil || (selectedProjectID != nil && !projects.contains(where: { $0.id == selectedProjectID })) {
                selection = .today
            }
            await reloadAgenda()
        } catch { await handle(error) }
    }

    /// Today/upcoming come from the server (calendar day in the device time zone). Failures only keep the old lists.
    func reloadAgenda() async {
        guard let client else { return }
        async let t = client.today()
        async let u = client.upcoming()
        if let t = try? await t { today = t }
        if let u = try? await u { upcoming = u }
    }

    func reloadTeams() async {
        guard let client else { return }
        do {
            async let t = client.teams()
            async let i = client.teamInvitations()
            (teams, teamInvitations) = try await (t, i)
        } catch { await handle(error) }
    }

    func addProject(name: String, parentID: UUID?) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let client, !name.isEmpty else { return }
        do {
            let p = try await client.createProject(name: name, parentID: parentID)
            projects.append(p); selectedProjectID = p.id
        } catch { await handle(error) }
    }

    func renameProject(_ project: Project, to name: String) async {
        guard let client else { return }
        do { replace(try await client.updateProject(project.id, version: project.version, ProjectUpdate(name: name))) }
        catch { await handle(error) }
    }

    func deleteProject(_ project: Project) async {
        guard let client else { return }
        do { try await client.deleteProject(project.id); await reload() } catch { await handle(error) }
    }

    func addTask(title: String) async {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard let client, let pid = selectedProjectID, !title.isEmpty else { return }
        do { tasks.append(try await client.createTask(projectID: pid, title: title)) } catch { await handle(error) }
    }

    func toggle(_ task: TodoTask) async {
        guard let client else { return }
        do {
            let updated = try await client.updateTask(task.id, version: task.version, TaskUpdate(status: task.isDone ? .open : .done))
            if let i = tasks.firstIndex(where: { $0.id == updated.id }) { tasks[i] = updated }
            await reloadAgenda()
        } catch { await handle(error) }
    }

    /// Applies a server-confirmed task (for example after a detail edit) to the local lists.
    func apply(_ updated: TodoTask) {
        if let i = tasks.firstIndex(where: { $0.id == updated.id }) { tasks[i] = updated }
    }

    func deleteTask(_ task: TodoTask) async {
        guard let client else { return }
        do { try await client.deleteTask(task.id); tasks.removeAll { $0.id == task.id } } catch { await handle(error) }
    }

    private func replace(_ p: Project) {
        if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p }
    }

    /// Simple conflict policy: the server state wins; reload and tell the user to repeat the change.
    func handle(_ error: Error) async {
        switch error as? APIError {
        case .versionConflict:
            noticeKey = "notice.conflict"
            await reload()
        case .unauthorized:
            await logout(); errorKey = "error.sessionExpired"
        default:
            noticeKey = Self.key(for: error)
        }
    }

    static func key(for error: Error) -> String {
        switch error as? APIError {
        case .unauthorized: "error.loginFailed"
        case .forbidden: "error.forbidden"
        case .passwordLoginDisabled: "error.passwordDisabled"
        case .transport: "error.network"
        case .passkeyFailed: "error.passkey"
        case .notFound: "error.notFound"
        case .invalidInput: "error.invalidInput"
        case .conflict: "error.conflict"
        default: "error.generic"
        }
    }
}
