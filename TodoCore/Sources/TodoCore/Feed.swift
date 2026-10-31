import Foundation

// "Für dich" feed (backend ADR 0023, contracts/feed.yaml in the main repository).

public struct FeedActor: Codable, Sendable, Equatable, Hashable {
    /// `Person`, `Integration` or `Run`.
    public let type: String
    public let id: UUID
    public let name: String?
    public var isAgent: Bool { type != "Person" }
}

public struct FeedImage: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let attachmentID: UUID
    public let buildArtifactID: UUID?
    public let filename: String
    public let mediaType: String
    public let previewURL: String
    public let buildID: String?
    public let label: String?
    public let platform: String?
    public var id: UUID { attachmentID }
}

public struct FeedPost: Codable, Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case progress, build, done, review, question, comment, agentRun = "agent_run" }
    public let id: UUID
    public let kind: String
    public let event: String
    /// started | finished | stopped | failed (agent runs), accepted | changes_requested (reviews).
    public let state: String?
    public let projectID: UUID
    public let projectName: String
    public let taskID: UUID
    public let taskTitle: String
    public let actor: FeedActor
    public let text: String?
    public let detail: String?
    public let percent: Int?
    public let images: [FeedImage]
    public let createdAt: Date?
    public var postKind: Kind? { Kind(rawValue: kind) }
}

/// Request body of a feed action; sent unchanged (plus the user's text in `inputField`).
public struct FeedActionBody: Codable, Sendable, Equatable, Hashable {
    public var answer: String?
    public var decision: String?
    public var note: String?
    public var status: String?
    public var version: Int?
}

public struct FeedAction: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let key: String
    public let label: String
    public let method: String
    public let path: String
    public let body: FeedActionBody?
    public let requiresInput: Bool
    public let inputField: String?
    public var id: String { key + "|" + label }
}

public struct FeedNeedsYou: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// question | review | blocked | overdue | due
    public let id: String
    public let kind: String
    public let projectID: UUID
    public let projectName: String
    public let taskID: UUID
    public let taskTitle: String
    public let taskVersion: Int
    public let title: String
    public let detail: String?
    public let options: [String]
    public let blocking: Bool
    public let questionID: UUID?
    public let reviewID: UUID?
    public let dueAt: Date?
    public let actor: FeedActor?
    public let createdAt: Date?
    public let actions: [FeedAction]
}

public struct FeedPage: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let mode: String
    public let projectID: UUID?
    public let needsYou: [FeedNeedsYou]
    public let needsYouTotal: Int
    public let posts: [FeedPost]
    public let nextCursor: String?

    public init(generatedAt: Date, mode: String, projectID: UUID?, needsYou: [FeedNeedsYou], needsYouTotal: Int, posts: [FeedPost], nextCursor: String?) {
        self.generatedAt = generatedAt; self.mode = mode; self.projectID = projectID; self.needsYou = needsYou
        self.needsYouTotal = needsYouTotal; self.posts = posts; self.nextCursor = nextCursor
    }
}

public enum FeedMode: String, Sendable { case all, classic, management }

/// The paged feed state: page 1 replaces everything, later pages append (deduplicated by post id).
public struct FeedState: Sendable, Equatable {
    public private(set) var needsYou: [FeedNeedsYou] = []
    public private(set) var needsYouTotal = 0
    public private(set) var posts: [FeedPost] = []
    public private(set) var nextCursor: String?
    public private(set) var loaded = false

    public init() {}

    public mutating func replace(with page: FeedPage) {
        needsYou = page.needsYou; needsYouTotal = page.needsYouTotal; posts = page.posts; nextCursor = page.nextCursor; loaded = true
    }

    public mutating func append(_ page: FeedPage) {
        let known = Set(posts.map(\.id))
        posts += page.posts.filter { !known.contains($0.id) }
        nextCursor = page.nextCursor
    }

    /// Drops a handled item immediately (before the refetch confirms it).
    public mutating func remove(needsYouID id: String) {
        needsYou.removeAll { $0.id == id }
        needsYouTotal = max(0, needsYouTotal - 1)
    }

    public var isEmpty: Bool { loaded && needsYou.isEmpty && posts.isEmpty }
}

extension APIClient {
    /// `GET /v1/feed`. Throws `APIError.notFound` on servers without the feed (or an invisible project).
    public func feed(cursor: String? = nil, limit: Int? = nil, projectID: UUID? = nil, mode: FeedMode? = nil) async throws -> FeedPage {
        var query: [URLQueryItem] = []
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        if let limit { query.append(.init(name: "limit", value: String(limit))) }
        if let projectID { query.append(.init(name: "projectID", value: projectID.uuidString.lowercased())) }
        if let mode { query.append(.init(name: "mode", value: mode.rawValue)) }
        return try await send("GET", "v1/feed", query: query)
    }

    /// Performs a feed action as the server described it. `input` fills `inputField` when `requiresInput`.
    public func perform(_ action: FeedAction, input: String? = nil) async throws {
        var body = action.body ?? FeedActionBody()
        if action.requiresInput {
            let text = input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch action.inputField {
            case "answer": guard !text.isEmpty else { throw APIError.invalidInput(reason: "answer_required") }; body.answer = text
            case "note": body.note = text.isEmpty ? nil : text
            default: break
            }
        }
        let path = action.path.hasPrefix("/") ? String(action.path.dropFirst()) : action.path
        let _: EmptyReply = try await send(action.method, path, body: body)
    }
}

private struct EmptyReply: Decodable {
    init(from decoder: any Decoder) throws {}
}
