import Foundation

// MARK: Comments, activity, attachments (contracts/collaboration.yaml, attachments.yaml)

public struct Comment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let taskID: UUID
    public let authorID: UUID
    public let authorName: String?
    public let body: String
    public let version: Int
}

public struct Activity: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sequence: Int
    /// `Person`, `Integration` or `Run`.
    public let actorType: String
    public let actorID: UUID
    public let actorName: String?
    /// For example `comment.created`, `task.status_changed`, `agent.question`; unknown kinds must stay displayable.
    public let kind: String
    public let subjectID: UUID?
    public let createdAt: Date?
}

public struct TaskAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let taskID: UUID
    public let filename: String
    /// `reference`, `progress` or `result`.
    public let role: String
    public let mediaType: String
    public let size: Int
    public let checksum: String
    public let status: String

    public var isImage: Bool { mediaType.hasPrefix("image/") }
}

struct CommentCreateBody: Encodable { let body: String }
struct CommentUpdateBody: Encodable { let body: String; let version: Int }
struct VersionBody: Encodable { let version: Int }

extension APIClient {
    public func comments(taskID: UUID) async throws -> [Comment] {
        try await send("GET", "v1/tasks/\(taskID.uuidString)/comments")
    }

    /// `idempotencyKey` makes a retry after a lost response safe; reuse the same key for the same logical comment.
    public func addComment(taskID: UUID, body: String, idempotencyKey: UUID = UUID()) async throws -> Comment {
        try await send(
            "POST", "v1/tasks/\(taskID.uuidString)/comments", body: CommentCreateBody(body: body),
            headers: ["Idempotency-Key": idempotencyKey.uuidString])
    }

    public func updateComment(taskID: UUID, id: UUID, version: Int, body: String) async throws -> Comment {
        try await send(
            "PATCH", "v1/tasks/\(taskID.uuidString)/comments/\(id.uuidString)", body: CommentUpdateBody(body: body, version: version))
    }

    public func deleteComment(taskID: UUID, id: UUID, version: Int) async throws {
        try await sendNoContent("DELETE", "v1/tasks/\(taskID.uuidString)/comments/\(id.uuidString)", body: VersionBody(version: version))
    }

    public func activity(taskID: UUID, limit: Int? = nil, cursor: String? = nil) async throws -> Page<Activity> {
        try await send("GET", "v1/tasks/\(taskID.uuidString)/activity", query: Self.paging(limit, cursor))
    }

    /// Metadata only. Upload, download and preview (binary) are not part of this client yet.
    public func attachments(taskID: UUID) async throws -> [TaskAttachment] {
        try await send("GET", "v1/tasks/\(taskID.uuidString)/attachments")
    }
}
