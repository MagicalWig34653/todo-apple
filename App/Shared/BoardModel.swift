import SwiftUI
import TodoCore

/// Drag payload for cards and columns (one Transferable type; `kind` tells them apart).
struct BoardDrag: Codable, Transferable, Hashable {
    enum Kind: String, Codable { case task, column }
    let kind: Kind
    let id: UUID
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .json) }
}

/// Board of one project. Loads `GET /v1/projects/:id/board`; on servers without board support (404) or without any
/// cache it derives virtual status columns locally from the synced tasks, where a drop changes the task status.
/// Moves are optimistic and reloaded from the server afterwards.
@MainActor @Observable
final class BoardModel {
    let projectID: UUID
    private(set) var board: Board?
    /// True when the server has no board endpoint (columns cannot be edited; status columns are derived locally).
    private(set) var unsupported = false
    private(set) var loadFailed = false

    init(projectID: UUID) { self.projectID = projectID }

    var hasOwnColumns: Bool { board?.hasOwnColumns == true }

    /// Columns shown on the board, "Ohne Spalte" first if it has tasks.
    var columns: [BoardColumn] {
        guard let board else { return [] }
        var result = board.columns
        if !board.unassigned.isEmpty || (board.hasOwnColumns && result.isEmpty) {
            result.insert(BoardColumn(id: nil, key: "unassigned", name: "", position: -1, tasks: board.unassigned), at: 0)
        }
        return result
    }

    static func isUnassigned(_ c: BoardColumn) -> Bool { c.key == "unassigned" }

    // MARK: Loading

    func load(_ app: AppModel) async {
        guard let client = app.client else { return }
        if unsupported { board = Self.localBoard(projectID, app.tasks); return }
        do {
            board = try await client.board(projectID: projectID)
            loadFailed = false
        } catch APIError.notFound {
            unsupported = true
            board = Self.localBoard(projectID, app.tasks)
        } catch {
            loadFailed = true
            if board == nil { board = Self.localBoard(projectID, app.tasks) }
        }
    }

    static func localBoard(_ projectID: UUID, _ tasks: [TodoTask]) -> Board {
        let mine = tasks.filter { $0.projectID == projectID }
        let defs: [(TaskStatus, String, Bool)] = [(.open, "board.status.open", false), (.inProgress, "board.status.inProgress", false), (.inReview, "board.status.inReview", false), (.done, "board.status.done", true)]
        let cols = defs.enumerated().map { i, d in
            BoardColumn(id: nil, key: d.0.rawValue, name: String(localized: String.LocalizationValue(d.1)), isDone: d.2, position: i,
                tasks: mine.filter { $0.status == d.0.rawValue })
        }
        return Board(projectID: projectID, mode: Board.Mode.status.rawValue, columns: cols)
    }

    // MARK: Moving

    /// Moves a card to `column` at `index` (nil = end).
    func move(taskID: UUID, to column: BoardColumn, index: Int?, _ app: AppModel) async {
        guard var board, let client = app.client else { return }
        // Locate and remove locally (optimistic).
        var task: TodoTask?
        for i in board.columns.indices { if let j = board.columns[i].tasks.firstIndex(where: { $0.id == taskID }) { task = board.columns[i].tasks.remove(at: j) } }
        if let j = board.unassigned.firstIndex(where: { $0.id == taskID }) { task = board.unassigned.remove(at: j) }
        guard let task else { return }
        let virtualStatus = !board.hasOwnColumns
        if Self.isUnassigned(column) {
            board.unassigned.insert(task, at: min(index ?? board.unassigned.count, board.unassigned.count))
        } else if let k = board.columns.firstIndex(where: { $0.stableID == column.stableID }) {
            board.columns[k].tasks.insert(task, at: min(index ?? board.columns[k].tasks.count, board.columns[k].tasks.count))
        }
        self.board = board
        do {
            if virtualStatus || unsupported {
                // Status mode: a drop changes the status (works offline through the sync queue).
                if let key = column.key, let status = TaskStatus(rawValue: key), task.status != key {
                    _ = await app.updateTask(task, TaskUpdate(status: status))
                }
            } else {
                let updated = try await client.moveTask(taskID, version: task.version, toColumn: Self.isUnassigned(column) ? nil : column.id, index: index)
                app.apply(updated)
            }
        } catch { await app.handle(error) }
        await load(app)
    }

    // MARK: Column management

    func addColumn(name: String, _ app: AppModel) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let client = app.client, !name.isEmpty, !unsupported else { return }
        do { _ = try await client.createColumn(projectID: projectID, name: name) } catch { await app.handle(error) }
        await load(app)
    }

    func applyStatusTemplate(_ app: AppModel) async {
        guard let client = app.client, !unsupported else { return }
        do { _ = try await client.applyColumnTemplate(projectID: projectID, source: "status") } catch { await app.handle(error) }
        await load(app)
    }

    func update(_ column: BoardColumn, name: String? = nil, color: String? = nil, isDone: Bool? = nil, index: Int? = nil, _ app: AppModel) async {
        guard let client = app.client, let id = column.id, let version = column.version else { return }
        do { _ = try await client.updateColumn(projectID: projectID, columnID: id, version: version, name: name, color: color, isDone: isDone, index: index) }
        catch { await app.handle(error) }
        await load(app)
    }

    func delete(_ column: BoardColumn, _ app: AppModel) async {
        guard let client = app.client, let id = column.id else { return }
        do { try await client.deleteColumn(projectID: projectID, columnID: id, version: column.version) } catch { await app.handle(error) }
        await load(app)
    }

    /// Reorders a column before/at the position of `target`.
    func moveColumn(_ id: UUID, before target: BoardColumn, _ app: AppModel) async {
        guard let board, let from = board.columns.firstIndex(where: { $0.id == id }),
            let to = board.columns.firstIndex(where: { $0.stableID == target.stableID }), from != to,
            let column = board.columns.first(where: { $0.id == id }) else { return }
        var copy = board
        copy.columns.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        self.board = copy
        await update(column, index: to, app)
    }

    /// Adds a task to a column: created on the server and moved into the column; offline it lands in the project without column.
    func addTask(title: String, in column: BoardColumn, _ app: AppModel) async {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        if let client = app.client, !unsupported, hasOwnColumns, let columnID = column.id {
            do {
                let created = try await client.createTask(projectID: projectID, title: title)
                let moved = try await client.moveTask(created.id, version: created.version, toColumn: columnID)
                app.apply(moved)
                await load(app)
                return
            } catch APIError.transport {} catch { await app.handle(error); return }
        }
        guard let id = await app.createTask(projectID: projectID, title: title) else { return }
        if let key = column.key, let status = TaskStatus(rawValue: key), status != .open, let t = app.tasks.first(where: { $0.id == id }) {
            _ = await app.updateTask(t, TaskUpdate(status: status))
        }
        await load(app)
    }
}

extension Color {
    /// `#RRGGBB` to a color; nil for anything else.
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static let columnPalette: [(name: String, hex: String)] = [
        ("red", "#DB4C3F"), ("orange", "#EB8909"), ("yellow", "#C2A61A"), ("green", "#44AD5C"),
        ("teal", "#29ABAB"), ("blue", "#2470E0"), ("violet", "#6B59D9"), ("pink", "#E05291"),
    ]
}
