import Foundation

// MARK: Offline outbox for REST-only task metadata
//
// contracts/sync.yaml (1.3.0) has no mutation for planning (due date, recurrence, reminders, priority) or labels,
// and the feed `Task` carries none of it. Until the backend gains those, the client keeps its own small outbox:
// the edits are applied optimistically (see `OutboxSnapshot`), persisted, and replayed against the REST routes
// (`PUT /v1/planning/tasks/{id}`, `PUT|DELETE /v1/tasks/{id}/labels/{labelID}`) once the server is reachable.
// The replay is idempotent (PUT replaces the whole planning, label add/remove can be repeated), so a retry after a
// lost response is safe. There is no version on these routes: the last write wins, same as online.

public struct OutboxOp: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case setPlanning, addLabel, removeLabel, addLabelNamed }
    public enum Status: String, Codable, Sendable { case pending, rejected }

    public var id: UUID
    public var kind: Kind
    public var taskID: UUID
    public var planning: PlanningData?
    public var labelID: UUID?
    public var labelName: String?
    public var status: Status
    /// Server reason for a rejected op (`not_found`, `forbidden`, ...).
    public var reason: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(), kind: Kind, taskID: UUID, planning: PlanningData? = nil, labelID: UUID? = nil,
        labelName: String? = nil, status: Status = .pending, reason: String? = nil, createdAt: Date = Date()
    ) {
        self.id = id; self.kind = kind; self.taskID = taskID; self.planning = planning; self.labelID = labelID
        self.labelName = labelName; self.status = status; self.reason = reason; self.createdAt = createdAt
    }
}

/// What the UI lays over the confirmed planning and labels.
public struct OutboxSnapshot: Sendable, Equatable {
    /// Latest unsent planning per task (replaces the confirmed planning).
    public var planning: [UUID: PlanningData] = [:]
    public var labelAdds: [UUID: Set<UUID>] = [:]
    public var labelRemoves: [UUID: Set<UUID>] = [:]
    /// Labels to add by name (created on the server on replay if missing).
    public var namedAdds: [UUID: [String]] = [:]
    public var pending = 0
    public var rejected: [OutboxOp] = []
    public init() {}
}

public struct OutboxReport: Sendable, Equatable {
    public var sent = 0
    public var rejected = 0
    /// The server could not be reached; the remaining ops stay queued.
    public var offline = false
    /// Server answers of replayed planning edits (task version may have changed).
    public var confirmed: [PlanningTask] = []
    /// Labels created by name during the replay.
    public var createdLabels: [TaskLabel] = []
    public init() {}
}

public protocol OutboxStore: Sendable {
    func load() throws -> [OutboxOp]
    func save(_ ops: [OutboxOp]) throws
}

public final class InMemoryOutboxStore: OutboxStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ops: [OutboxOp] = []
    public init() {}
    public func load() throws -> [OutboxOp] { lock.lock(); defer { lock.unlock() }; return ops }
    public func save(_ ops: [OutboxOp]) throws { lock.lock(); self.ops = ops; lock.unlock() }
}

/// One JSON file per server and account (atomic replace).
public struct FileOutboxStore: OutboxStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    public func load() throws -> [OutboxOp] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return try Self.decoder.decode([OutboxOp].self, from: data)
    }

    public func save(_ ops: [OutboxOp]) throws {
        if ops.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try Self.encoder.encode(ops).write(to: url, options: .atomic)
    }
}

public actor PlanningOutbox {
    private let store: any OutboxStore
    private var ops: [OutboxOp]
    private var flushing = false

    public init(store: any OutboxStore) {
        self.store = store
        self.ops = (try? store.load()) ?? []
    }

    // MARK: Enqueue (with coalescing)

    /// Replaces all planning data of the task; an older unsent edit of the same task is superseded.
    public func setPlanning(taskID: UUID, _ data: PlanningData) {
        ops.removeAll { $0.status == .pending && $0.kind == .setPlanning && $0.taskID == taskID }
        ops.append(OutboxOp(kind: .setPlanning, taskID: taskID, planning: data))
        persist()
    }

    public func addLabel(_ labelID: UUID, toTask taskID: UUID) {
        dropLabelOps(taskID: taskID, labelID: labelID)
        ops.append(OutboxOp(kind: .addLabel, taskID: taskID, labelID: labelID))
        persist()
    }

    public func removeLabel(_ labelID: UUID, fromTask taskID: UUID) {
        dropLabelOps(taskID: taskID, labelID: labelID)
        ops.append(OutboxOp(kind: .removeLabel, taskID: taskID, labelID: labelID))
        persist()
    }

    /// Adds the label with this name (case-insensitive); it is looked up or created on the server during the replay.
    public func addLabel(named name: String, toTask taskID: UUID) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let exists = ops.contains { $0.status == .pending && $0.kind == .addLabelNamed && $0.taskID == taskID && $0.labelName?.lowercased() == name.lowercased() }
        guard !exists else { return }
        ops.append(OutboxOp(kind: .addLabelNamed, taskID: taskID, labelName: name))
        persist()
    }

    private func dropLabelOps(taskID: UUID, labelID: UUID) {
        ops.removeAll { $0.status == .pending && ($0.kind == .addLabel || $0.kind == .removeLabel) && $0.taskID == taskID && $0.labelID == labelID }
    }

    /// Forget everything queued for a task (deleted locally).
    public func discard(taskID: UUID) {
        ops.removeAll { $0.taskID == taskID }
        persist()
    }

    /// Drops everything (sign-out: the account's cache is discarded as well).
    public func reset() { ops = []; persist() }

    public func dismiss(_ id: UUID) { ops.removeAll { $0.id == id }; persist() }

    // MARK: Reading

    public var pendingCount: Int { ops.filter { $0.status == .pending }.count }

    public func snapshot() -> OutboxSnapshot {
        var s = OutboxSnapshot()
        for op in ops where op.status == .pending {
            s.pending += 1
            switch op.kind {
            case .setPlanning: s.planning[op.taskID] = op.planning
            case .addLabel:
                guard let l = op.labelID else { continue }
                s.labelAdds[op.taskID, default: []].insert(l); s.labelRemoves[op.taskID]?.remove(l)
            case .removeLabel:
                guard let l = op.labelID else { continue }
                s.labelRemoves[op.taskID, default: []].insert(l); s.labelAdds[op.taskID]?.remove(l)
            case .addLabelNamed: if let n = op.labelName { s.namedAdds[op.taskID, default: []].append(n) }
            }
        }
        s.rejected = ops.filter { $0.status == .rejected }
        return s
    }

    // MARK: Replay

    /// Sends the queued ops strictly in order. Ops for `skipping` tasks (not yet created on the server) stay queued.
    /// Transport failures and 5xx stop the run (`offline`); other failures reject the op, the rest continues.
    /// 401 is thrown so the caller can sign out.
    public func flush(client: APIClient, skipping: Set<UUID> = []) async throws -> OutboxReport {
        var report = OutboxReport()
        guard !flushing else { return report }
        flushing = true
        defer { flushing = false }
        for op in ops where op.status == .pending && !skipping.contains(op.taskID) {
            do {
                try await send(op, client: client, report: &report)
                ops.removeAll { $0.id == op.id }
                report.sent += 1
            } catch let error as APIError {
                switch error {
                case .transport: report.offline = true
                case .server(let status, _) where status >= 500: report.offline = true
                case .unauthorized: persist(); throw error
                default:
                    // A repeated delete of a gone label is a success; everything else is final.
                    if op.kind == .removeLabel, case .notFound = error { ops.removeAll { $0.id == op.id }; report.sent += 1; continue }
                    if let i = ops.firstIndex(where: { $0.id == op.id }) {
                        ops[i].status = .rejected; ops[i].reason = Self.reason(error)
                    }
                    report.rejected += 1
                }
                if report.offline { break }
            }
        }
        persist()
        return report
    }

    private func send(_ op: OutboxOp, client: APIClient, report: inout OutboxReport) async throws {
        switch op.kind {
        case .setPlanning:
            guard let data = op.planning else { return }
            report.confirmed.append(try await client.setPlanning(taskID: op.taskID, data))
        case .addLabel:
            guard let l = op.labelID else { return }
            try await client.addLabel(l, toTask: op.taskID)
        case .removeLabel:
            guard let l = op.labelID else { return }
            try await client.removeLabel(l, fromTask: op.taskID)
        case .addLabelNamed:
            guard let name = op.labelName else { return }
            let known = try await Self.findLabel(named: name, client: client)
            let label: TaskLabel
            if let known { label = known } else {
                label = try await client.createLabel(name: name)
                report.createdLabels.append(label)
            }
            try await client.addLabel(label.id, toTask: op.taskID)
        }
    }

    /// Case-insensitive lookup over all pages (the server caps a page at 100 labels).
    private static func findLabel(named name: String, client: APIClient) async throws -> TaskLabel? {
        var cursor: String?
        repeat {
            let page = try await client.labels(limit: 100, cursor: cursor)
            if let hit = page.items.first(where: { $0.name.lowercased() == name.lowercased() }) { return hit }
            cursor = page.nextCursor
        } while cursor != nil
        return nil
    }

    private static func reason(_ error: APIError) -> String {
        switch error {
        case .notFound: "not_found"
        case .forbidden: "forbidden"
        case .versionConflict: "version_conflict"
        case .conflict(let r): r ?? "conflict"
        case .invalidInput(let r): r ?? "invalid_input"
        default: "error"
        }
    }

    private func persist() { try? store.save(ops) }
}
