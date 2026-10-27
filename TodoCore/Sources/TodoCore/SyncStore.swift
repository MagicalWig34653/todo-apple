import Foundation

// MARK: Local sync state and the persistence seam
//
// The store holds the *confirmed* server state (projects/tasks as delivered by the feed or returned by
// mutations), the feed cursor and the offline mutation queue. The user-visible state is confirmed state plus the
// pending queue (computed by `SyncEngine`). Concrete stores: `InMemorySyncStore` (tests) and `SQLiteSyncStore`.

public struct QueuedMutation: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        /// Waiting to be sent (or retried after a transport failure with the same mutationID).
        case pending
        /// The server answered 409 `version_conflict`; the user decides (`SyncEngine.resolveConflict`).
        case conflict
        /// The server refused it for good (403/404/400/409 other than a conflict). The user dismisses it.
        case rejected
    }

    public var mutation: SyncMutation
    /// Position in the queue; mutations are sent strictly in this order.
    public var order: Int
    /// True if an earlier queued mutation touches the same entity: the version is then taken from the confirmed
    /// state at send time (the earlier mutation raises it).
    public var chained: Bool
    public var status: Status
    /// Machine-readable server reason for `conflict`/`rejected` (for example `version_conflict`, `id_exists`).
    public var reason: String?
    /// A `mutation_id_reused` answer is retried once under a fresh mutationID (the old one provably was not ours).
    public var idRegenerated: Bool
    public var createdAt: Date

    public var id: UUID { mutation.mutationID }

    public init(
        mutation: SyncMutation, order: Int, chained: Bool, status: Status = .pending, reason: String? = nil,
        idRegenerated: Bool = false, createdAt: Date = Date()
    ) {
        self.mutation = mutation
        self.order = order
        self.chained = chained
        self.status = status
        self.reason = reason
        self.idRegenerated = idRegenerated
        self.createdAt = createdAt
    }
}

public struct SyncState: Sendable, Equatable {
    public var projects: [UUID: Project]
    public var tasks: [UUID: TodoTask]
    public var cursor: String
    public var queue: [QueuedMutation]

    public init(projects: [UUID: Project] = [:], tasks: [UUID: TodoTask] = [:], cursor: String = "c0", queue: [QueuedMutation] = []) {
        self.projects = projects
        self.tasks = tasks
        self.cursor = cursor
        self.queue = queue
    }
}

/// One atomic write. `replaceEntities` first removes all confirmed projects/tasks (full resync); the queue is kept.
public struct SyncBatch: Sendable, Equatable {
    public var replaceEntities = false
    public var projectUpserts: [Project] = []
    public var taskUpserts: [TodoTask] = []
    public var projectDeletes: [UUID] = []
    public var taskDeletes: [UUID] = []
    public var cursor: String?
    public var queueUpserts: [QueuedMutation] = []
    /// Removed by mutationID (applied before `queueUpserts`, so an id change keeps the position).
    public var queueRemovals: [UUID] = []

    public init() {}
}

public protocol SyncStore: Sendable {
    func load() throws -> SyncState
    /// Applies the batch atomically (all or nothing).
    func commit(_ batch: SyncBatch) throws
    /// Removes everything (logout, account switch).
    func wipe() throws
}

/// Applies a batch to a state value. Shared by `InMemorySyncStore` and tests.
extension SyncState {
    mutating func apply(_ batch: SyncBatch) {
        if batch.replaceEntities { projects = [:]; tasks = [:] }
        for p in batch.projectUpserts { projects[p.id] = p }
        for t in batch.taskUpserts { tasks[t.id] = t }
        for id in batch.projectDeletes { projects[id] = nil }
        for id in batch.taskDeletes { tasks[id] = nil }
        if let cursor = batch.cursor { self.cursor = cursor }
        if !batch.queueRemovals.isEmpty { queue.removeAll { batch.queueRemovals.contains($0.id) } }
        for q in batch.queueUpserts {
            if let i = queue.firstIndex(where: { $0.id == q.id }) { queue[i] = q } else { queue.append(q) }
        }
        queue.sort { $0.order < $1.order }
    }
}

public final class InMemorySyncStore: SyncStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state = SyncState()
    /// Test hook: makes the next `commit` throw (simulates a failing disk) and clears itself.
    public var failNextCommit = false

    public init() {}

    public func load() throws -> SyncState { lock.withLock { state } }

    public func commit(_ batch: SyncBatch) throws {
        try lock.withLock {
            if failNextCommit { failNextCommit = false; throw SyncStoreError.writeFailed("injected") }
            state.apply(batch)
        }
    }

    public func wipe() throws { lock.withLock { state = SyncState() } }
}

public enum SyncStoreError: Error, Equatable, Sendable {
    case openFailed(String)
    case writeFailed(String)
    case corrupt(String)
}
