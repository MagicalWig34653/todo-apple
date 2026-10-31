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
    /// Menu-bar / keyboard command requests; the main view observes the counters and opens the matching sheet.
    var quickAddRequests = 0
    var newProjectRequests = 0
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
    /// Everything not yet confirmed by the server: queued sync mutations plus outbox edits.
    var unsentChanges: Int { pendingChanges + legacyOutboxSnapshot.pending }
    /// First unresolved `version_conflict` (the user decides: keep mine / use server).
    var conflict: QueuedMutation?
    var engine: SyncEngine?
    /// Offline outbox for planning and label edits (REST-only on the server; see `PlanningOutbox`).
    var outbox: PlanningOutbox?
    /// What the REST outbox still has to send (older servers, and entries from before the update until they moved).
    private(set) var legacyOutboxSnapshot = OutboxSnapshot()
    /// Queued planning/label mutations of the sync engine (contract 1.4.0).
    private(set) var syncMetaOverlay = OutboxSnapshot()
    /// Planning and labels as confirmed by the sync feed; only meaningful while `metaFromFeed`.
    private(set) var feedPlanning: [UUID: PlanningData] = [:]
    private(set) var feedLabels: [SyncLabel] = []
    /// The server delivers planning and labels in the feed (contract 1.4.0): `TaskMeta` needs no REST fetches for them.
    private(set) var metaFromFeed = false
    /// What is still to be sent, laid over the confirmed planning and labels by `TaskMeta` (outbox plus sync queue).
    var outboxSnapshot: OutboxSnapshot {
        var o = legacyOutboxSnapshot
        let m = syncMetaOverlay
        for (t, d) in m.planning { o.planning[t] = d }
        for (t, ids) in m.labelAdds { o.labelAdds[t, default: []].formUnion(ids); o.labelRemoves[t]?.subtract(ids) }
        for (t, ids) in m.labelRemoves { o.labelRemoves[t, default: []].formUnion(ids); o.labelAdds[t]?.subtract(ids) }
        o.newLabels = m.newLabels
        return o
    }
    /// Bumped when confirmed planning/labels may have changed (lists refresh their metadata).
    var metaRevision = 0
    /// Cache file of `TaskMeta` (planning and labels as last confirmed), next to the sync store.
    var metaCacheURL: URL?
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
        PushCoordinator.shared.model = self
        #if DEBUG
        DebugLaunch.seedSession(model: self)
        #if os(macOS)
        DebugLaunch.snapshotIfRequested()
        #endif
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
        await PushCoordinator.shared.accountWillSignOut(client: client, userID: user?.id)
        syncLoop?.cancel(); syncLoop = nil
        try? await engine?.reset()
        await outbox?.reset()
        if let url = metaCacheURL { try? FileManager.default.removeItem(at: url) }
        metaCacheURL = nil
        outbox = nil; legacyOutboxSnapshot = OutboxSnapshot(); syncMetaOverlay = OutboxSnapshot(); feedPlanning = [:]; feedLabels = []; metaFromFeed = false
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
        Task { await pushSync() }
        guard let client, let user, let path = storePath(for: user),
            let store = try? SQLiteSyncStore(path: path), let engine = try? SyncEngine(client: client, store: store)
        else { usesREST = true; loadPrefsCache(); await reloadREST(); await refreshServerState(); return }
        self.engine = engine
        metaCacheURL = URL(fileURLWithPath: path + ".meta.json")
        outbox = PlanningOutbox(store: FileOutboxStore(url: URL(fileURLWithPath: path + ".outbox.json")))
        legacyOutboxSnapshot = await outbox?.snapshot() ?? OutboxSnapshot()
        usesREST = false
        loadPrefsCache()
        let cached = await engine.snapshot()
        // A cache that already holds feed planning (contract 1.4.0) serves chips and due dates offline right away.
        metaFromFeed = !cached.planning.isEmpty
        publish(cached)
        await syncNow()
        selectDefaultIfNeeded()
        openPendingPushLink()
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
        syncMetaOverlay = snap.metaOverlay
        if metaFromFeed {
            if feedPlanning != snap.planning { feedPlanning = snap.planning }
            if feedLabels != snap.labels { feedLabels = snap.labels }
        }
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
            await migrateOutboxToEngine()
            let report = try await engine.sync()
            await handOverUnsupported(engine)
            let support = await engine.planningSyncSupport
            if (support == .supported) != metaFromFeed {
                metaFromFeed = support == .supported
                if !metaFromFeed { feedPlanning = [:]; feedLabels = [] }
                metaRevision += 1
            }
            var snap = await engine.snapshot()
            if snap.rejected.isEmpty == false {
                for q in snap.rejected { snap = (try? await engine.dismiss(q.id)) ?? snap }
                noticeKey = "notice.syncRejected"
            }
            publish(snap)
            syncStatus = report.offline ? .offline : .idle
            selectDefaultIfNeeded()
            if !report.offline { await flushOutbox(); await reloadAgenda(); await refreshServerState() }
        } catch APIError.unauthorized {
            await logout(); errorKey = "error.sessionExpired"
        } catch {
            // No usable feed (older server, decoding or store problem): use REST for everything.
            syncLoop?.cancel(); syncLoop = nil
            usesREST = true; syncStatus = .idle; pendingChanges = 0; conflict = nil
            await reloadREST()
        }
    }

    // MARK: Planning and label edits (outbox)

    /// Queues a full replacement of the task's planning (optimistic; sent as soon as the server is reachable).
    /// Without a sync engine (REST fallback) it is sent directly. Returns false if that fails.
    @discardableResult
    func savePlanning(taskID: UUID, _ data: PlanningData) async -> Bool {
        if await queueMeta({ try await $0.setPlanning(taskID, data) }) { return true }
        if let outbox, !usesREST {
            await outbox.setPlanning(taskID: taskID, data)
            await outboxChanged()
            return true
        }
        guard let client else { return false }
        do { apply(try await client.setPlanning(taskID: taskID, data).task); await reloadAgenda(); metaRevision += 1; return true }
        catch { await handle(error); return false }
    }

    func setLabel(_ label: TaskLabel, on taskID: UUID, enabled: Bool) async {
        if await queueMeta({ e in try await e.setLabel(await e.resolvedLabelID(label), on: taskID, enabled: enabled) }) { return }
        if let outbox, !usesREST {
            if enabled { await outbox.addLabel(label.id, toTask: taskID) } else { await outbox.removeLabel(label.id, fromTask: taskID) }
            await outboxChanged()
            return
        }
        guard let client else { return }
        do {
            if enabled { try await client.addLabel(label.id, toTask: taskID) } else { try await client.removeLabel(label.id, fromTask: taskID) }
            metaRevision += 1
        } catch { await handle(error) }
    }

    /// Adds a label by name: reuses a known one, otherwise it is created on the server during the replay.
    func addLabel(named name: String, to taskID: UUID, known: [TaskLabel]) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let match = known.first(where: { $0.name.lowercased() == name.lowercased() }) { await setLabel(match, on: taskID, enabled: true); return }
        if await queueMeta({ try await $0.addLabel(named: name, to: taskID) }) { return }
        if let outbox, !usesREST {
            await outbox.addLabel(named: name, toTask: taskID)
            await outboxChanged()
            return
        }
        guard let client else { return }
        do { let l = try await client.createLabel(name: name); try await client.addLabel(l.id, toTask: taskID); metaRevision += 1 }
        catch { await handle(error) }
    }

    /// Planning/label edits go into the sync queue while the server speaks contract 1.4.0 (or is not known yet to
    /// predate it). Returns false when the REST outbox has to take the edit.
    private func queueMeta(_ edit: (SyncEngine) async throws -> SyncSnapshot) async -> Bool {
        guard let engine, !usesREST, await engine.planningSyncSupport != .unsupported else { return false }
        guard let snap = try? await edit(engine) else { return false }
        publish(snap)
        metaRevision += 1
        Task { await syncNow() }
        return true
    }

    /// Moves outbox entries written by earlier builds (or while the server was old) into the sync queue, so planning
    /// edits keep their order and merge with newer ones. An entry leaves the outbox only after the queue has it.
    private func migrateOutboxToEngine() async {
        guard let engine, let outbox, await engine.planningSyncSupport != .unsupported else { return }
        for op in await outbox.pendingOps() {
            let queued: SyncSnapshot?
            switch op.kind {
            case .setPlanning:
                guard let data = op.planning else { continue }
                queued = try? await engine.setPlanning(op.taskID, data)
            case .addLabel:
                guard let l = op.labelID else { continue }
                queued = try? await engine.setLabel(l, on: op.taskID, enabled: true)
            case .removeLabel:
                guard let l = op.labelID else { continue }
                queued = try? await engine.setLabel(l, on: op.taskID, enabled: false)
            case .addLabelNamed:
                guard let n = op.labelName else { continue }
                queued = try? await engine.addLabel(named: n, to: op.taskID)
            }
            if queued != nil { await outbox.dismiss(op.id) }  // an unknown task stays in the outbox
        }
        legacyOutboxSnapshot = await outbox.snapshot()
    }

    /// The server predates contract 1.4.0: planning/label entries parked by the engine move to the REST outbox.
    private func handOverUnsupported(_ engine: SyncEngine) async {
        let parked = await engine.unsupportedMutations()
        guard !parked.isEmpty, let outbox else { return }
        await outbox.adopt(parked.map(\.mutation))
        for q in parked { _ = try? await engine.dismiss(q.id) }
        legacyOutboxSnapshot = await outbox.snapshot()
        Task { await flushOutbox() }
    }

    private func outboxChanged() async {
        legacyOutboxSnapshot = await outbox?.snapshot() ?? OutboxSnapshot()
        Task { await flushOutbox() }
    }

    /// Replays the outbox after the sync queue (tasks created offline have to exist on the server first).
    func flushOutbox() async {
        guard let outbox, let client, !usesREST else { return }
        let current = await outbox.snapshot()
        guard current.pending > 0 || !current.rejected.isEmpty else { return }
        let waiting = await engine?.queuedEntityIDs() ?? []
        do {
            let report = try await outbox.flush(client: client, skipping: waiting)
            for confirmed in report.confirmed where tasks.first(where: { $0.id == confirmed.task.id })?.version != confirmed.task.version {
                apply(confirmed.task)
            }
            let rejected = await outbox.snapshot().rejected
            for op in rejected { await outbox.dismiss(op.id) }
            if !rejected.isEmpty { noticeKey = "notice.syncRejected" }
            legacyOutboxSnapshot = await outbox.snapshot()
            if report.sent > 0 || !rejected.isEmpty { metaRevision += 1; await reloadAgenda() }
            if report.offline { syncStatus = .offline }
        } catch APIError.unauthorized {
            await logout(); errorKey = "error.sessionExpired"
        } catch {}
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
        if let center = try? await client.commandCenter(options) {
            commandSummary = center.summary
            PushCoordinator.shared.updateBadge(attentionCount)
        }
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

    /// Sets the done state and registers it with the window/shake undo manager (Cmd+Z / shake to undo and redo).
    func setDone(_ id: UUID, _ done: Bool, undoManager: UndoManager?) {
        guard let task = tasks.first(where: { $0.id == id }), task.isDone != done else { return }
        Task { await toggle(task) }
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setDone(id, !done, undoManager: undoManager) }
        }
        undoManager.setActionName(String(localized: done ? "task.markDone" : "task.markOpen"))
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
