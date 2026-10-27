import Foundation

// MARK: Sync (contracts/sync.yaml)

public struct SyncChange: Codable, Sendable, Equatable {
    public enum EntityType: String, Codable, Sendable { case project, task }
    public enum Kind: String, Codable, Sendable { case upsert, delete }
    public let seq: Int
    public let entityType: EntityType
    public let entityID: UUID
    public let kind: Kind
    public let project: Project?
    public let task: TodoTask?
}

public struct SyncChanges: Codable, Sendable, Equatable {
    public let changes: [SyncChange]
    /// Opaque (`c<number>`); pass it back unchanged. `c0` is the full state.
    public let cursor: String
    public let hasMore: Bool
}

public enum SyncMutationType: String, Codable, Sendable {
    case projectCreate = "project.create", projectUpdate = "project.update", projectDelete = "project.delete"
    case taskCreate = "task.create", taskUpdate = "task.update", taskDelete = "task.delete"
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

    public init(
        mutationID: UUID = UUID(), type: SyncMutationType, id: UUID, version: Int? = nil, name: String? = nil,
        parentID: UUID? = nil, moveToRoot: Bool? = nil, projectID: UUID? = nil, title: String? = nil,
        description: String? = nil, status: String? = nil
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
    }
}

public struct SyncMutationResult: Codable, Sendable, Equatable {
    public let mutationID: UUID
    public let type: String
    public let id: UUID
    public let deleted: Bool
    public let project: Project?
    public let task: TodoTask?
    public let cursor: String
    /// True if the server answered 201 (entity created by this mutation).
    public var created: Bool { _created }
    var _created = false

    private enum CodingKeys: String, CodingKey { case mutationID, type, id, deleted, project, task, cursor }
}

extension APIClient {
    /// One page of changes after `cursor` (default `c0` = everything visible). Loop while `hasMore`.
    /// `APIError.invalidInput(reason: "invalid_cursor")` and `APIError.conflict(reason: "cursor_ahead")`
    /// mean the client should restart at `c0`.
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
