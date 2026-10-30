import Foundation

// MARK: Project board columns (ADR 0011, contracts/project-columns.yaml)
// Shapes follow `contracts/project-columns.yaml` (main repository). Extra task fields (`columnID`, `boardPosition`,
// `planning`) are ignored by `TodoTask`; the sync feed's `column` entries are skipped by `SyncChanges`.

/// A board column of exactly one project. Columns are never inherited by sub-projects.
public struct ProjectColumn: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public let projectID: UUID
    public var name: String
    /// `#RRGGBB` or nil.
    public var color: String?
    /// Moving a task in completes it; moving it out reopens it.
    public var isDone: Bool
    public var position: Int
    public var version: Int

    public init(id: UUID, projectID: UUID, name: String, color: String? = nil, isDone: Bool = false, position: Int = 0, version: Int = 1) {
        self.id = id; self.projectID = projectID; self.name = name; self.color = color
        self.isDone = isDone; self.position = position; self.version = version
    }
}

/// One column of the board response. Virtual status columns (project without own columns) have no `id`, only a `key`.
public struct BoardColumn: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID?
    public let key: String?
    public var name: String
    public var color: String?
    public var isDone: Bool
    public var position: Int
    public var version: Int?
    public var tasks: [TodoTask]

    public init(id: UUID?, key: String? = nil, name: String, color: String? = nil, isDone: Bool = false, position: Int = 0, version: Int? = nil, tasks: [TodoTask] = []) {
        self.id = id; self.key = key; self.name = name; self.color = color
        self.isDone = isDone; self.position = position; self.version = version; self.tasks = tasks
    }

    /// Stable identity for lists: the column id or the status key.
    public var stableID: String { id?.uuidString ?? key ?? name }
    /// True for a column the user can edit (has its own id).
    public var isReal: Bool { id != nil }
}

public struct Board: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case status, columns }
    public let projectID: UUID
    public let mode: String
    public var columns: [BoardColumn]
    /// Tasks without a column ("Ohne Spalte"); empty in status mode.
    public var unassigned: [TodoTask]

    public init(projectID: UUID, mode: String, columns: [BoardColumn], unassigned: [TodoTask] = []) {
        self.projectID = projectID; self.mode = mode; self.columns = columns; self.unassigned = unassigned
    }

    public var hasOwnColumns: Bool { mode == Mode.columns.rawValue }
}

struct CreateColumnBody: Encodable { let name: String; let color: String?; let isDone: Bool?; let index: Int? }
struct UpdateColumnBody: Encodable {
    let version: Int
    let name: String?
    let color: String?
    let isDone: Bool?
    let index: Int?
}
struct ColumnTemplateBody: Encodable { let source: String }
struct MoveTaskBody: Encodable {
    let version: Int
    let columnID: UUID?
    let index: Int?
    // `columnID: null` means "Ohne Spalte" and must be sent explicitly.
    enum CodingKeys: String, CodingKey { case version, columnID, index }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(columnID, forKey: .columnID)
        try c.encodeIfPresent(index, forKey: .index)
    }
}

extension APIClient {
    /// Board of a project. Throws `APIError.notFound` on servers without board support.
    public func board(projectID: UUID) async throws -> Board {
        try await send("GET", "v1/projects/\(projectID.uuidString.lowercased())/board")
    }

    public func columns(projectID: UUID) async throws -> [ProjectColumn] {
        try await send("GET", "v1/projects/\(projectID.uuidString.lowercased())/columns")
    }

    public func createColumn(projectID: UUID, name: String, color: String? = nil, isDone: Bool? = nil, index: Int? = nil) async throws -> ProjectColumn {
        try await send("POST", "v1/projects/\(projectID.uuidString.lowercased())/columns", body: CreateColumnBody(name: name, color: color, isDone: isDone, index: index))
    }

    /// `color == ""` removes the color. `index` reorders.
    public func updateColumn(projectID: UUID, columnID: UUID, version: Int, name: String? = nil, color: String? = nil, isDone: Bool? = nil, index: Int? = nil) async throws -> ProjectColumn {
        try await send("PATCH", "v1/projects/\(projectID.uuidString.lowercased())/columns/\(columnID.uuidString.lowercased())",
            body: UpdateColumnBody(version: version, name: name, color: color, isDone: isDone, index: index))
    }

    /// Deletes a column; its tasks go to `moveTo` (nil = the first remaining column) or, with `toUnassigned`, to "Ohne Spalte".
    public func deleteColumn(projectID: UUID, columnID: UUID, moveTo: UUID? = nil, toUnassigned: Bool = false, version: Int? = nil) async throws {
        var query: [URLQueryItem] = []
        if toUnassigned { query.append(.init(name: "moveTo", value: "none")) }
        else if let moveTo { query.append(.init(name: "moveTo", value: moveTo.uuidString.lowercased())) }
        if let version { query.append(.init(name: "version", value: String(version))) }
        let request = try makeRequest("DELETE", "v1/projects/\(projectID.uuidString.lowercased())/columns/\(columnID.uuidString.lowercased())", query: query, body: nil, auth: true)
        _ = try await performWithStatus(request)
    }

    /// Creates the columns from a template: `"status"` (Offen / In Arbeit / Erledigt) or a readable project's id.
    public func applyColumnTemplate(projectID: UUID, source: String) async throws -> [ProjectColumn] {
        try await send("POST", "v1/projects/\(projectID.uuidString.lowercased())/columns/template", body: ColumnTemplateBody(source: source))
    }

    /// Moves a task into a column (nil = "Ohne Spalte") at a 0-based index; returns the updated task.
    public func moveTask(_ id: UUID, version: Int, toColumn columnID: UUID?, index: Int? = nil) async throws -> TodoTask {
        try await send("PUT", "v1/tasks/\(id.uuidString.lowercased())/column", body: MoveTaskBody(version: version, columnID: columnID, index: index))
    }
}

extension Board {
    /// Builds the board of a project from synced data (columns and tasks of the sync store), the same shape as
    /// `GET /v1/projects/:id/board`: own columns (plus the tasks without column) or, without columns, virtual status
    /// columns. `statusNames` maps `open`/`in_progress`/`in_review`/`done` to the display names of the virtual columns.
    public static func local(
        projectID: UUID, columns: [ProjectColumn], tasks: [TodoTask], statusNames: [String: String] = [:]
    ) -> Board {
        let mine = tasks.filter { $0.projectID == projectID }
        let own = columns.filter { $0.projectID == projectID }.sorted { ($0.position, $0.id.uuidString) < ($1.position, $1.id.uuidString) }
        func ordered(_ list: [TodoTask]) -> [TodoTask] {
            list.sorted { ($0.boardPosition, $0.id.uuidString) < ($1.boardPosition, $1.id.uuidString) }
        }
        if own.isEmpty {
            let defs: [(String, Bool)] = [("open", false), ("in_progress", false), ("in_review", false), ("done", true)]
            let cols = defs.enumerated().map { i, d in
                BoardColumn(
                    id: nil, key: d.0, name: statusNames[d.0] ?? d.0, isDone: d.1, position: i,
                    tasks: ordered(mine.filter { $0.status == d.0 }))
            }
            return Board(projectID: projectID, mode: Mode.status.rawValue, columns: cols)
        }
        let ids = Set(own.map(\.id))
        let cols = own.map { c in
            BoardColumn(
                id: c.id, name: c.name, color: c.color, isDone: c.isDone, position: c.position, version: c.version,
                tasks: ordered(mine.filter { $0.columnID == c.id }))
        }
        // A task pointing at a column we do not know (yet) is shown as unassigned rather than lost.
        return Board(
            projectID: projectID, mode: Mode.columns.rawValue, columns: cols,
            unassigned: ordered(mine.filter { $0.columnID == nil || !ids.contains($0.columnID!) }))
    }
}
