import SQLite3
import XCTest
@testable import TodoCore

/// Columns, column/position mutations and project order in the sync engine (ADR 0011/0012, sync 1.2.0).
final class SyncColumnsTests: XCTestCase {
    let pid = UUID(), p2 = UUID(), p3 = UUID(), c1 = UUID(), c2 = UUID(), t1 = UUID(), t2 = UUID()
    var client: APIClient!
    var store: InMemorySyncStore!
    var feed: String = "[]"

    override func setUp() {
        MockURLProtocol.seen = []
        MockURLProtocol.handler = nil
        let tokens = InMemoryTokenStore()
        try? tokens.save("tok")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: URL(string: "http://test.invalid")!, session: URLSession(configuration: config), tokenStore: tokens)
        store = InMemorySyncStore()
    }

    private func project(_ id: UUID, _ name: String, position: Int? = nil, parent: UUID? = nil, version: Int = 1) -> String {
        #"{"seq":1,"entityType":"project","entityID":"\#(id)","kind":"upsert","project":{"id":"\#(id)","parentID":\#(parent.map { "\"\($0)\"" } ?? "null"),"name":"\#(name)","version":\#(version),"position":\#(position.map(String.init) ?? "null"),"isFavorite":false}}"#
    }
    private func column(_ id: UUID, _ name: String, position: Int, isDone: Bool = false, project: UUID? = nil) -> String {
        #"{"seq":2,"entityType":"column","entityID":"\#(id)","kind":"upsert","column":{"id":"\#(id)","projectID":"\#(project ?? pid)","name":"\#(name)","color":null,"isDone":\#(isDone),"position":\#(position),"version":1}}"#
    }
    private func task(_ id: UUID, _ title: String, column: UUID? = nil, pos: Int = 0, status: String = "open") -> String {
        #"{"seq":3,"entityType":"task","entityID":"\#(id)","kind":"upsert","task":{"id":"\#(id)","projectID":"\#(pid)","title":"\#(title)","description":"","status":"\#(status)","version":1,"columnID":\#(column.map { "\"\($0)\"" } ?? "null"),"boardPosition":\#(pos)}}"#
    }
    private func offlineEngine(_ changes: [String]) async throws -> SyncEngine {
        MockURLProtocol.handler = { req in
            if req.url!.path == "/v1/sync/changes" {
                return (200, Data(#"{"changes":[\#(changes.joined(separator: ","))],"cursor":"c5","hasMore":false}"#.utf8))
            }
            return (-1, Data())  // mutations: offline
        }
        let engine = try SyncEngine(client: client, store: store)
        _ = try await engine.sync()
        return engine
    }
    private func mutations() -> [[String: Any]] {
        MockURLProtocol.seen.filter { $0.url?.path == "/v1/sync/mutations" }.map {
            (try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data())) as? [String: Any] ?? [:]
        }
    }

    func testFeedColumnsAreCachedUpdatedAndDeleted() async throws {
        let engine = try await offlineEngine([project(pid, "P"), column(c1, "Todo", position: 0), column(c2, "Done", position: 1, isDone: true), task(t1, "a", column: c1, pos: 2)])
        var snap = await engine.snapshot()
        XCTAssertEqual(snap.columns.map(\.name), ["Todo", "Done"])
        XCTAssertEqual(snap.tasks.first?.columnID, c1); XCTAssertEqual(snap.tasks.first?.boardPosition, 2)
        // Persisted in the store, survives a restart.
        let reopened = try SyncEngine(client: client, store: store)
        let again = await reopened.snapshot()
        XCTAssertEqual(again.columns.count, 2)
        // Incremental delete of one column.
        MockURLProtocol.handler = { _ in (200, Data(#"{"changes":[{"seq":6,"entityType":"column","entityID":"\#(self.c1)","kind":"delete"}],"cursor":"c6","hasMore":false}"#.utf8)) }
        _ = try await engine.sync()
        snap = await engine.snapshot()
        XCTAssertEqual(snap.columns.map(\.name), ["Done"])
    }

    func testProjectDeleteRemovesItsColumns() async throws {
        let engine = try await offlineEngine([project(pid, "P"), column(c1, "Todo", position: 0), project(p2, "Q"), column(c2, "Other", position: 0, project: p2)])
        MockURLProtocol.handler = { _ in (200, Data(#"{"changes":[{"seq":6,"entityType":"project","entityID":"\#(self.pid)","kind":"delete"}],"cursor":"c6","hasMore":false}"#.utf8)) }
        _ = try await engine.sync()
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.columns.map(\.name), ["Other"])
    }

    func testOfflineColumnCreateUpdateDeleteAreOptimisticAndSentInOrder() async throws {
        let engine = try await offlineEngine([project(pid, "P"), column(c1, "Todo", position: 0), column(c2, "Done", position: 1, isDone: true), task(t1, "a", column: c1), task(t2, "b", column: c2, status: "done")])
        let new = UUID()
        _ = try await engine.createColumn(id: new, projectID: pid, name: "Review", color: "#2470E0", index: 1)
        var snap = try await engine.updateColumn(c1, name: "Backlog")
        XCTAssertEqual(snap.columns.map(\.name), ["Backlog", "Review", "Done"])
        XCTAssertEqual(snap.columns.map(\.position), [0, 1, 2])
        snap = try await engine.updateColumn(c2, index: 0)
        XCTAssertEqual(snap.columns.map(\.name), ["Done", "Backlog", "Review"])
        // Deleting a column moves its tasks to the first remaining one (server default).
        snap = try await engine.deleteColumn(c1)
        XCTAssertEqual(snap.columns.map(\.name), ["Done", "Review"])
        XCTAssertEqual(snap.tasks.first { $0.id == t1 }?.columnID, c2)
        XCTAssertEqual(snap.tasks.first { $0.id == t1 }?.status, "done")  // moved into a done column
        XCTAssertEqual(snap.pending, 4)
        // Flush offline: nothing accepted, mutations were attempted in order with their wire fields.
        _ = try await engine.sync()
        let sent = mutations()
        XCTAssertEqual(sent.first?["type"] as? String, "column.create")
        XCTAssertEqual(sent.first?["projectID"] as? String, pid.uuidString)
        XCTAssertEqual(sent.first?["name"] as? String, "Review")
        XCTAssertEqual(sent.first?["color"] as? String, "#2470E0")
        XCTAssertEqual(sent.first?["index"] as? Int, 1)
    }

    func testColumnMutationWireFormatAndConfirmedResult() async throws {
        var sentBodies: [[String: Any]] = []
        let engine = try await offlineEngine([project(pid, "P"), column(c1, "Todo", position: 0)])
        _ = try await engine.updateColumn(c1, name: "Neu", color: "", isDone: true, index: 0)
        _ = try await engine.deleteColumn(c1, toUnassigned: true)
        MockURLProtocol.handler = { [self] req in
            if req.url!.path == "/v1/sync/changes" { return (200, Data(#"{"changes":[],"cursor":"c9","hasMore":false}"#.utf8)) }
            let body = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: Any] ?? [:]
            sentBodies.append(body)
            let type = body["type"] as! String
            let col = type == "column.update" ? #"{"id":"\#(c1)","projectID":"\#(pid)","name":"Neu","color":null,"isDone":true,"position":0,"version":2}"# : "null"
            return (200, Data(#"{"mutationID":"\#(body["mutationID"] as! String)","type":"\#(type)","id":"\#(c1)","deleted":\#(type == "column.delete"),"project":null,"task":null,"column":\#(col),"cursor":"c9"}"#.utf8))
        }
        let report = try await engine.sync()
        XCTAssertEqual(report.pushed, 2)
        XCTAssertEqual(sentBodies[0]["version"] as? Int, 1)  // taken from the confirmed column at send time
        XCTAssertEqual(sentBodies[0]["isDone"] as? Bool, true); XCTAssertEqual(sentBodies[0]["color"] as? String, "")
        XCTAssertEqual(sentBodies[1]["type"] as? String, "column.delete"); XCTAssertEqual(sentBodies[1]["moveTo"] as? String, "none")
        XCTAssertEqual(sentBodies[1]["version"] as? Int, 2)  // chained: version from the update result
        let snap = await engine.snapshot()
        XCTAssertTrue(snap.columns.isEmpty); XCTAssertEqual(snap.pending, 0)
    }

    func testOfflineTaskMoveBetweenColumnsMirrorsServerRules() async throws {
        let engine = try await offlineEngine([project(pid, "P"), column(c1, "Todo", position: 0), column(c2, "Done", position: 1, isDone: true),
            task(t1, "a", column: c1, pos: 0), task(t2, "b", column: c1, pos: 1)])
        var snap = try await engine.moveTask(t1, toColumn: c2)
        let a = snap.tasks.first { $0.id == t1 }!, b = snap.tasks.first { $0.id == t2 }!
        XCTAssertEqual(a.columnID, c2); XCTAssertEqual(a.status, "done"); XCTAssertEqual(a.boardPosition, 0)
        XCTAssertEqual(b.boardPosition, 1)  // like the server, only the target column is renumbered
        // Back out of the done column at index 0 of Todo: reopened, b pushed down.
        snap = try await engine.moveTask(t1, toColumn: c1, index: 0)
        let a2 = snap.tasks.first { $0.id == t1 }!, b2 = snap.tasks.first { $0.id == t2 }!
        XCTAssertEqual(a2.status, "open"); XCTAssertEqual(a2.boardPosition, 0); XCTAssertEqual(b2.boardPosition, 1)
        // To "Ohne Spalte".
        snap = try await engine.moveTask(t2, toColumn: nil)
        XCTAssertNil(snap.tasks.first { $0.id == t2 }?.columnID)
        _ = try await engine.sync()
        let sent = mutations()
        XCTAssertEqual(sent.first?["type"] as? String, "task.move_column")
        XCTAssertEqual(sent.first?["columnID"] as? String, c2.uuidString)
        XCTAssertEqual(sent.first?["version"] as? Int, 1)
    }

    func testProjectOrderFollowsPositionAndOfflineMoveRenumbers() async throws {
        let engine = try await offlineEngine([project(pid, "A", position: 0), project(p2, "B", position: 1), project(p3, "C", position: 2)])
        var snap = await engine.snapshot()
        XCTAssertEqual(snap.projects.map(\.name), ["A", "B", "C"])
        snap = try await engine.moveProject(p3, index: 0)
        XCTAssertEqual(snap.projects.map(\.name), ["C", "A", "B"])
        XCTAssertEqual(snap.projects.map(\.position), [0, 1, 2])
        // Into a parent (reparent): last child of A; carries the version at send time.
        snap = try await engine.moveProject(p2, index: 0, parent: .parent(pid))
        XCTAssertEqual(snap.projects.first { $0.id == p2 }?.parentID, pid)
        XCTAssertEqual(snap.projects.first { $0.id == p2 }?.position, 0)
        var sent: [[String: Any]] = []
        MockURLProtocol.handler = { req in
            if req.url!.path == "/v1/sync/changes" { return (200, Data(#"{"changes":[],"cursor":"c9","hasMore":false}"#.utf8)) }
            let body = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: Any] ?? [:]
            sent.append(body)
            return (200, Data(#"{"mutationID":"\#(body["mutationID"] as! String)","type":"\#(body["type"] as! String)","id":"\#(body["id"] as! String)","deleted":false,"cursor":"c9"}"#.utf8))
        }
        _ = try await engine.sync()
        XCTAssertEqual(sent[0]["type"] as? String, "project.position")
        XCTAssertEqual(sent[0]["index"] as? Int, 0)
        XCTAssertNil(sent[0]["parentID"]); XCTAssertNil(sent[0]["version"])  // personal reorder: no version, no parent
        XCTAssertEqual(sent[1]["parentID"] as? String, pid.uuidString); XCTAssertEqual(sent[1]["version"] as? Int, 1)
        // Move to root.
        sent = []
        _ = try await engine.moveProject(p2, index: 1, parent: .root)
        _ = try await engine.sync()
        XCTAssertEqual(sent.last?["moveToRoot"] as? Bool, true)
    }

    func testProjectDescriptionAndColorAreOptimisticAndClearable() async throws {
        let engine = try await offlineEngine([project(pid, "A")])
        var snap = try await engine.updateProject(pid, ProjectUpdate(description: "hello", color: "#44AD5C"))
        XCTAssertEqual(snap.projects.first?.description, "hello"); XCTAssertEqual(snap.projects.first?.color, "#44AD5C")
        snap = try await engine.updateProject(pid, ProjectUpdate(description: "", color: ""))
        XCTAssertNil(snap.projects.first?.description); XCTAssertNil(snap.projects.first?.color)
        _ = try await engine.sync()
        XCTAssertEqual(mutations().first?["description"] as? String, "hello")
        XCTAssertEqual(mutations().first?["color"] as? String, "#44AD5C")
    }

    func testFavoritesAreAppliedToCachedProjects() async throws {
        let engine = try await offlineEngine([project(pid, "A"), project(p2, "B")])
        try await engine.applyFavorites([FavoriteEntry(projectID: p2, position: 0)])
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.projects.first { $0.id == p2 }?.isFavorite, true)
        XCTAssertEqual(snap.projects.first { $0.id == p2 }?.favoritePosition, 0)
        XCTAssertEqual(snap.projects.first { $0.id == pid }?.isFavorite, false)
    }

    func testOldSQLiteCacheRestartsTheFeedAtC0KeepingTheQueue() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            let store = try SQLiteSyncStore(path: dir)
            var b = SyncBatch()
            b.cursor = "c42"
            b.queueUpserts = [QueuedMutation(mutation: SyncMutation(type: .projectCreate, id: pid, name: "Q"), order: 1, chained: false)]
            try store.commit(b)
            XCTAssertEqual(try store.load().cursor, "c42")
        }
        // Simulate a cache from before columns existed: no schema marker.
        do {
            let raw = try SQLiteSyncStore(path: dir)
            _ = raw
        }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir, &handle), SQLITE_OK)
        sqlite3_exec(handle, "DELETE FROM meta WHERE key = 'schema'", nil, nil, nil)
        sqlite3_close(handle)
        let reopened = try SQLiteSyncStore(path: dir)
        let state = try reopened.load()
        XCTAssertEqual(state.cursor, "c0")
        XCTAssertEqual(state.queue.count, 1)
        // A second open keeps a cursor written after the migration.
        var b = SyncBatch(); b.cursor = "c7"; try reopened.commit(b)
        XCTAssertEqual(try SQLiteSyncStore(path: dir).load().cursor, "c7")
    }

    func testUnknownColumnTolerantDecodingStillSkipsUnknownEntityTypes() throws {
        let page = try JSONDecoder().decode(SyncChanges.self, from: Data(#"{"changes":[{"seq":1,"entityType":"widget","entityID":"\#(pid)","kind":"upsert"},\#(column(c1, "X", position: 0))],"cursor":"c2","hasMore":false}"#.utf8))
        XCTAssertEqual(page.changes.count, 1); XCTAssertEqual(page.changes.first?.column?.name, "X")
    }
}
