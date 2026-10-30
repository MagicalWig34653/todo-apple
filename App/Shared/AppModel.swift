import Foundation
import Observation
import TodoCore

enum SidebarItem: Hashable {
    case inbox, today, upcoming, search, teams, labels, account, runner, activity, commandCenter
    case project(UUID)
    case projectCommandCenter(UUID)
    case label(UUID)
}

@MainActor @Observable
final class AppModel {
    enum Phase { case launching, signedOut, signedIn }

    var phase: Phase = .launching
    var user: User?
    var capabilities: Capabilities?
    var errorKey: String? { didSet { errorDetail = nil } }
    /// Raw cause line shown small below the error (for example the `ASAuthorizationError` code).
    var errorDetail: String?
    /// Restricted bearer from a redeemed recovery code (memory only; valid for minutes).
    var recoveryToken: RecoveryToken?
    /// Host of the configured server, used in error texts.
    var serverHost: String { URL(string: serverURL)?.host ?? serverURL }
    var busy = false
    var serverURL = AppConfig.savedBaseURL

    // Data
    var projects: [Project] = []
    var tasks: [TodoTask] = []
    /// Board columns of all projects (from the sync store; empty with the REST fallback, where boards are fetched).
    var columns: [ProjectColumn] = []
    /// Per-account display settings per project (server state, ADR 0012), with local edits not yet sent on top.
    var displayPrefs: [UUID: ProjectDisplayPrefs] = [:]
    var pendingPrefs: [UUID: ProjectPrefsPatch] = [:]
    var prefsFlushing = false
    var selection: SidebarItem? = nil
    /// Detail navigation path (task details pushed on the detail stack).
    var path: [TodoTask] = []
    var today: [PlanningTask] = []
    var upcoming: [PlanningTask] = []
    var teams: [Team] = []
    var teamInvitations: [TeamMembership] = []
    /// Localization key of a transient notice (for example after a version conflict).
    var noticeKey: String?

    // Sync (local store + background sync; REST fallback if the server has no usable sync feed)
    enum SyncStatus { case idle, syncing, offline }
    var syncStatus: SyncStatus = .idle
    /// Changes waiting to be sent.
    var pendingChanges = 0
    /// First unresolved `version_conflict` (the user decides: keep mine / use server).
    var conflict: QueuedMutation?
    var engine: SyncEngine?
    var hasEngine: Bool { engine != nil && !usesREST }
    var syncLoop: Task<Void, Never>?
    /// True when the sync feed is unavailable and everything goes through REST like before the sync engine.
    private(set) var usesREST = false
    private static let syncInterval: Duration = .seconds(30)

    #if DEBUG
    // Unsigned simulator builds have no keychain access group; a debug token from the environment lives in memory.
    private let tokenStore: any TokenStore = {
        if let t = ProcessInfo.processInfo.environment["TODO_DEBUG_TOKEN"] { return InMemoryTokenStore(token: t) }
        return KeychainTokenStore()
    }()
    #else
    private let tokenStore: any TokenStore = KeychainTokenStore()
    #endif
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

    /// Last signed-in account, so a launch without network can still open the local store.
    private static var cachedUser: User? {
        get { UserDefaults.standard.data(forKey: "cachedUser").flatMap { try? JSONDecoder().decode(User.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "cachedUser") }
    }

    var selectedProjectID: UUID? {
        get { if case .project(let id) = selection { id } else { nil } }
        set { selection = newValue.map(SidebarItem.project) }
    }

    var tree: [ProjectNode] { ProjectTree.build(projects) }
    var visibleTasks: [TodoTask] { tasks.filter { $0.projectID == selectedProjectID } }

    func start() async {
        #if DEBUG
        DebugLaunch.seedSession(model: self)
        defer { Task { await DebugLaunch.navigate(model: self) } }
        #endif
        guard let client, client.hasStoredSession() else { phase = .signedOut; await refreshCapabilities(); return }
        do {
            user = try await client.me()
            Self.cachedUser = user
            phase = .signedIn
            await beginSync()
        } catch APIError.unauthorized {
            try? await client.logout()
            phase = .signedOut
            await refreshCapabilities()
        } catch {
            if let cached = Self.cachedUser {
                // Offline at launch with a stored session: work from the local store, sync when the server is back.
                user = cached
                phase = .signedIn
                await beginSync()
            } else {
                phase = .signedOut
                errorKey = "error.network"
            }
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
        busy = true; errorKey = nil; errorDetail = nil
        defer { busy = false }
        do {
            user = try await work(client)
            Self.cachedUser = user
            phase = .signedIn
            await beginSync()
        } catch { errorKey = Self.key(for: error); errorDetail = Self.detail(for: error) }
    }

    /// Recovery with a one-time code issued by an admin: redeem, create a new passkey for the existing account
    /// (iCloud Keychain on this device), then sign in with it. If creating the passkey fails after the code was
    /// redeemed, the restricted bearer is kept so the user can retry without a new code (it expires after minutes).
    func recover(code: String, passkeyName: String) async {
        guard let client else { errorKey = "error.invalidServer"; return }
        busy = true; errorKey = nil; errorDetail = nil
        defer { busy = false }
        if let t = recoveryToken, t.expiresAt <= Date() { recoveryToken = nil }
        do {
            if recoveryToken == nil {
                do { recoveryToken = try await client.redeemRecovery(code: code) }
                catch { throw RecoveryStepError.redeem(error) }
            }
            guard let bearer = recoveryToken?.token else { return }
            do {
                let name = passkeyName.trimmingCharacters(in: .whitespacesAndNewlines)
                try await client.registerRecoveryPasskey(
                    bearer: bearer, passkeyName: name.isEmpty ? nil : name, authenticator: passkey)
            } catch APIError.unauthorized {
                recoveryToken = nil
                throw RecoveryStepError.expired
            }
            recoveryToken = nil
            user = try await client.loginWithPasskey(authenticator: passkey)
            Self.cachedUser = user
            phase = .signedIn
            await beginSync()
        } catch RecoveryStepError.redeem(let e) {
            errorKey = Self.recoveryRedeemKey(for: e); errorDetail = Self.detail(for: e)
        } catch RecoveryStepError.expired {
            errorKey = "error.recovery.expired"
        } catch {
            errorKey = Self.key(for: error); errorDetail = Self.detail(for: error)
        }
    }

    private enum RecoveryStepError: Error { case redeem(any Error), expired }

    func resetRecovery() { recoveryToken = nil; errorKey = nil; errorDetail = nil }

    static func recoveryRedeemKey(for error: Error) -> String {
        switch error as? APIError {
        case .unauthorized, .forbidden, .notFound, .invalidInput, .conflict: "error.recovery.invalidCode"
        default: key(for: error)
        }
    }

    /// Small raw-cause line for support/diagnosis; nil when the localized text says everything.
    static func detail(for error: Error) -> String? {
        switch error as? APIError {
        case .passkey(let f): "ASAuthorizationError \(f.code) \u{00B7} \(f.detail)"
        case .passkeyFailed(let text): String(text.prefix(200))
        case .server(let status, let reason): "HTTP \(status)" + (reason.map { " \u{00B7} \($0)" } ?? "")
        case .transport(let text): String(text.prefix(200))
        default: nil
        }
    }

    func loginWithPasskey() async { await run { try await $0.loginWithPasskey(authenticator: passkey) } }

    func register(token: String, displayName: String) async {
        await run { try await $0.registerWithPasskey(token: token, displayName: displayName, authenticator: passkey) }
    }

    func loginWithPassword(username: String, password: String) async {
        await run { try await $0.passwordLogin(username: username, password: password) }
    }

    func logout() async {
        syncLoop?.cancel(); syncLoop = nil
        try? await engine?.reset()
        engine = nil; usesREST = false; syncStatus = .idle; pendingChanges = 0; conflict = nil
        try? await client?.logout()
        Self.cachedUser = nil
        user = nil; projects = []; tasks = []; columns = []; displayPrefs = [:]; pendingPrefs = [:]; today = []; upcoming = []; teams = []; teamInvitations = []; commandSummary = nil; selection = nil
        phase = .signedOut
        await refreshCapabilities()
    }

    // MARK: Data

    // MARK: Sync

    private func storePath(for user: User) -> String? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Todo", isDirectory: true)
        else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // One database per server and account; a different account never sees another one's cache.
        let server = serverURL.unicodeScalars.map { $0.properties.isAlphabetic || $0.properties.numericType != nil ? Character($0) : "_" }
        return dir.appendingPathComponent("sync-\(String(server))-\(user.id.uuidString).sqlite").path
    }

    /// Opens the local store, shows what is cached right away, then syncs and keeps syncing in the background.
    /// Falls back to REST if the store cannot be opened.
    private func beginSync() async {
        syncLoop?.cancel()
        guard let client, let user, let path = storePath(for: user),
            let store = try? SQLiteSyncStore(path: path), let engine = try? SyncEngine(client: client, store: store)
        else { usesREST = true; loadPrefsCache(); await reloadREST(); await refreshServerState(); return }
        self.engine = engine
        usesREST = false
        loadPrefsCache()
        await publish(await engine.snapshot())
        await syncNow()
        selectDefaultIfNeeded()
        syncLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.syncInterval)
                if Task.isCancelled { return }
                await self?.syncNow()
            }
        }
    }

    func publish(_ snap: SyncSnapshot) {
        projects = snap.projects
        tasks = snap.tasks
        columns = snap.columns
        pendingChanges = snap.pending
        conflict = snap.conflicts.first
    }

    private func selectDefaultIfNeeded() {
        if selection == nil || (selectedProjectID != nil && !projects.contains(where: { $0.id == selectedProjectID })) {
            selection = .today
        }
    }

    /// Sends queued changes, pulls the feed and refreshes the lists. Offline is not an error: cached data stays.
    func syncNow() async {
        guard let engine, !usesREST else { return }
        syncStatus = .syncing
        do {
            let report = try await engine.sync()
            var snap = await engine.snapshot()
            if report.rejected > 0 {
                for q in snap.rejected { snap = (try? await engine.dismiss(q.id)) ?? snap }
                noticeKey = "notice.syncRejected"
            }
            publish(snap)
            syncStatus = report.offline ? .offline : .idle
            selectDefaultIfNeeded()
            if !report.offline { await reloadAgenda(); await refreshServerState() }
        } catch APIError.unauthorized {
            await logout(); errorKey = "error.sessionExpired"
        } catch {
            // No usable feed (older server, decoding or store problem): use REST for everything.
            syncLoop?.cancel(); syncLoop = nil
            usesREST = true; syncStatus = .idle; pendingChanges = 0; conflict = nil
            await reloadREST()
        }
    }

    func resolveConflict(keepMine: Bool) async {
        guard let engine, let c = conflict else { return }
        if let snap = try? await engine.resolveConflict(c.id, keepMine: keepMine) { publish(snap) }
        await syncNow()
    }

    func queueChange(_ change: (SyncEngine) async throws -> SyncSnapshot) async -> Bool {
        guard let engine, !usesREST else { return false }
        do { publish(try await change(engine)) } catch { noticeKey = "error.generic"; return true }
        Task { await syncNow() }
        return true
    }

    func reload() async {
        if engine != nil, !usesREST { await syncNow() } else { await reloadREST() }
    }

    func reloadREST() async {
        guard let client else { return }
        do {
            async let p = client.projects()
            async let t = client.tasks()
            (projects, tasks) = try await (p, t)
            if selection == nil || (selectedProjectID != nil && !projects.contains(where: { $0.id == selectedProjectID })) {
                selection = .today
            }
            await reloadAgenda()
            await refreshServerState()
        } catch { await handle(error) }
    }

    /// Today/upcoming come from the server (calendar day in the device time zone). Failures only keep the old lists.
    func reloadAgenda() async {
        guard let client else { return }
        async let t = client.today()
        async let u = client.upcoming()
        if let t = try? await t { today = t }
        if let u = try? await u { upcoming = u }
        agendaLoaded = true
    }

    /// False until the first agenda load finished (lists show skeleton rows instead of an empty state).
    var agendaLoaded = false

    /// Open questions and pending reviews across the account (badge on the command-center entry).
    var commandSummary: CommandSummary?
    var attentionCount: Int { (commandSummary?.openQuestions ?? 0) + (commandSummary?.pendingReviews ?? 0) }

    /// Light fetch (summary only); failures keep the last value because this is a background refresh.
    func refreshCommandSummary() async {
        guard let client else { return }
        var options = CommandCenterOptions(view: .list)
        options.limit = 1; options.updatesLimit = 0
        if let center = try? await client.commandCenter(options) { commandSummary = center.summary }
    }

    func reloadTeams() async {
        guard let client else { return }
        do {
            async let t = client.teams()
            async let i = client.teamInvitations()
            (teams, teamInvitations) = try await (t, i)
        } catch APIError.transport {
            // Offline: keep the last lists, no alert for a background refresh.
        } catch { await handle(error) }
    }

    func addProject(name: String, parentID: UUID?) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let client, !name.isEmpty else { return }
        let id = UUID()
        if await queueChange({ try await $0.createProject(id: id, name: name, parentID: parentID) }) { selectedProjectID = id; return }
        do {
            let p = try await client.createProject(name: name, parentID: parentID)
            projects.append(p); selectedProjectID = p.id
        } catch { await handle(error) }
    }

    func renameProject(_ project: Project, to name: String) async {
        guard let client else { return }
        if await queueChange({ try await $0.updateProject(project.id, ProjectUpdate(name: name)) }) { return }
        do { replace(try await client.updateProject(project.id, version: project.version, ProjectUpdate(name: name))) }
        catch { await handle(error) }
    }

    func deleteProject(_ project: Project) async {
        guard let client else { return }
        if await queueChange({ try await $0.deleteProject(project.id) }) { return }
        do { try await client.deleteProject(project.id); await reload() } catch { await handle(error) }
    }

    func addTask(title: String) async {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard let client, let pid = selectedProjectID, !title.isEmpty else { return }
        if await queueChange({ try await $0.createTask(projectID: pid, title: title) }) { return }
        do { tasks.append(try await client.createTask(projectID: pid, title: title)) } catch { await handle(error) }
    }

    /// Creates a task in `projectID` without changing the selection and returns its id (quick-add then sets
    /// planning and labels, which are REST-only). nil if the task could not be created.
    func createTask(projectID: UUID, title: String) async -> UUID? {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard let client, !title.isEmpty else { return nil }
        let id = UUID()
        if await queueChange({ try await $0.createTask(id: id, projectID: projectID, title: title) }) {
            return tasks.contains { $0.id == id } ? id : nil
        }
        do { let t = try await client.createTask(projectID: projectID, title: title); tasks.append(t); return t.id }
        catch { await handle(error); return nil }
    }

    func toggle(_ task: TodoTask) async {
        guard let client else { return }
        if await queueChange({ try await $0.updateTask(task.id, TaskUpdate(status: task.isDone ? .open : .done)) }) { return }
        do {
            let updated = try await client.updateTask(task.id, version: task.version, TaskUpdate(status: task.isDone ? .open : .done))
            if let i = tasks.firstIndex(where: { $0.id == updated.id }) { tasks[i] = updated }
            await reloadAgenda()
        } catch { await handle(error) }
    }

    /// Task detail edits (title, description, status). With the sync engine they are optimistic and queued (they
    /// also work offline); without it they go through REST. Returns the task as it should now be shown.
    func updateTask(_ task: TodoTask, _ update: TaskUpdate) async -> TodoTask? {
        guard let client else { return nil }
        if await queueChange({ try await $0.updateTask(task.id, update) }) { return tasks.first { $0.id == task.id } ?? task }
        do {
            let updated = try await client.updateTask(task.id, version: task.version, update)
            if let i = tasks.firstIndex(where: { $0.id == updated.id }) { tasks[i] = updated }
            await reloadAgenda()
            return updated
        } catch { await handle(error); return nil }
    }

    /// Applies a server-confirmed task (for example after a detail edit) to the local lists.
    func apply(_ updated: TodoTask) {
        if let engine, !usesREST {
            // Queued edits stay on top of the confirmed state, so republish from the engine instead of overwriting.
            Task { try? await engine.acceptServer(task: updated); publish(await engine.snapshot()); await syncNow() }
        } else if let i = tasks.firstIndex(where: { $0.id == updated.id }) { tasks[i] = updated }
    }

    func deleteTask(_ task: TodoTask) async {
        guard let client else { return }
        if await queueChange({ try await $0.deleteTask(task.id) }) { return }
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
        case .passkey(let failure): "error.passkey." + failure.kind.rawValue
        case .server(429, _): "error.rateLimited"
        case .notFound: "error.notFound"
        case .invalidInput: "error.invalidInput"
        case .conflict: "error.conflict"
        default: "error.generic"
        }
    }
}
