import Foundation
import XCTest

@testable import TodoCore

/// Opt-in: runs the sync engine against a real backend (same fixture/virtual passkeys as `LiveEtappe2Tests`).
/// Skipped unless `TODO_LIVE_BASE_URL` is set; needs a backend with a fresh database (bootstrap token unused).
extension LiveEtappe2Tests {
    private func sqliteStore() throws -> (SQLiteSyncStore, String) {
        let path = NSTemporaryDirectory() + "live-sync-\(UUID().uuidString).sqlite"
        return (try SQLiteSyncStore(path: path), path)
    }

    private func cleanup(_ path: String) { for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + ext) } }

    func testSyncEngineOfflineQueueTwoReplicasConflictAndTombstone() async throws {
        let f = try await fixture()
        let (storeA, pathA) = try sqliteStore(); defer { cleanup(pathA) }
        let storeB = InMemorySyncStore()
        let a = try SyncEngine(client: f.admin, store: storeA, pageSize: 3)
        let b = try SyncEngine(client: APIClient(baseURL: f.admin.baseURL, tokenStore: f.adminStore), store: storeB, pageSize: 3)

        // Replica A creates offline-style (queue only), then syncs.
        let pid = UUID(), tid = UUID()
        try await a.createProject(id: pid, name: "Engine \(f.suffix)")
        let queued = try await a.createTask(id: tid, projectID: pid, title: "Aus der Warteschlange")
        XCTAssertEqual(queued.pending, 2)
        XCTAssertTrue(queued.tasks.contains { $0.id == tid })
        let r1 = try await a.sync()
        XCTAssertEqual(r1.pushed, 2)
        XCTAssertFalse(r1.offline)
        let afterA = await a.snapshot()
        XCTAssertEqual(afterA.pending, 0)
        let serverTask = try await f.admin.tasks(projectID: pid)
        XCTAssertEqual(serverTask.map(\.id), [tid], "server has exactly one task (no duplicate from retries)")

        // Replica B pulls it through the feed (paged with size 3).
        let rb = try await b.sync()
        XCTAssertTrue(rb.pulled > 0)
        var snapB = await b.snapshot()
        XCTAssertEqual(snapB.tasks.first { $0.id == tid }?.title, "Aus der Warteschlange")
        XCTAssertTrue(snapB.projects.contains { $0.id == pid })

        // Conflict: A edits and syncs; B (not yet synced) edits the same task from the stale version.
        try await a.updateTask(tid, TaskUpdate(title: "Von A"))
        _ = try await a.sync()
        try await b.updateTask(tid, TaskUpdate(title: "Von B", status: .done))
        let rc = try await b.sync()
        XCTAssertEqual(rc.conflicts, 1)
        snapB = await b.snapshot()
        XCTAssertEqual(snapB.conflicts.first?.reason, "version_conflict")
        XCTAssertEqual(snapB.tasks.first { $0.id == tid }?.title, "Von A", "server state shown while in conflict")
        try await b.resolveConflict(try XCTUnwrap(snapB.conflicts.first).id, keepMine: true)
        let rk = try await b.sync()
        XCTAssertEqual(rk.pushed, 1)
        let finalServer = try await f.admin.tasks(projectID: pid).first
        XCTAssertEqual(finalServer?.title, "Von B")
        XCTAssertEqual(finalServer?.status, "done")

        // Idempotence: another sync with an empty queue changes nothing.
        let again = try await b.sync()
        XCTAssertEqual(again.pushed, 0)

        // Tombstone: A deletes the project (cascade); B's feed removes project and task.
        try await a.deleteProject(pid)
        let rd = try await a.sync()
        XCTAssertEqual(rd.pushed, 1)
        _ = try await b.sync()
        snapB = await b.snapshot()
        XCTAssertFalse(snapB.projects.contains { $0.id == pid })
        XCTAssertFalse(snapB.tasks.contains { $0.id == tid })

        // A reopened store (app restart) keeps cursor and data.
        let reopened = try SyncEngine(client: f.admin, store: try SQLiteSyncStore(path: pathA))
        let s = await reopened.snapshot()
        XCTAssertNotEqual(s.cursor, "c0")
    }

    func testSyncEngineRevokeAndRegrantReachBob() async throws {
        let f = try await fixture()
        let bobEngine = try SyncEngine(client: f.bob, store: InMemorySyncStore())
        let admin = try SyncEngine(client: f.admin, store: InMemorySyncStore())
        let pid = UUID(), tid = UUID()
        try await admin.createProject(id: pid, name: "Revoke \(f.suffix)")
        try await admin.createTask(id: tid, projectID: pid, title: "Geheim")
        _ = try await admin.sync()
        _ = try await bobEngine.sync()
        var snap = await bobEngine.snapshot()
        XCTAssertFalse(snap.projects.contains { $0.id == pid }, "private project not visible")

        let grant = try await f.admin.setGrant(projectID: pid, principalType: .person, principalID: f.bobUser.id, role: .edit)
        _ = try await bobEngine.sync()
        snap = await bobEngine.snapshot()
        XCTAssertTrue(snap.projects.contains { $0.id == pid }, "gained access arrives as upsert")
        XCTAssertTrue(snap.tasks.contains { $0.id == tid })

        // Bob edits through his queue (edit role).
        try await bobEngine.updateTask(tid, TaskUpdate(status: .inProgress))
        let rb = try await bobEngine.sync()
        XCTAssertEqual(rb.pushed, 1)
        let bobEdit = try await f.admin.tasks(projectID: pid).first?.status
        XCTAssertEqual(bobEdit, "in_progress")

        try await f.admin.removeGrant(projectID: pid, grantID: grant.id)
        _ = try await bobEngine.sync()
        snap = await bobEngine.snapshot()
        XCTAssertFalse(snap.projects.contains { $0.id == pid }, "revoke removes the project locally")
        XCTAssertFalse(snap.tasks.contains { $0.id == tid })

        // A queued change after losing access is refused, surfaced and does not loop.
        try await bobEngine.acceptServer(task: TodoTask(id: tid, projectID: pid, title: "Geheim", status: "in_progress", version: 2))
        try await bobEngine.updateTask(tid, TaskUpdate(title: "ohne Recht"))
        let rr = try await bobEngine.sync()
        XCTAssertEqual(rr.rejected, 1)

        _ = try await f.admin.setGrant(projectID: pid, principalType: .person, principalID: f.bobUser.id, role: .comment)
        _ = try await bobEngine.sync()
        snap = await bobEngine.snapshot()
        XCTAssertTrue(snap.projects.contains { $0.id == pid }, "re-grant brings it back")
    }

    func testSyncEngineResyncsAfterCursorAhead() async throws {
        let f = try await fixture()
        let store = InMemorySyncStore()
        var stale = SyncBatch()
        stale.cursor = "c999999999"
        stale.taskUpserts = [TodoTask(id: UUID(), projectID: UUID(), title: "Phantom")]
        try store.commit(stale)
        let engine = try SyncEngine(client: f.admin, store: store)
        let report = try await engine.sync()
        XCTAssertTrue(report.fullResync)
        let snap = await engine.snapshot()
        XCTAssertFalse(snap.tasks.contains { $0.title == "Phantom" })
        XCTAssertNotEqual(snap.cursor, "c999999999")
        let serverProjects = try await f.admin.projects()
        XCTAssertEqual(Set(snap.projects.map(\.id)), Set(serverProjects.map(\.id)))
    }
}
