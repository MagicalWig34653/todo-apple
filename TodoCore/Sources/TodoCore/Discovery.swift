import Foundation

// MARK: Labels and search (contracts/discovery.yaml)

public struct TaskLabel: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let version: Int
    public init(id: UUID, name: String, version: Int = 1) { self.id = id; self.name = name; self.version = version }
}

public struct Page<Item: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let items: [Item]
    public let nextCursor: String?
    public init(items: [Item], nextCursor: String? = nil) { self.items = items; self.nextCursor = nextCursor }
}

public struct SearchHit: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case project, task }
    public let kind: Kind
    public let id: UUID
    public let project: Project
    public let task: TodoTask?
}

struct LabelBody: Encodable { let name: String; let version: Int? }

extension APIClient {
    public func labels(limit: Int? = nil, cursor: String? = nil) async throws -> Page<TaskLabel> {
        try await send("GET", "v1/labels", query: Self.paging(limit, cursor))
    }

    public func createLabel(name: String) async throws -> TaskLabel {
        try await send("POST", "v1/labels", body: LabelBody(name: name, version: nil))
    }

    public func renameLabel(_ id: UUID, version: Int, name: String) async throws -> TaskLabel {
        try await send("PATCH", "v1/labels/\(id.uuidString)", body: LabelBody(name: name, version: version))
    }

    public func deleteLabel(_ id: UUID) async throws {
        try await sendNoContent("DELETE", "v1/labels/\(id.uuidString)")
    }

    public func labels(taskID: UUID) async throws -> Page<TaskLabel> {
        try await send("GET", "v1/tasks/\(taskID.uuidString)/labels")
    }

    public func addLabel(_ labelID: UUID, toTask taskID: UUID) async throws {
        try await sendNoContent("PUT", "v1/tasks/\(taskID.uuidString)/labels/\(labelID.uuidString)")
    }

    public func removeLabel(_ labelID: UUID, fromTask taskID: UUID) async throws {
        try await sendNoContent("DELETE", "v1/tasks/\(taskID.uuidString)/labels/\(labelID.uuidString)")
    }

    /// Full-text search over visible projects and tasks, optionally narrowed by project, label and status.
    public func search(
        _ q: String? = nil, projectID: UUID? = nil, labelID: UUID? = nil, status: TaskStatus? = nil,
        limit: Int? = nil, cursor: String? = nil
    ) async throws -> Page<SearchHit> {
        var query = Self.paging(limit, cursor)
        if let q, !q.isEmpty { query.append(.init(name: "q", value: q)) }
        if let projectID { query.append(.init(name: "projectID", value: projectID.uuidString)) }
        if let labelID { query.append(.init(name: "labelID", value: labelID.uuidString)) }
        if let status { query.append(.init(name: "status", value: status.rawValue)) }
        return try await send("GET", "v1/search", query: query)
    }

    static func paging(_ limit: Int?, _ cursor: String?) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let limit { items.append(.init(name: "limit", value: String(limit))) }
        if let cursor { items.append(.init(name: "cursor", value: cursor)) }
        return items
    }
}
