import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persistent `SyncStore` backed by one SQLite file (WAL). Entities and queue entries are stored as JSON rows;
/// SQL is used for atomicity (one transaction per `commit`), not for querying. Pass `":memory:"` for tests.
public final class SQLiteSyncStore: SyncStore, @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SyncStoreError.openFailed(message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 5000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, json BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, json BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS queue (mutation_id TEXT PRIMARY KEY, ord INTEGER NOT NULL, json BLOB NOT NULL);
            """)
    }

    deinit { sqlite3_close(db) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: SyncStore

    public func load() throws -> SyncState {
        try lock.withLock {
            var state = SyncState()
            for (_, data) in try rows("SELECT id, json FROM projects") {
                let p = try decode(Project.self, data)
                state.projects[p.id] = p
            }
            for (_, data) in try rows("SELECT id, json FROM tasks") {
                let t = try decode(TodoTask.self, data)
                state.tasks[t.id] = t
            }
            for (_, data) in try rows("SELECT mutation_id, json FROM queue ORDER BY ord") {
                state.queue.append(try decode(QueuedMutation.self, data))
            }
            if let cursor = try text("SELECT value FROM meta WHERE key = 'cursor'") { state.cursor = cursor }
            return state
        }
    }

    public func commit(_ batch: SyncBatch) throws {
        try lock.withLock {
            try exec("BEGIN IMMEDIATE")
            do {
                if batch.replaceEntities { try exec("DELETE FROM projects; DELETE FROM tasks;") }
                for p in batch.projectUpserts { try upsert("projects", p.id.uuidString, Self.encoder.encode(p)) }
                for t in batch.taskUpserts { try upsert("tasks", t.id.uuidString, Self.encoder.encode(t)) }
                for id in batch.projectDeletes { try run("DELETE FROM projects WHERE id = ?", [.text(id.uuidString)]) }
                for id in batch.taskDeletes { try run("DELETE FROM tasks WHERE id = ?", [.text(id.uuidString)]) }
                if let cursor = batch.cursor {
                    try run("INSERT INTO meta (key, value) VALUES ('cursor', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(cursor)])
                }
                for id in batch.queueRemovals { try run("DELETE FROM queue WHERE mutation_id = ?", [.text(id.uuidString)]) }
                for q in batch.queueUpserts {
                    try run(
                        "INSERT INTO queue (mutation_id, ord, json) VALUES (?, ?, ?) ON CONFLICT(mutation_id) DO UPDATE SET ord = excluded.ord, json = excluded.json",
                        [.text(q.id.uuidString), .int(q.order), .blob(Self.encoder.encode(q))])
                }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    public func wipe() throws {
        try lock.withLock {
            try exec("DELETE FROM projects; DELETE FROM tasks; DELETE FROM queue; DELETE FROM meta;")
        }
    }

    // MARK: SQLite helpers

    private enum Value { case text(String), int(Int), blob(Data) }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try Self.decoder.decode(T.self, from: data) } catch { throw SyncStoreError.corrupt(String(describing: error)) }
    }

    private func upsert(_ table: String, _ id: String, _ json: Data) throws {
        try run(
            "INSERT INTO \(table) (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
            [.text(id), .blob(json)])
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(error)
            throw SyncStoreError.writeFailed(message)
        }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SyncStoreError.writeFailed(String(cString: sqlite3_errmsg(db)))
        }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, index, s, -1, sqliteTransient)
            case .int(let n): sqlite3_bind_int64(stmt, index, Int64(n))
            case .blob(let d):
                _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(d.count), sqliteTransient) }
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        let stmt = try prepare(sql, values)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SyncStoreError.writeFailed(String(cString: sqlite3_errmsg(db))) }
    }

    private func rows(_ sql: String) throws -> [(String, Data)] {
        let stmt = try prepare(sql, [])
        defer { sqlite3_finalize(stmt) }
        var out: [(String, Data)] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SyncStoreError.corrupt(String(cString: sqlite3_errmsg(db))) }
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_bytes(stmt, 1))
            let data = count > 0 ? Data(bytes: sqlite3_column_blob(stmt, 1), count: count) : Data()
            out.append((key, data))
        }
        return out
    }

    private func text(_ sql: String) throws -> String? {
        let stmt = try prepare(sql, [])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }
}
