import Foundation

// MARK: Sync engine (ADR 0009, contracts/sync.yaml)
//
// Reads come from the local store; writes are applied optimistically on top of the confirmed state and queued as
// idempotent mutations. `sync()` first sends the queue (strictly in order, a retry reuses the mutationID), then
// pulls the feed from the stored cursor. The user-visible state is `confirmed + pending queue`.

public struct SyncSnapshot: Sendable, Equatable {
    public var projects: [Project]
    public var tasks: [TodoTask]
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
        self.state = try store.load()
    }

    // MARK: Reading

    public func snapshot() -> SyncSnapshot {
        let (projects, tasks) = overlay()
        return SyncSnapshot(
            projects: projects.values.sorted { ($0.name.lowercased(), $0.id.uuidString) < ($1.name.lowercased(), $1.id.uuidString) },
            tasks: tasks.values.sorted { ($0.title.lowercased(), $0.id.uuidString) < ($1.title.lowercased(), $1.id.uuidString) },
            pending: state.queue.filter { $0.status == .pending }.count,
            conflicts: state.queue.filter { $0.status == .conflict },
            rejected: state.queue.filter { $0.status == .rejected },
            cursor: state.cursor)
    }

    /// Confirmed state plus pending mutations. Entities with a stopped (conflict/rejected) mutation show the server
    /// state; later mutations on them stay queued but invisible until the user resolves the stop.
    private func overlay() -> (projects: [UUID: Project], tasks: [UUID: TodoTask]) {
        var projects = state.projects
        var tasks = state.tasks
        let blocked = blockedIDs()
        for q in state.queue where q.status == .pending && !blocked.contains(q.mutation.id) {
            let m = q.mutation
            switch m.type {
            case .projectCreate:
                if projects[m.id] == nil { projects[m.id] = Project(id: m.id, parentID: m.parentID, name: m.name ?? "", version: 1) }
            case .projectUpdate:
                if let p = projects[m.id] {
                    let parent = m.moveToRoot == true ? nil : (m.parentID ?? p.parentID)
                    projects[m.id] = Project(id: p.id, parentID: parent, name: m.name ?? p.name, version: p.version)
                }
            case .projectDelete:
                Self.removeProjectTree(m.id, projects: &projects, tasks: &tasks)
            case .taskCreate:
                if tasks[m.id] == nil, let pid = m.projectID {
                    tasks[m.id] = TodoTask(id: m.id, projectID: pid, title: m.title ?? "", description: m.description ?? "", status: m.status ?? "open", version: 1)
                }
            case .taskUpdate:
                if let t = tasks[m.id] {
                    tasks[m.id] = TodoTask(
                        id: t.id, projectID: m.projectID ?? t.projectID, title: m.title ?? t.title,
                        description: m.description ?? t.description, status: m.status ?? t.status, version: t.version)
                }
            case .taskDelete:
                tasks[m.id] = nil
            }
        }
        return (projects, tasks)
    }

    /// Entities that have a queue entry stopped by a conflict or rejection.
    private func blockedIDs() -> Set<UUID> {
        Set(state.queue.filter { $0.status != .pending }.map { $0.mutation.id })
    }

    // MARK: Local writes (optimistic, queued)

    @discardableResult
    public func createProject(id: UUID = UUID(), name: String, parentID: UUID? = nil) throws -> SyncSnapshot {
        try enqueue(SyncMutation(type: .projectCreate, id: id, name: name, parentID: parentID))
    }

    @discardableResult
    public func updateProject(_ id: UUID, _ update: ProjectUpdate) throws -> SyncSnapshot {
        try enqueue(SyncMutation(type: .projectUpdate, id: id, name: update.name, parentID: update.parentID, moveToRoot: update.moveToRoot))
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

    private func enqueue(_ template: SyncMutation) throws -> SyncSnapshot {
        var m = template
        let touchesExisting = m.type != .projectCreate && m.type != .taskCreate
        let chained = state.queue.contains { $0.mutation.id == m.id }
        if touchesExisting {
            if chained {
                m.version = nil
            } else if let v = state.projects[m.id]?.version ?? state.tasks[m.id]?.version {
                m.version = v
            } else {
                throw SyncEngineError.unknownEntity(m.id)
            }
        }
        let order = (state.queue.map(\.order).max() ?? 0) + 1
        try transact { $0.queue.append(QueuedMutation(mutation: m, order: order, chained: chained)) }
        return snapshot()
    }

    /// Takes a server-confirmed entity (for example after a REST edit) into the store. Older versions are ignored.
    public func acceptServer(task: TodoTask) throws {
        try transact { s in
            if let old = s.tasks[task.id], old.version > task.version { return }
            s.tasks[task.id] = task
        }
    }

    public func acceptServer(project: Project) throws {
        try transact { s in
            if let old = s.projects[project.id], old.version > project.version { return }
            s.projects[project.id] = project
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
            let isCreate = q.mutation.type == .projectCreate || q.mutation.type == .taskCreate
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
            if next.chained, m.type != .projectCreate, m.type != .taskCreate {
                m.version = state.projects[m.id]?.version ?? state.tasks[m.id]?.version
            }
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
            removeProjectTree(result.id, projects: &s.projects, tasks: &s.tasks)
            s.tasks[result.id] = nil
            return
        }
        if let p = result.project, (s.projects[p.id]?.version ?? 0) <= p.version { s.projects[p.id] = p }
        if let t = result.task, (s.tasks[t.id]?.version ?? 0) <= t.version { s.tasks[t.id] = t }
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
            if let t = change.task { s.tasks[t.id] = t }
        case (.project, .delete):
            removeProjectTree(change.entityID, projects: &s.projects, tasks: &s.tasks)
        case (.task, .delete):
            s.tasks[change.entityID] = nil
        }
    }

    private static func removeProjectTree(_ id: UUID, projects: inout [UUID: Project], tasks: inout [UUID: TodoTask]) {
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
    }

    // MARK: Persistence

    /// Mutates a copy, writes the difference atomically and only then adopts the copy, so memory and disk agree.
    private func transact(_ body: (inout SyncState) -> Void) throws {
        var next = state
        body(&next)
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
        if old.cursor != new.cursor { b.cursor = new.cursor }
        let oldQueue = Dictionary(uniqueKeysWithValues: old.queue.map { ($0.id, $0) })
        let newIDs = Set(new.queue.map(\.id))
        b.queueRemovals = old.queue.map(\.id).filter { !newIDs.contains($0) }
        b.queueUpserts = new.queue.filter { oldQueue[$0.id] != $0 }
        return b
    }
}
