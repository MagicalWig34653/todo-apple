import Foundation

// MARK: Sync engine (ADR 0009, contracts/sync.yaml)
//
// Reads come from the local store; writes are applied optimistically on top of the confirmed state and queued as
// idempotent mutations. `sync()` first sends the queue (strictly in order, a retry reuses the mutationID), then
// pulls the feed from the stored cursor. The user-visible state is `confirmed + pending queue`.

public struct SyncSnapshot: Sendable, Equatable {
    /// In the viewer's order: own sibling position first, then creation time and name.
    public var projects: [Project]
    public var tasks: [TodoTask]
    /// Board columns of all projects, ordered by project and position.
    public var columns: [ProjectColumn]
    /// Mutations that are still waiting to be sent.
    public var pending: Int
    /// Queue entries stopped by a 409 `version_conflict`; resolve with `SyncEngine.resolveConflict`.
    public var conflicts: [QueuedMutation]
    /// Queue entries the server refused for good; remove with `SyncEngine.dismiss`.
    public var rejected: [QueuedMutation]
    public var cursor: String
}

public struct SyncReport: Sendable, Equatable {
    /// Mutations the server accepted in this run.
    public var pushed = 0
    /// Feed changes applied in this run.
    public var pulled = 0
    /// The feed answered `cursor_ahead`/`invalid_cursor`; local entities were replaced from `c0`.
    public var fullResync = false
    /// The server could not be reached (transport failure or 5xx). Local state stays usable.
    public var offline = false
    /// Another `sync()` was already running; it will run once more.
    public var skipped = false
    public var conflicts = 0
    public var rejected = 0
}

public enum SyncEngineError: Error, Equatable, Sendable {
    /// The entity is neither confirmed nor created by a pending mutation.
    case unknownEntity(UUID)
    case store(String)
}

public actor SyncEngine {
    private let client: APIClient
    private let store: any SyncStore
    private var state: SyncState
    private var syncing = false
    private var rerun = false
    private let pageSize: Int

    public init(client: APIClient, store: any SyncStore, pageSize: Int = 200) throws {
        self.client = client
        self.store = store
        self.pageSize = pageSize
        var loaded = try store.load()
        // Caches written before ranks existed: rank the unranked tasks once, in the old alphabetical order.
        loaded.nextRank = (loaded.ranks.values.max() ?? 0) + 1
        let unranked = loaded.tasks.values.filter { loaded.ranks[$0.id] == nil }
            .sorted { ($0.title.lowercased(), $0.id.uuidString) < ($1.title.lowercased(), $1.id.uuidString) }
        if !unranked.isEmpty {
            let before = loaded
            for t in unranked { Self.assignRank(t.id, in: &loaded) }
            try? store.commit(Self.diff(from: before, to: loaded))
        }
        self.state = loaded
    }

    /// Gives an entity its rank on first sight (see `SyncState.ranks`).
    static func assignRank(_ id: UUID, in s: inout SyncState) {
        guard s.ranks[id] == nil else { return }
        s.ranks[id] = s.nextRank
        s.nextRank += 1
    }

    // MARK: Reading

    public func snapshot() -> SyncSnapshot {
        let (projects, tasks, columns) = overlay()
        return SyncSnapshot(
            projects: projects.values.sorted(by: Self.siblingOrder),
            tasks: tasks.values.sorted { a, b in
                // Stable first-seen order; alphabetical only as a tie-break for ranks that are missing.
                let (ra, rb) = (state.ranks[a.id] ?? Int.max, state.ranks[b.id] ?? Int.max)
                if ra != rb { return ra < rb }
                return (a.title.lowercased(), a.id.uuidString) < (b.title.lowercased(), b.id.uuidString)
            },
            columns: columns.values.sorted { ($0.projectID.uuidString, $0.position, $0.id.uuidString) < ($1.projectID.uuidString, $1.position, $1.id.uuidString) },
            pending: state.queue.filter { $0.status == .pending }.count,
            conflicts: state.queue.filter { $0.status == .conflict },
            rejected: state.queue.filter { $0.status == .rejected },
            cursor: state.cursor)
    }

    /// Own sibling order of the viewer (ADR 0012): positioned first, then creation time, name and id.
    static func siblingOrder(_ a: Project, _ b: Project) -> Bool {
        let (pa, pb) = (a.position ?? Int.max, b.position ?? Int.max)
        if pa != pb { return pa < pb }
        let (ca, cb) = (a.createdAt ?? .distantFuture, b.createdAt ?? .distantFuture)
        if ca != cb { return ca < cb }
        return (a.name.lowercased(), a.id.uuidString) < (b.name.lowercased(), b.id.uuidString)
    }

    /// Confirmed state plus pending mutations. Entities with a stopped (conflict/rejected) mutation show the server
    /// state; later mutations on them stay queued but invisible until the user resolves the stop.
    private func overlay() -> (projects: [UUID: Project], tasks: [UUID: TodoTask], columns: [UUID: ProjectColumn]) {
        var projects = state.projects
        var tasks = state.tasks
        var columns = state.columns
        let blocked = blockedIDs()
        for q in state.queue where q.status == .pending && !blocked.contains(q.mutation.id) {
            let m = q.mutation
            switch m.type {
            case .projectCreate:
                if projects[m.id] == nil {
                    projects[m.id] = Project(
                        id: m.id, parentID: m.parentID, name: m.name ?? "", version: 1,
                        description: m.description.flatMap { $0.isEmpty ? nil : $0 }, color: m.color.flatMap { $0.isEmpty ? nil : $0 })
                }
            case .projectUpdate:
                if var p = projects[m.id] {
                    p.parentID = m.moveToRoot == true ? nil : (m.parentID ?? p.parentID)
                    p.name = m.name ?? p.name
                    if let d = m.description { p.description = d.isEmpty ? nil : d }
                    if let c = m.color { p.color = c.isEmpty ? nil : c }
                    projects[m.id] = p
                }
            case .projectPosition:
                guard projects[m.id] != nil, let index = m.index else { break }
                let reparent = m.moveToRoot == true || m.parentID != nil
                let parent: UUID?? = reparent ? .some(m.moveToRoot == true ? nil : m.parentID) : nil
                Self.place(project: m.id, parent: parent, index: index, in: &projects)
            case .projectDelete:
                Self.removeProjectTree(m.id, projects: &projects, tasks: &tasks, columns: &columns)
            case .taskCreate:
                if tasks[m.id] == nil, let pid = m.projectID {
                    tasks[m.id] = TodoTask(id: m.id, projectID: pid, title: m.title ?? "", description: m.description ?? "", status: m.status ?? "open", version: 1)
                }
            case .taskUpdate:
                if let t = tasks[m.id] {
                    tasks[m.id] = TodoTask(
                        id: t.id, projectID: m.projectID ?? t.projectID, title: m.title ?? t.title,
                        description: m.description ?? t.description, status: m.status ?? t.status, version: t.version,
                        columnID: t.columnID, boardPosition: t.boardPosition)
                }
            case .taskDelete:
                tasks[m.id] = nil
            case .taskMoveColumn:
                Self.place(task: m.id, in: m.columnID.flatMap { columns[$0] }, at: m.index, tasks: &tasks)
            case .columnCreate:
                if columns[m.id] == nil, let pid = m.projectID {
                    var list = columns.values.filter { $0.projectID == pid }.sorted { $0.position < $1.position }
                    let column = ProjectColumn(
                        id: m.id, projectID: pid, name: m.name ?? "", color: m.color.flatMap { $0.isEmpty ? nil : $0 },
                        isDone: m.isDone ?? false, position: list.count, version: 1)
                    list.insert(column, at: min(max(m.index ?? list.count, 0), list.count))
                    for (i, var c) in list.enumerated() { c.position = i; columns[c.id] = c }
                }
            case .columnUpdate:
                if var c = columns[m.id] {
                    if let n = m.name { c.name = n }
                    if let color = m.color { c.color = color.isEmpty ? nil : color }
                    if let d = m.isDone { c.isDone = d }
                    columns[c.id] = c
                    if let index = m.index {
                        var list = columns.values.filter { $0.projectID == c.projectID && $0.id != c.id }.sorted { $0.position < $1.position }
                        list.insert(c, at: min(max(index, 0), list.count))
                        for (i, var x) in list.enumerated() { x.position = i; columns[x.id] = x }
                    }
                }
            case .columnDelete:
                guard let c = columns[m.id] else { break }
                let remaining = columns.values.filter { $0.projectID == c.projectID && $0.id != c.id }.sorted { $0.position < $1.position }
                var target: ProjectColumn?
                if let raw = m.moveTo {
                    target = UUID(uuidString: raw).flatMap { id in remaining.first { $0.id == id } }
                } else {
                    target = remaining.first
                }
                for t in tasks.values.filter({ $0.columnID == c.id }).sorted(by: { ($0.boardPosition, $0.id.uuidString) < ($1.boardPosition, $1.id.uuidString) }) {
                    Self.place(task: t.id, in: target, at: nil, tasks: &tasks)
                }
                columns[c.id] = nil
                for (i, var x) in remaining.enumerated() { x.position = i; columns[x.id] = x }
            }
        }
        return (projects, tasks, columns)
    }

    /// Mirrors the server's board placement: dense positions in the target, done column completes, other column reopens.
    private static func place(task id: UUID, in target: ProjectColumn?, at index: Int?, tasks: inout [UUID: TodoTask]) {
        guard let t = tasks[id] else { return }
        var status = t.status
        if let target {
            if target.isDone && status != TaskStatus.done.rawValue { status = TaskStatus.done.rawValue }
            else if !target.isDone && status == TaskStatus.done.rawValue { status = TaskStatus.open.rawValue }
        }
        var others = tasks.values.filter { $0.projectID == t.projectID && $0.columnID == target?.id && $0.id != id }
            .sorted { ($0.boardPosition, $0.id.uuidString) < ($1.boardPosition, $1.id.uuidString) }
        let at = min(max(index ?? others.count, 0), others.count)
        others.insert(t, at: at)
        for (i, o) in others.enumerated() {
            tasks[o.id] = TodoTask(
                id: o.id, projectID: o.projectID, title: o.title, description: o.description,
                status: o.id == id ? status : o.status, version: o.version, columnID: target?.id, boardPosition: i)
        }
    }

    /// Mirrors `project.position`: the sibling group of the (new) parent gets dense positions 0..n-1.
    /// `parent`: nil = keep the current one; `.some(nil)` = root; `.some(id)` = that parent.
    private static func place(project id: UUID, parent: UUID??, index: Int, in projects: inout [UUID: Project]) {
        guard var p = projects[id] else { return }
        func effectiveParent(_ q: Project) -> UUID? { q.parentID.flatMap { projects[$0] != nil ? $0 : nil } }
        let newParent: UUID? = parent.map { $0 } ?? effectiveParent(p)
        if parent != nil { p.parentID = newParent }
        var siblings = projects.values.filter { $0.id != id && effectiveParent($0) == newParent }.sorted(by: siblingOrder)
        siblings.insert(p, at: min(max(index, 0), siblings.count))
        for (i, var s) in siblings.enumerated() { s.position = i; projects[s.id] = s }
    }

    /// Entities that have a queue entry stopped by a conflict or rejection.
    private func blockedIDs() -> Set<UUID> {
        Set(state.queue.filter { $0.status != .pending }.map { $0.mutation.id })
    }

    // MARK: Local writes (optimistic, queued)

    @discardableResult
    public func createProject(id: UUID = UUID(), name: String, parentID: UUID? = nil, color: String? = nil) throws -> SyncSnapshot {
        try enqueue(SyncMutation(type: .projectCreate, id: id, name: name, parentID: parentID, color: color))
    }

    @discardableResult
    public func updateProject(_ id: UUID, _ update: ProjectUpdate) throws -> SyncSnapshot {
        try enqueue(
            SyncMutation(
                type: .projectUpdate, id: id, name: update.name, parentID: update.parentID, moveToRoot: update.moveToRoot,
                description: update.description, color: update.color))
    }

    /// Places a project among its siblings. `.keep` is the personal order only; `.root`/`.parent` also change the
    /// shared tree (needs the `manage` role; the project version is taken at send time).
    @discardableResult
    public func moveProject(_ id: UUID, index: Int, parent: ProjectParentChange = .keep) throws -> SyncSnapshot {
        var m = SyncMutation(type: .projectPosition, id: id, index: index)
        switch parent {
        case .keep: break
        case .root: m.moveToRoot = true
        case .parent(let p): m.parentID = p
        }
        return try enqueue(m)
    }

    @discardableResult
    public func createColumn(id: UUID = UUID(), projectID: UUID, name: String, color: String? = nil, isDone: Bool? = nil, index: Int? = nil) throws -> SyncSnapshot {
        try enqueue(SyncMutation(type: .columnCreate, id: id, name: name, projectID: projectID, color: color, isDone: isDone, index: index))
    }

    /// `color == ""` clears the colour; `index` reorders.
    @discardableResult
    public func updateColumn(_ id: UUID, name: String? = nil, color: String? = nil, isDone: Bool? = nil, index: Int? = nil) throws -> SyncSnapshot {
        try enqueue(SyncMutation(type: .columnUpdate, id: id, name: name, color: color, isDone: isDone, index: index))
    }

    /// The tasks go to `moveTo` (nil = the first remaining column; `.some(nil)` is not representable, use `toUnassigned`).
    @discardableResult
    public func deleteColumn(_ id: UUID, moveTo: UUID? = nil, toUnassigned: Bool = false) throws -> SyncSnapshot {
        try enqueue(SyncMutation(type: .columnDelete, id: id, moveTo: toUnassigned ? "none" : moveTo?.uuidString.lowercased()))
    }

    /// Moves a task into a board column (nil = "Ohne Spalte") at `index` (nil = end).
    @discardableResult
    public func moveTask(_ id: UUID, toColumn columnID: UUID?, index: Int? = nil) throws -> SyncSnapshot {
        try enqueue(SyncMutation(type: .taskMoveColumn, id: id, index: index, columnID: columnID))
    }

    @discardableResult
    public func deleteProject(_ id: UUID) throws -> SyncSnapshot { try enqueue(SyncMutation(type: .projectDelete, id: id)) }

    @discardableResult
    public func createTask(id: UUID = UUID(), projectID: UUID, title: String, description: String? = nil) throws -> SyncSnapshot {
        try enqueue(SyncMutation(type: .taskCreate, id: id, projectID: projectID, title: title, description: description))
    }

    @discardableResult
    public func updateTask(_ id: UUID, _ update: TaskUpdate) throws -> SyncSnapshot {
        try enqueue(
            SyncMutation(
                type: .taskUpdate, id: id, projectID: update.projectID, title: update.title, description: update.description,
                status: update.status?.rawValue))
    }

    @discardableResult
    public func deleteTask(_ id: UUID) throws -> SyncSnapshot { try enqueue(SyncMutation(type: .taskDelete, id: id)) }

    static func isCreate(_ type: SyncMutationType) -> Bool { type == .projectCreate || type == .taskCreate || type == .columnCreate }

    /// Mutations that carry the entity version (a `project.position` only when it also changes the parent).
    static func needsVersion(_ m: SyncMutation) -> Bool {
        switch m.type {
        case .projectCreate, .taskCreate, .columnCreate: false
        case .projectPosition: m.moveToRoot == true || m.parentID != nil
        default: true
        }
    }

    private func confirmedVersion(_ id: UUID) -> Int? {
        state.projects[id]?.version ?? state.tasks[id]?.version ?? state.columns[id]?.version
    }

    private func enqueue(_ template: SyncMutation) throws -> SyncSnapshot {
        var m = template
        var chained = state.queue.contains { $0.mutation.id == m.id }
        if !Self.isCreate(m.type) {
            if chained {
                m.version = nil
            } else if confirmedVersion(m.id) != nil {
                if Self.needsVersion(m) { m.version = confirmedVersion(m.id) }
            } else {
                throw SyncEngineError.unknownEntity(m.id)
            }
            // Board columns change version whenever a neighbour moves; their edits are not conflict-sensitive.
            if m.type == .columnUpdate || m.type == .columnDelete { m.version = nil; chained = true }
        }
        let order = (state.queue.map(\.order).max() ?? 0) + 1
        try transact {
            $0.queue.append(QueuedMutation(mutation: m, order: order, chained: chained))
            if m.type == .taskCreate { Self.assignRank(m.id, in: &$0) }
        }
        return snapshot()
    }

    /// Takes a server-confirmed entity (for example after a REST edit) into the store. Older versions are ignored.
    public func acceptServer(task: TodoTask) throws {
        try transact { s in
            if let old = s.tasks[task.id], old.version > task.version { return }
            s.tasks[task.id] = task
            Self.assignRank(task.id, in: &s)
        }
    }

    public func acceptServer(project: Project) throws {
        try transact { s in
            if let old = s.projects[project.id], old.version > project.version { return }
            s.projects[project.id] = project
        }
    }

    /// Takes the account's favourite list (answer of `PUT/GET /v1/me/favorites`) into the cached projects.
    public func applyFavorites(_ entries: [FavoriteEntry]) throws {
        let byProject = Dictionary(entries.map { ($0.projectID, $0.position) }, uniquingKeysWith: { a, _ in a })
        try transact { s in
            for id in s.projects.keys {
                s.projects[id]?.isFavorite = byProject[id] != nil
                s.projects[id]?.favoritePosition = byProject[id]
            }
        }
    }

    // MARK: Conflict handling

    /// `keepMine`: send the change again on top of the current server version. Otherwise discard it.
    @discardableResult
    public func resolveConflict(_ mutationID: UUID, keepMine: Bool) throws -> SyncSnapshot {
        try transact { s in
            guard let i = s.queue.firstIndex(where: { $0.id == mutationID && $0.status == .conflict }) else { return }
            if keepMine {
                s.queue[i].status = .pending
                s.queue[i].reason = nil
                s.queue[i].chained = true  // version is taken from the (refreshed) confirmed state at send time
            } else {
                s.queue.remove(at: i)
            }
        }
        return snapshot()
    }

    /// Removes a stopped entry (rejected or conflict). Dismissing a rejected create also drops later changes to it.
    @discardableResult
    public func dismiss(_ mutationID: UUID) throws -> SyncSnapshot {
        try transact { s in
            guard let q = s.queue.first(where: { $0.id == mutationID && $0.status != .pending }) else { return }
            let isCreate = Self.isCreate(q.mutation.type)
            s.queue.removeAll { $0.id == mutationID || (isCreate && $0.mutation.id == q.mutation.id) }
        }
        return snapshot()
    }

    /// Wipes everything (logout, account switch). Pending mutations are lost.
    public func reset() throws {
        do { try store.wipe() } catch { throw SyncEngineError.store(String(describing: error)) }
        state = SyncState()
    }

    // MARK: Sync

    /// Sends the queue, then pulls the feed. Transport/5xx problems set `offline` instead of throwing; `unauthorized`
    /// and unexpected feed errors (for example `notFound` when the server has no sync feed) are thrown.
    public func sync() async throws -> SyncReport {
        if syncing { rerun = true; var r = SyncReport(); r.skipped = true; return r }
        syncing = true
        defer { syncing = false }
        var report = SyncReport()
        repeat {
            rerun = false
            try await flush(&report)
            if !report.offline { try await pull(&report) }
        } while rerun && !report.offline
        report.conflicts = state.queue.filter { $0.status == .conflict }.count
        report.rejected = state.queue.filter { $0.status == .rejected }.count
        return report
    }

    private func nextSendable() -> QueuedMutation? {
        let blocked = blockedIDs()
        return state.queue.first { $0.status == .pending && !blocked.contains($0.mutation.id) }
    }

    private func flush(_ report: inout SyncReport) async throws {
        while let next = nextSendable() {
            var m = next.mutation
            if next.chained, !Self.isCreate(m.type), Self.needsVersion(m) { m.version = confirmedVersion(m.id) }
            do {
                let result = try await client.applyMutation(m)
                try transact { s in
                    s.queue.removeAll { $0.id == next.id }
                    Self.confirm(result, into: &s)
                }
                report.pushed += 1
            } catch let error as APIError {
                switch error {
                case .transport, .server:
                    report.offline = true
                    return
                case .unauthorized:
                    throw error
                case .versionConflict:
                    try mark(next.id, .conflict, "version_conflict")
                case .conflict(let reason) where reason == "mutation_id_reused" && !next.idRegenerated:
                    // The server holds a different mutation under this ID, so ours was never applied under it.
                    try transact { s in
                        guard let i = s.queue.firstIndex(where: { $0.id == next.id }) else { return }
                        s.queue[i].mutation.mutationID = UUID()
                        s.queue[i].idRegenerated = true
                    }
                case .conflict(let reason), .forbidden(let reason), .invalidInput(let reason):
                    try mark(next.id, .rejected, reason ?? "rejected")
                case .notFound:
                    try mark(next.id, .rejected, "not_found")
                default:
                    throw error
                }
            }
        }
    }

    private func mark(_ id: UUID, _ status: QueuedMutation.Status, _ reason: String) throws {
        try transact { s in
            guard let i = s.queue.firstIndex(where: { $0.id == id }) else { return }
            s.queue[i].status = status
            s.queue[i].reason = reason
        }
    }

    private static func confirm(_ result: SyncMutationResult, into s: inout SyncState) {
        if result.deleted {
            removeProjectTree(result.id, projects: &s.projects, tasks: &s.tasks, columns: &s.columns)
            s.tasks[result.id] = nil
            s.columns[result.id] = nil
            return
        }
        if let c = result.column, (s.columns[c.id]?.version ?? 0) <= c.version { s.columns[c.id] = c }
        if let p = result.project, (s.projects[p.id]?.version ?? 0) <= p.version { s.projects[p.id] = p }
        if let t = result.task, (s.tasks[t.id]?.version ?? 0) <= t.version {
            s.tasks[t.id] = t
            assignRank(t.id, in: &s)
        }
    }

    private func pull(_ report: inout SyncReport) async throws {
        do {
            try await pullFeed(from: state.cursor, report: &report)
        } catch let error as APIError {
            switch error {
            case .transport, .server:
                report.offline = true
            case .conflict(let reason) where reason == "cursor_ahead":
                try await resync(&report)
            case .invalidInput(let reason) where reason == "invalid_cursor":
                try await resync(&report)
            default:
                throw error
            }
        }
    }

    private func resync(_ report: inout SyncReport) async throws {
        report.fullResync = true
        do { try await pullFeed(from: "c0", report: &report) }
        catch APIError.transport { report.offline = true }
        catch APIError.server { report.offline = true }
    }

    /// From `c0` the whole feed is collected first and then replaces the confirmed entities in one commit, so an
    /// interrupted full sync never leaves a half-empty store and a resync drops what the server no longer shows.
    private func pullFeed(from start: String, report: inout SyncReport) async throws {
        var cursor = start
        if start == "c0" {
            var all: [SyncChange] = []
            while true {
                let page = try await client.syncChanges(cursor: cursor, limit: pageSize)
                all += page.changes
                cursor = page.cursor
                if !page.hasMore { break }
            }
            try transact { s in
                s.projects = [:]
                s.tasks = [:]
                s.columns = [:]
                for change in all { Self.apply(change, to: &s) }
                s.cursor = cursor
            }
            report.pulled += all.count
            return
        }
        while true {
            let page = try await client.syncChanges(cursor: cursor, limit: pageSize)
            let next = page.cursor
            try transact { s in
                for change in page.changes { Self.apply(change, to: &s) }
                s.cursor = next
            }
            report.pulled += page.changes.count
            cursor = next
            if !page.hasMore { return }
        }
    }

    /// Feed entries arrive in sequence order. A delete (tombstone or revoke) removes the entity and, for projects,
    /// whatever hangs below it locally.
    private static func apply(_ change: SyncChange, to s: inout SyncState) {
        switch (change.entityType, change.kind) {
        case (.project, .upsert):
            if let p = change.project { s.projects[p.id] = p }
        case (.task, .upsert):
            if let t = change.task { s.tasks[t.id] = t; assignRank(t.id, in: &s) }
        case (.column, .upsert):
            if let c = change.column { s.columns[c.id] = c }
        case (.project, .delete):
            removeProjectTree(change.entityID, projects: &s.projects, tasks: &s.tasks, columns: &s.columns)
        case (.task, .delete):
            s.tasks[change.entityID] = nil
        case (.column, .delete):
            s.columns[change.entityID] = nil
        }
    }

    private static func removeProjectTree(
        _ id: UUID, projects: inout [UUID: Project], tasks: inout [UUID: TodoTask], columns: inout [UUID: ProjectColumn]
    ) {
        guard projects[id] != nil else { return }
        var doomed: Set<UUID> = [id]
        var grew = true
        while grew {
            grew = false
            for p in projects.values where !doomed.contains(p.id) && p.parentID.map(doomed.contains) == true {
                doomed.insert(p.id)
                grew = true
            }
        }
        for pid in doomed { projects[pid] = nil }
        for (tid, t) in tasks where doomed.contains(t.projectID) { tasks[tid] = nil }
        for (cid, c) in columns where doomed.contains(c.projectID) { columns[cid] = nil }
    }

    // MARK: Persistence

    /// Mutates a copy, writes the difference atomically and only then adopts the copy, so memory and disk agree.
    private func transact(_ body: (inout SyncState) -> Void) throws {
        var next = state
        body(&next)
        // Ranks live only as long as their task (confirmed or about to be created by a queued mutation).
        let creating = Set(next.queue.filter { $0.mutation.type == .taskCreate }.map(\.mutation.id))
        for id in next.ranks.keys where next.tasks[id] == nil && !creating.contains(id) { next.ranks[id] = nil }
        let batch = Self.diff(from: state, to: next)
        do { try store.commit(batch) } catch { throw SyncEngineError.store(String(describing: error)) }
        state = next
    }

    static func diff(from old: SyncState, to new: SyncState) -> SyncBatch {
        var b = SyncBatch()
        for (id, p) in new.projects where old.projects[id] != p { b.projectUpserts.append(p) }
        for (id, t) in new.tasks where old.tasks[id] != t { b.taskUpserts.append(t) }
        b.projectDeletes = old.projects.keys.filter { new.projects[$0] == nil }
        b.taskDeletes = old.tasks.keys.filter { new.tasks[$0] == nil }
        for (id, c) in new.columns where old.columns[id] != c { b.columnUpserts.append(c) }
        b.columnDeletes = old.columns.keys.filter { new.columns[$0] == nil }
        if old.cursor != new.cursor { b.cursor = new.cursor }
        let oldQueue = Dictionary(uniqueKeysWithValues: old.queue.map { ($0.id, $0) })
        let newIDs = Set(new.queue.map(\.id))
        b.queueRemovals = old.queue.map(\.id).filter { !newIDs.contains($0) }
        b.queueUpserts = new.queue.filter { oldQueue[$0.id] != $0 }
        for (id, r) in new.ranks where old.ranks[id] != r { b.rankUpserts[id] = r }
        b.rankDeletes = old.ranks.keys.filter { new.ranks[$0] == nil }
        return b
    }
}
