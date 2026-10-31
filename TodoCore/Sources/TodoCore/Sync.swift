import Foundation

// MARK: Sync (contracts/sync.yaml)

public struct SyncChange: Codable, Sendable, Equatable {
    public enum EntityType: String, Codable, Sendable { case project, task, column, label }
    public enum Kind: String, Codable, Sendable { case upsert, delete }
    public let seq: Int
    public let entityType: EntityType
    public let entityID: UUID
    public let kind: Kind
    public let project: Project?
    public let task: TodoTask?
    /// Set for `entityType == .column` upserts (board columns, ADR 0011).
    public let column: ProjectColumn?
    /// Planning of a task upsert (contract 1.4.0, ADR 0020); nil from older servers.
    public let planning: PlanningData?
    /// Set for `entityType == .label` upserts (account-private labels with their full task membership).
    public let label: SyncLabel?
}

/// A label as the feed delivers it (contract 1.4.0): `taskIDs` is the full membership of readable tasks.
public struct SyncLabel: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var version: Int
    public var taskIDs: [UUID]
    public init(id: UUID, name: String, version: Int = 1, taskIDs: [UUID] = []) {
        self.id = id; self.name = name; self.version = version; self.taskIDs = taskIDs
    }
    public var asTaskLabel: TaskLabel { TaskLabel(id: id, name: name, version: version) }
}

public struct SyncChanges: Codable, Sendable, Equatable {
    public let changes: [SyncChange]
    /// Opaque (`c<number>`); pass it back unchanged. `c0` is the full state.
    public let cursor: String
    public let hasMore: Bool

    public init(changes: [SyncChange], cursor: String, hasMore: Bool) {
        self.changes = changes; self.cursor = cursor; self.hasMore = hasMore
    }

    private enum CodingKeys: String, CodingKey { case changes, cursor, hasMore }
    private struct Probe: Decodable { let entityType: String }

    /// Entries of entity types this client does not know are
    /// skipped instead of failing the whole page; the cursor still advances past them.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try c.decode(String.self, forKey: .cursor)
        hasMore = try c.decode(Bool.self, forKey: .hasMore)
        var list = try c.nestedUnkeyedContainer(forKey: .changes)
        var result: [SyncChange] = []
        while !list.isAtEnd {
            let item = try list.superDecoder()
            let known = (try? Probe(from: item).entityType).flatMap(SyncChange.EntityType.init(rawValue:)) != nil
            if known { result.append(try SyncChange(from: item)) }
        }
        changes = result
    }
}

public enum SyncMutationType: String, Codable, Sendable {
    case projectCreate = "project.create", projectUpdate = "project.update", projectDelete = "project.delete"
    case taskCreate = "task.create", taskUpdate = "task.update", taskDelete = "task.delete"
    case projectPosition = "project.position", taskMoveColumn = "task.move_column"
    case columnCreate = "column.create", columnUpdate = "column.update", columnDelete = "column.delete"
    /// Contract 1.4.0 (ADR 0020).
    case taskPlanning = "task.planning"
    case labelCreate = "label.create", labelRename = "label.rename", labelDelete = "label.delete"
    case taskLabelAdd = "task.label_add", taskLabelRemove = "task.label_remove"

    /// Mutation types a server without contract 1.4.0 answers with `400 unknown_mutation_type`.
    public var isPlanningSync: Bool {
        switch self {
        case .taskPlanning, .labelCreate, .labelRename, .labelDelete, .taskLabelAdd, .taskLabelRemove: true
        default: false
        }
    }
}

/// Idempotent client mutation. Keep the same `mutationID` when retrying; use a new one for a new change.
public struct SyncMutation: Codable, Sendable, Equatable {
    public var mutationID: UUID
    public var type: SyncMutationType
    public var id: UUID
    /// Required for updates, optional for deletes (then checked).
    public var version: Int?
    public var name: String?
    public var parentID: UUID?
    public var moveToRoot: Bool?
    public var projectID: UUID?
    public var title: String?
    public var description: String?
    public var status: String?
    /// project.create/update and column.create/update: `#RRGGBB` ("" clears).
    public var color: String?
    /// column.create/update.
    public var isDone: Bool?
    /// 0-based target position: project.position, task.move_column, column.create/update.
    public var index: Int?
    /// column.delete: `"none"` or a column UUID; nil = first remaining column.
    public var moveTo: String?
    /// task.move_column: target column; nil = "Ohne Spalte".
    public var columnID: UUID?
    /// task.planning (full replacement; absent fields clear). `priority` and `reminders` are always sent.
    public var dueAt: Date?
    public var plannedAt: Date?
    public var priority: Int?
    public var recurrence: RecurrenceRule?
    public var reminders: [Date]?
    /// task.label_add / task.label_remove (`id` is the task).
    public var labelID: UUID?

    public init(
        mutationID: UUID = UUID(), type: SyncMutationType, id: UUID, version: Int? = nil, name: String? = nil,
        parentID: UUID? = nil, moveToRoot: Bool? = nil, projectID: UUID? = nil, title: String? = nil,
        description: String? = nil, status: String? = nil, color: String? = nil, isDone: Bool? = nil,
        index: Int? = nil, moveTo: String? = nil, columnID: UUID? = nil, dueAt: Date? = nil, plannedAt: Date? = nil,
        priority: Int? = nil, recurrence: RecurrenceRule? = nil, reminders: [Date]? = nil, labelID: UUID? = nil
    ) {
        self.mutationID = mutationID
        self.type = type
        self.id = id
        self.version = version
        self.name = name
        self.parentID = parentID
        self.moveToRoot = moveToRoot
        self.projectID = projectID
        self.title = title
        self.description = description
        self.status = status
        self.color = color
        self.isDone = isDone
        self.index = index
        self.moveTo = moveTo
        self.columnID = columnID
        self.dueAt = dueAt
        self.plannedAt = plannedAt
        self.priority = priority
        self.recurrence = recurrence
        self.reminders = reminders
        self.labelID = labelID
    }

    /// `task.planning` carrying the whole planning of the task.
    public static func planning(taskID: UUID, _ data: PlanningData, mutationID: UUID = UUID()) -> SyncMutation {
        SyncMutation(
            mutationID: mutationID, type: .taskPlanning, id: taskID, dueAt: data.dueAt, plannedAt: data.plannedAt,
            priority: data.priority, recurrence: data.recurrence, reminders: data.reminders)
    }

    /// The planning a `task.planning` mutation sets.
    public var planningData: PlanningData {
        PlanningData(dueAt: dueAt, plannedAt: plannedAt, priority: priority ?? 0, recurrence: recurrence, reminders: reminders ?? [])
    }
}

public struct SyncMutationResult: Codable, Sendable, Equatable {
    public let mutationID: UUID
    public let type: String
    public let id: UUID
    public let deleted: Bool
    public let project: Project?
    public let task: TodoTask?
    public let column: ProjectColumn?
    public let planning: PlanningData?
    public let label: SyncLabel?
    public let cursor: String
    /// True if the server answered 201 (entity created by this mutation).
    public var created: Bool { _created }
    var _created = false

    private enum CodingKeys: String, CodingKey { case mutationID, type, id, deleted, project, task, column, planning, label, cursor }
}

extension APIClient {
    /// One page of changes after `cursor` (default `c0` = everything visible). Loop while `hasMore`.
    /// `APIError.invalidInput(reason: "invalid_cursor")` and `APIError.conflict(reason: "cursor_ahead")`
    /// and `APIError.cursorExpired` (410, ADR 0019) mean the client should restart at `c0`.
    public func syncChanges(cursor: String = "c0", limit: Int? = nil) async throws -> SyncChanges {
        var query = [URLQueryItem(name: "cursor", value: cursor)]
        if let limit { query.append(.init(name: "limit", value: String(limit))) }
        return try await send("GET", "v1/sync/changes", query: query)
    }

    /// Follows `hasMore` until the feed is drained and returns all changes with the final cursor.
    public func syncAll(from cursor: String = "c0", pageSize: Int = 200) async throws -> SyncChanges {
        var all: [SyncChange] = []
        var current = cursor
        while true {
            let page = try await syncChanges(cursor: current, limit: pageSize)
            all += page.changes
            current = page.cursor
            if !page.hasMore { return SyncChanges(changes: all, cursor: current, hasMore: false) }
        }
    }

    public func applyMutation(_ mutation: SyncMutation) async throws -> SyncMutationResult {
        var (result, status): (SyncMutationResult, Int) = try await sendWithStatus("POST", "v1/sync/mutations", body: mutation)
        result._created = status == 201
        return result
    }
}
