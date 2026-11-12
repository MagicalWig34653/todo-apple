import Foundation

// MARK: Comments, activity, attachments (contracts/collaboration.yaml, attachments.yaml)

/// A chat message of a card. A task has one chat of its own plus one chat per question and per review
/// (`questionID`/`reviewID`); fields after `version` are missing on older servers and older messages.
public struct Comment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let taskID: UUID
    public let authorID: UUID
    public let authorName: String?
    public let body: String
    public let version: Int
    public var questionID: UUID?
    public var reviewID: UUID?
    /// `person` or `agent` (written via MCP or runner, often with the person's token).
    public var authorKind: String?
    /// Agent name (`agentName`) for agent messages.
    public var authorLabel: String?
    public var createdAt: Date?
    /// `attachment`: entry for an upload by a person (body = file name); otherwise missing.
    public var kind: String?
    public var attachmentID: UUID?
    public var attachments: [CommentAttachment]?

    public var isAgent: Bool { authorKind == "agent" }
    public var isAttachment: Bool { kind == "attachment" }

    /// Agents may write with the person's own token, so the same `authorID` alone does not make it "you".
    public func isMine(_ me: UUID?) -> Bool { !isAgent && authorID == me }

    public func author(me: UUID?) -> CommentAuthor {
        if isAgent {
            let label = authorLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .agent(label?.isEmpty == false ? label : nil)
        }
        return isMine(me) ? .me : .person(authorName)
    }
}

public enum CommentAuthor: Sendable, Equatable {
    case me
    /// Agent label, nil = unnamed agent.
    case agent(String?)
    /// Display name, nil when the account no longer exists.
    case person(String?)
}

public struct CommentAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let filename: String
    public let mediaType: String
    public let size: Int

    public var isImage: Bool { mediaType.hasPrefix("image/") }
}

/// Whose chat: everything of the task, only the task's own chat, or the chat of one question or review.
public enum CommentThread: Sendable, Hashable {
    case all, task, question(UUID), review(UUID)

    var queryItems: [URLQueryItem] {
        switch self {
        case .all: []
        case .task: [.init(name: "thread", value: "task")]
        case .question(let id): [.init(name: "questionID", value: id.uuidString)]
        case .review(let id): [.init(name: "reviewID", value: id.uuidString)]
        }
    }
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

struct CommentCreateBody: Encodable {
    let body: String
    var questionID: UUID?
    var reviewID: UUID?

    init(body: String, thread: CommentThread) {
        self.body = body
        if case .question(let id) = thread { questionID = id }
        if case .review(let id) = thread { reviewID = id }
    }
}
struct CommentUpdateBody: Encodable { let body: String; let version: Int }
struct VersionBody: Encodable { let version: Int }

extension APIClient {
    public func comments(taskID: UUID, thread: CommentThread = .all) async throws -> [Comment] {
        try await send("GET", "v1/tasks/\(taskID.uuidString)/comments", query: thread.queryItems)
    }

    /// `idempotencyKey` makes a retry after a lost response safe; reuse the same key for the same logical comment.
    /// `thread` `.question`/`.review` posts into that chat; `.all` and `.task` post into the task's own chat.
    public func addComment(taskID: UUID, body: String, thread: CommentThread = .task, idempotencyKey: UUID = UUID()) async throws -> Comment {
        try await send(
            "POST", "v1/tasks/\(taskID.uuidString)/comments", body: CommentCreateBody(body: body, thread: thread),
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
