import Foundation

// MARK: Per-account project state, project comments, activity feed, runner lists
// (ADR 0012, contracts/project-state.yaml and the device/job lists of contracts/agents.yaml)

/// One favourite of the account (dense `position` 0..n-1).
public struct FavoriteEntry: Codable, Sendable, Equatable {
    public let projectID: UUID
    public let position: Int
    public init(projectID: UUID, position: Int) { self.projectID = projectID; self.position = position }
}

struct FavoritesResponse: Codable, Sendable { let items: [FavoriteEntry] }

/// The account's display settings for one project. `revision` 0 = never written (defaults).
public struct ProjectDisplayPrefs: Codable, Sendable, Equatable {
    public enum View: String, Codable, Sendable, CaseIterable { case list, board }
    public enum Sort: String, Codable, Sendable, CaseIterable { case manual, title, due, priority }
    public enum Grouping: String, Codable, Sendable, CaseIterable { case none, column, priority, due }

    public var projectID: UUID
    public var view: String
    public var sort: String
    public var grouping: String
    public var showCompleted: Bool
    public var isFavorite: Bool
    public var favoritePosition: Int?
    public var revision: Int
    public var updatedAt: Date?

    /// Server defaults: `list`, `manual`, `column`, completed shown.
    public init(
        projectID: UUID, view: String = View.list.rawValue, sort: String = Sort.manual.rawValue,
        grouping: String = Grouping.column.rawValue, showCompleted: Bool = true, isFavorite: Bool = false,
        favoritePosition: Int? = nil, revision: Int = 0, updatedAt: Date? = nil
    ) {
        self.projectID = projectID; self.view = view; self.sort = sort; self.grouping = grouping
        self.showCompleted = showCompleted; self.isFavorite = isFavorite; self.favoritePosition = favoritePosition
        self.revision = revision; self.updatedAt = updatedAt
    }

    public var viewMode: View { View(rawValue: view) ?? .list }
    public var sortMode: Sort { Sort(rawValue: sort) ?? .manual }
    public var groupMode: Grouping { Grouping(rawValue: grouping) ?? .column }
}

struct ProjectPrefsList: Codable, Sendable { let items: [ProjectDisplayPrefs] }

/// Partial change of the display settings (nil = unchanged).
public struct ProjectPrefsPatch: Codable, Sendable, Equatable {
    public var view: String?
    public var sort: String?
    public var grouping: String?
    public var showCompleted: Bool?
    public init(view: String? = nil, sort: String? = nil, grouping: String? = nil, showCompleted: Bool? = nil) {
        self.view = view; self.sort = sort; self.grouping = grouping; self.showCompleted = showCompleted
    }
    public var isEmpty: Bool { view == nil && sort == nil && grouping == nil && showCompleted == nil }

    /// Later changes win field by field.
    public func merged(with later: ProjectPrefsPatch) -> ProjectPrefsPatch {
        ProjectPrefsPatch(
            view: later.view ?? view, sort: later.sort ?? sort, grouping: later.grouping ?? grouping,
            showCompleted: later.showCompleted ?? showCompleted)
    }

    public func applied(to prefs: ProjectDisplayPrefs) -> ProjectDisplayPrefs {
        var p = prefs
        if let view { p.view = view }
        if let sort { p.sort = sort }
        if let grouping { p.grouping = grouping }
        if let showCompleted { p.showCompleted = showCompleted }
        return p
    }
}

struct PrefsPatchBody: Encodable {
    let revision: Int
    let patch: ProjectPrefsPatch
    enum CodingKeys: String, CodingKey { case revision, view, sort, grouping, showCompleted }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(revision, forKey: .revision)
        try c.encodeIfPresent(patch.view, forKey: .view)
        try c.encodeIfPresent(patch.sort, forKey: .sort)
        try c.encodeIfPresent(patch.grouping, forKey: .grouping)
        try c.encodeIfPresent(patch.showCompleted, forKey: .showCompleted)
    }
}

/// How a project position change treats the parent. `.keep` is a purely personal reorder.
public enum ProjectParentChange: Sendable, Equatable {
    case keep
    case root
    case parent(UUID)
}

struct ProjectPositionBody: Encodable {
    let index: Int
    let change: ProjectParentChange
    let version: Int?
    enum CodingKeys: String, CodingKey { case index, parentID, version }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        switch change {
        case .keep: break
        case .root: try c.encodeNil(forKey: .parentID)
        case .parent(let id): try c.encode(id, forKey: .parentID)
        }
        try c.encodeIfPresent(version, forKey: .version)
    }
}

public struct ProjectComment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public let authorID: UUID
    public let authorName: String?
    public let body: String
    public let version: Int
    public let createdAt: Date?
}

public struct ActivityItem: Codable, Sendable, Equatable, Identifiable {
    /// `task` or `project`.
    public let source: String
    public let id: UUID
    public let projectID: UUID
    public let projectName: String
    public let taskID: UUID?
    public let taskTitle: String?
    public let sequence: Int
    /// `Person`, `Integration` or `Run`.
    public let actorType: String
    public let actorID: UUID
    public let actorName: String?
    /// For example `task.created`, `comment.created`, `agent.released`; unknown kinds must stay displayable.
    public let kind: String
    public let subjectID: UUID?
    public let createdAt: Date?
}

public struct ActivityFeed: Codable, Sendable, Equatable {
    public let items: [ActivityItem]
    public let nextCursor: String?
}

public struct RunnerBinding: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public let deviceID: UUID
    public let repositoryKey: String
    public let label: String
}

public struct RunnerDevice: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let label: String
    public let paired: Bool
    public let revokedAt: Date?
    public let activeRunCount: Int
    public let bindings: [RunnerBinding]
}

public struct AgentJobResult: Codable, Sendable, Equatable {
    public let summary: String
    public let references: [String]
    public let checks: [String]
    public let limitations: [String]
}

public struct AgentJob: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let taskID: UUID
    public let projectID: UUID
    /// `clarify` or `implement`.
    public let mode: String
    /// `queued`, `claimed`, `running`, `waiting_for_answer`, `awaiting_review`, `succeeded`, `failed`, `cancelled`.
    public let state: String
    public let progress: String?
    public let result: AgentJobResult?
}

public struct AgentJobListItem: Codable, Sendable, Equatable, Identifiable {
    public let job: AgentJob
    public let taskTitle: String
    public let projectName: String
    public let createdAt: Date?
    public var id: UUID { job.id }
}

public struct AgentJobList: Codable, Sendable, Equatable {
    public let items: [AgentJobListItem]
    public let nextCursor: String?
}

private struct CommentBodyDTO: Encodable { let body: String }
private struct CommentEditDTO: Encodable { let body: String; let version: Int }
private struct VersionDTO: Encodable { let version: Int }
private struct FavoriteBody: Encodable { let index: Int }

extension APIClient {
    private func pid(_ id: UUID) -> String { id.uuidString.lowercased() }

    // MARK: Favourites

    public func favorites() async throws -> [FavoriteEntry] {
        (try await send("GET", "v1/me/favorites") as FavoritesResponse).items
    }

    /// Idempotent; `index` nil = end of the list. Returns the new favourite list.
    public func setFavorite(_ id: UUID, index: Int? = nil) async throws -> [FavoriteEntry] {
        let r: FavoritesResponse = try await send(
            "PUT", "v1/me/favorites/\(pid(id))", body: index.map { FavoriteBody(index: $0) })
        return r.items
    }

    public func removeFavorite(_ id: UUID) async throws {
        try await sendNoContent("DELETE", "v1/me/favorites/\(pid(id))")
    }

    // MARK: Display preferences

    /// Only projects that were written at least once; everything else uses the defaults.
    public func projectPrefs() async throws -> [ProjectDisplayPrefs] {
        (try await send("GET", "v1/me/project-prefs") as ProjectPrefsList).items
    }

    public func projectPrefs(for id: UUID) async throws -> ProjectDisplayPrefs {
        try await send("GET", "v1/me/project-prefs/\(pid(id))")
    }

    /// `revision` must be the stored one (409 `revision_conflict` = `APIError.conflict`). Every write adds one.
    public func patchProjectPrefs(_ id: UUID, revision: Int, _ patch: ProjectPrefsPatch) async throws -> ProjectDisplayPrefs {
        try await send("PATCH", "v1/me/project-prefs/\(pid(id))", body: PrefsPatchBody(revision: revision, patch: patch))
    }

    // MARK: Project order

    /// Places the project among its siblings (own order). With `.root`/`.parent` the shared tree changes too, which
    /// needs `version` and the `manage` role.
    public func putProjectPosition(_ id: UUID, index: Int, parent: ProjectParentChange = .keep, version: Int? = nil) async throws -> Project {
        try await send("PUT", "v1/projects/\(pid(id))/position", body: ProjectPositionBody(index: index, change: parent, version: version))
    }

    // MARK: Project comments

    public func projectComments(_ projectID: UUID) async throws -> [ProjectComment] {
        try await send("GET", "v1/projects/\(pid(projectID))/comments")
    }

    public func addProjectComment(_ projectID: UUID, body: String, idempotencyKey: UUID = UUID()) async throws -> ProjectComment {
        try await send(
            "POST", "v1/projects/\(pid(projectID))/comments", body: CommentBodyDTO(body: body),
            headers: ["Idempotency-Key": idempotencyKey.uuidString])
    }

    public func editProjectComment(_ projectID: UUID, id: UUID, version: Int, body: String) async throws -> ProjectComment {
        try await send("PATCH", "v1/projects/\(pid(projectID))/comments/\(pid(id))", body: CommentEditDTO(body: body, version: version))
    }

    public func deleteProjectComment(_ projectID: UUID, id: UUID, version: Int) async throws {
        try await sendNoContent("DELETE", "v1/projects/\(pid(projectID))/comments/\(pid(id))", body: VersionDTO(version: version))
    }

    // MARK: Activity

    /// Newest first across all readable projects (or one). Pass `nextCursor` as `before` for the next page.
    public func activityFeed(projectID: UUID? = nil, limit: Int? = nil, before: String? = nil) async throws -> ActivityFeed {
        var query: [URLQueryItem] = []
        if let projectID { query.append(.init(name: "projectID", value: pid(projectID))) }
        if let limit { query.append(.init(name: "limit", value: String(limit))) }
        if let before { query.append(.init(name: "before", value: before)) }
        return try await send("GET", "v1/activity", query: query)
    }

    // MARK: Runner devices and jobs

    public func agentDevices() async throws -> [RunnerDevice] {
        try await send("GET", "v1/agents/devices")
    }

    /// Jobs of the account's own projects (403 for a visible foreign project). Newest release first.
    public func agentJobs(projectID: UUID? = nil, taskID: UUID? = nil, state: String? = nil, limit: Int? = nil, before: String? = nil) async throws -> AgentJobList {
        var query: [URLQueryItem] = []
        if let projectID { query.append(.init(name: "projectID", value: pid(projectID))) }
        if let taskID { query.append(.init(name: "taskID", value: pid(taskID))) }
        if let state { query.append(.init(name: "state", value: state)) }
        if let limit { query.append(.init(name: "limit", value: String(limit))) }
        if let before { query.append(.init(name: "before", value: before)) }
        return try await send("GET", "v1/agents/jobs", query: query)
    }
}
