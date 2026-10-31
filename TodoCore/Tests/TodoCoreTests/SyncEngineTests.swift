import XCTest
@testable import TodoCore

final class SyncEngineTests: XCTestCase {
    let pid = UUID(), child = UUID(), t1 = UUID(), t2 = UUID()
    var client: APIClient!
    var store: InMemorySyncStore!

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

    // MARK: Fixtures

    func engine(pageSize: Int = 200, store: (any SyncStore)? = nil) throws -> SyncEngine {
        try SyncEngine(client: client, store: store ?? self.store, pageSize: pageSize)
    }
    func projectJSON(_ id: UUID, name: String = "P", parent: UUID? = nil, version: Int = 1) -> String {
        #"{"id":"\#(id)","parentID":\#(parent.map { "\"\($0)\"" } ?? "null"),"name":"\#(name)","version":\#(version)}"#
    }
    func taskJSON(_ id: UUID, project: UUID? = nil, title: String = "T", status: String = "open", version: Int = 1) -> String {
        #"{"id":"\#(id)","projectID":"\#(project ?? pid)","title":"\#(title)","description":"","status":"\#(status)","version":\#(version)}"#
    }
    func upsertProject(_ seq: Int, _ id: UUID, name: String = "P", parent: UUID? = nil, version: Int = 1) -> String {
        #"{"seq":\#(seq),"entityType":"project","entityID":"\#(id)","kind":"upsert","project":\#(projectJSON(id, name: name, parent: parent, version: version))}"#
    }
    func upsertTask(_ seq: Int, _ id: UUID, project: UUID? = nil, title: String = "T", version: Int = 1) -> String {
        #"{"seq":\#(seq),"entityType":"task","entityID":"\#(id)","kind":"upsert","task":\#(taskJSON(id, project: project, title: title, version: version))}"#
    }
    func delete(_ seq: Int, _ type: String, _ id: UUID) -> String {
        #"{"seq":\#(seq),"entityType":"\#(type)","entityID":"\#(id)","kind":"delete"}"#
    }
    func page(_ changes: [String], cursor: String, more: Bool = false) -> (Int, Data) {
        (200, Data(#"{"changes":[\#(changes.joined(separator: ","))],"cursor":"\#(cursor)","hasMore":\#(more)}"#.utf8))
    }
    func err(_ status: Int, _ reason: String) -> (Int, Data) { (status, Data(#"{"error":true,"reason":"\#(reason)"}"#.utf8)) }
    func mutationResult(_ m: [String: Any], task: String? = nil, project: String? = nil, deleted: Bool = false, status: Int = 200) -> (Int, Data) {
        let body = #"{"mutationID":"\#(m["mutationID"] as! String)","type":"\#(m["type"] as! String)","id":"\#(m["id"] as! String)","deleted":\#(deleted),"project":\#(project ?? "null"),"task":\#(task ?? "null"),"cursor":"c99"}"#
        return (status, Data(body.utf8))
    }
    func jsonBody(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
    }
    var feedRequests: [URLRequest] { MockURLProtocol.seen.filter { $0.url?.path == "/v1/sync/changes" } }
    var mutationRequests: [[String: Any]] { MockURLProtocol.seen.filter { $0.url?.path == "/v1/sync/mutations" }.map(jsonBody) }
    func cursorQuery(_ r: URLRequest) -> String { URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value ?? "" }

    /// Handler for an empty feed at the given cursor and mutations answered by `onMutation`.
    func serve(feed: @escaping (String) -> (Int, Data) = { _ in (200, Data(#"{"changes":[],"cursor":"c0","hasMore":false}"#.utf8)) },
               mutation: @escaping ([String: Any]) -> (Int, Data) = { _ in (500, Data()) }) {
        MockURLProtocol.handler = { [self] req in
            if req.url!.path == "/v1/sync/changes" { return feed(cursorQuery(req)) }
            return mutation(jsonBody(req))
        }
    }

    // MARK: Cursor handling

    func testInitialSyncStartsAtC0PagesAndPersists() async throws {
        serve(feed: { [self] c in
            switch c {
            case "c0": page([upsertProject(1, pid), upsertTask(2, t1)], cursor: "c2", more: true)
            case "c2": page([upsertTask(3, t2, title: "B")], cursor: "c3")
            default: err(500, "unexpected")
            }
        })
        let e = try engine(pageSize: 2)
        let report = try await e.sync()
        XCTAssertEqual(feedRequests.map(cursorQuery), ["c0", "c2"])
        XCTAssertEqual(report.pulled, 3)
        XCTAssertFalse(report.offline)
        let snap = await e.snapshot()
        XCTAssertEqual(snap.projects.map(\.id), [pid])
        XCTAssertEqual(Set(snap.tasks.map(\.id)), [t1, t2])
        XCTAssertEqual(snap.cursor, "c3")
        // A new engine on the same store starts from the persisted cursor with the persisted data (no c0).
        MockURLProtocol.seen = []
        let e2 = try engine(); let s2 = await e2.snapshot()
        XCTAssertEqual(s2.tasks.count, 2); XCTAssertEqual(s2.cursor, "c3")
        _ = try await e2.sync()
        XCTAssertEqual(feedRequests.map(cursorQuery), ["c3"])
    }

    func testIncrementalSyncAppliesUpsertTombstoneAndRevoke() async throws {
        serve(feed: { [self] c in
            switch c {
            case "c0": page([upsertProject(1, pid), upsertProject(2, child, name: "C", parent: pid), upsertTask(3, t1), upsertTask(4, t2, project: child)], cursor: "c4")
            case "c4": page([upsertTask(5, t1, title: "T2", version: 2), delete(6, "task", t2)], cursor: "c6")
            case "c6": page([delete(7, "project", pid)], cursor: "c7")  // revoke is delivered as kind=delete too
            default: err(500, "unexpected")
            }
        })
        let e = try engine()
        _ = try await e.sync()
        var snap = await e.snapshot()
        XCTAssertEqual(snap.tasks.count, 2)
        _ = try await e.sync()
        snap = await e.snapshot()
        XCTAssertEqual(snap.tasks.map(\.title), ["T2"])
        XCTAssertEqual(snap.tasks.first?.version, 2)
        XCTAssertEqual(snap.projects.count, 2)
        _ = try await e.sync()
        snap = await e.snapshot()
        XCTAssertTrue(snap.projects.isEmpty, "revoked project and its subtree vanish locally")
        XCTAssertTrue(snap.tasks.isEmpty)
        XCTAssertEqual(snap.cursor, "c7")
    }

    func testCursorAheadTriggersFullResyncKeepingQueue() async throws {
        let offline = UUID()
        var calls = 0
        serve(feed: { [self] c in
            calls += 1
            switch c {
            case "c0" where calls == 1: return page([upsertProject(1, pid), upsertTask(2, t1)], cursor: "c9")
            case "c9": return err(409, "cursor_ahead")
            case "c0": return page([upsertProject(1, pid), upsertTask(2, t2)], cursor: "c2")  // t1 no longer visible after restore
            default: return err(500, "unexpected")
            }
        }, mutation: { _ in (-1, Data()) })
        let e = try engine()
        _ = try await e.sync()
        try await e.createTask(id: offline, projectID: pid, title: "Offline")
        let report = try await e.sync()
        XCTAssertTrue(report.offline)  // queue could not be sent
        // Now the server is reachable for the feed only; force the stale-cursor path.
        MockURLProtocol.seen = []
        let report2 = try await e.sync()
        XCTAssertTrue(report2.offline)
        XCTAssertEqual(feedRequests.count, 0, "no pull while the queue cannot be sent")
        // Mutations succeed now.
        serve(feed: { [self] c in
            switch c {
            case "c9": return err(409, "cursor_ahead")
            case "c0": return page([upsertProject(1, pid), upsertTask(2, t2), upsertTask(3, offline, title: "Offline")], cursor: "c2")
            default: return err(500, "unexpected \(c)")
            }
        }, mutation: { [self] m in mutationResult(m, task: taskJSON(offline, title: "Offline"), status: 201) })
        let report3 = try await e.sync()
        XCTAssertTrue(report3.fullResync)
        XCTAssertEqual(report3.pushed, 1)
        let snap = await e.snapshot()
        XCTAssertEqual(Set(snap.tasks.map(\.id)), [t2, offline])
        XCTAssertEqual(snap.cursor, "c2")
        XCTAssertEqual(snap.pending, 0)
    }

    func testCursorAheadInitialCursorIsFetchedBeforeResync() async throws {
        // Store holds cursor c9 from before a backup restore.
        try store.commit({ var b = SyncBatch(); b.cursor = "c9"; b.taskUpserts = [TodoTask(id: t1, projectID: pid, title: "Stale")]; return b }())
        serve(feed: { [self] c in
            c == "c9" ? err(409, "cursor_ahead") : page([upsertProject(1, pid)], cursor: "c1")
        })
        let e = try engine()
        let r = try await e.sync()
        XCTAssertTrue(r.fullResync)
        XCTAssertEqual(feedRequests.map(cursorQuery), ["c9", "c0"])
        let snap = await e.snapshot()
        XCTAssertTrue(snap.tasks.isEmpty, "entities missing from the fresh state are dropped")
    }

    func testInvalidCursorAlsoResyncs() async throws {
        try store.commit({ var b = SyncBatch(); b.cursor = "garbage"; return b }())
        serve(feed: { [self] c in c == "garbage" ? err(400, "invalid_cursor") : page([], cursor: "c1") })
        let r = try await engine().sync()
        XCTAssertTrue(r.fullResync)
    }

    // MARK: 410 cursor_expired (ADR 0019)

    func testCursorExpiredDropsCacheKeepsQueueAndReloadsFromC0() async throws {
        let e = try await seeded()  // cursor c2, project + t1 confirmed
        // A conflicting queued edit stays in the queue (never sent again); a create is sent before the pull.
        let offline = UUID()
        try await e.updateTask(t1, TaskUpdate(title: "Mine"))
        try await e.createTask(id: offline, projectID: pid, title: "Offline")
        serve(feed: { [self] c in
            switch c {
            case "c2": return err(410, "cursor_expired")
            case "c0": return page([upsertProject(1, pid), upsertTask(5, t2, title: "B"), upsertTask(6, offline, title: "Offline")], cursor: "c6")
            default: return err(500, "unexpected \(c)")
            }
        }, mutation: { [self] m in
            if m["type"] as? String == "task.update" { return err(409, "version_conflict") }
            return mutationResult(m, task: taskJSON(offline, title: "Offline"), status: 201)
        })
        let before = Date()
        let r = try await e.sync()
        XCTAssertTrue(r.fullResync)
        XCTAssertFalse(r.offline)
        XCTAssertEqual(r.pushed, 1)
        XCTAssertEqual(feedRequests.map(cursorQuery), ["c2", "c0"])
        let snap = await e.snapshot()
        XCTAssertEqual(snap.cursor, "c6")
        XCTAssertFalse(snap.tasks.contains { $0.id == t1 }, "cache was replaced: t1 is no longer visible on the server")
        XCTAssertEqual(Set(snap.tasks.map(\.id)), [t2, offline])
        XCTAssertEqual(snap.conflicts.count, 1, "unsent/stopped queue entries survive the resync")
        XCTAssertEqual(snap.conflicts.first?.mutation.id, t1)
        let persisted = try store.load()
        XCTAssertEqual(Set(persisted.tasks.keys), [t2, offline], "the store itself was emptied of stale entities")
        XCTAssertEqual(persisted.queue.count, 1)
        let at = await e.lastFullResyncAt
        XCTAssertNotNil(at)
        XCTAssertGreaterThanOrEqual(at!, before)
    }

    func testCursorExpiredKeepsPendingQueueWhenOffline() async throws {
        let e = try await seeded()
        try await e.createTask(projectID: pid, title: "Pending")
        // Mutations unreachable: nothing is pulled, so no resync and the queue is untouched.
        serve(feed: { [self] _ in err(410, "cursor_expired") }, mutation: { _ in (-1, Data()) })
        let r = try await e.sync()
        XCTAssertTrue(r.offline)
        XCTAssertFalse(r.fullResync)
        let snap = await e.snapshot()
        XCTAssertEqual(snap.pending, 1)
    }

    func testCursorExpiredResyncsOnlyOncePerRun() async throws {
        let e = try await seeded()
        serve(feed: { [self] _ in err(410, "cursor_expired") })  // even c0 answers 410
        do { _ = try await e.sync(); XCTFail("must surface the error") }
        catch { XCTAssertEqual(error as? APIError, .cursorExpired) }
        XCTAssertEqual(feedRequests.map(cursorQuery), ["c2", "c0"], "no loop: one retry from c0 only")
        let snap = await e.snapshot()
        XCTAssertEqual(snap.tasks.map(\.id), [t1], "failed resync leaves the cache untouched")
        let at = await e.lastFullResyncAt
        XCTAssertNil(at)
    }

    func testCursorC0AndCursorAtFloorStayValid() async throws {
        serve(feed: { [self] c in
            c == "c0" ? page([upsertProject(1, pid)], cursor: "c5") : page([upsertTask(6, t1)], cursor: "c6")
        })
        let e = try engine()
        var r = try await e.sync()
        XCTAssertFalse(r.fullResync, "the initial c0 pull is not a resync")
        r = try await e.sync()  // cursor c5 = retention floor: valid
        XCTAssertFalse(r.fullResync)
        let at = await e.lastFullResyncAt
        XCTAssertNil(at)
        XCTAssertEqual(feedRequests.map(cursorQuery), ["c0", "c5"])
    }

    func testCursorExpiredResyncInterruptedByNetworkKeepsCache() async throws {
        let e = try await seeded()
        serve(feed: { [self] c in c == "c2" ? err(410, "cursor_expired") : (-1, Data()) })
        let r = try await e.sync()
        XCTAssertTrue(r.fullResync)
        XCTAssertTrue(r.offline)
        let snap = await e.snapshot()
        XCTAssertEqual(snap.tasks.map(\.id), [t1])
        XCTAssertEqual(snap.cursor, "c2", "the old cursor stays, so the next run retries and gets 410 again")
        let at = await e.lastFullResyncAt
        XCTAssertNil(at)
    }

    func testFullResyncEventsEmitOnCompletion() async throws {
        let e = try await seeded()
        let stream = await e.fullResyncEvents()
        serve(feed: { [self] c in c == "c2" ? err(410, "cursor_expired") : page([upsertProject(1, pid)], cursor: "c3") })
        _ = try await e.sync()
        var it = stream.makeAsyncIterator()
        let d = await it.next()
        XCTAssertNotNil(d)
    }

    func testOther410IsAPlainServerError() {
        XCTAssertEqual(APIError.from(status: 410, reason: "cursor_expired"), .cursorExpired)
        XCTAssertEqual(APIError.from(status: 410, reason: "gone"), .server(status: 410, reason: "gone"))
    }

    func testMissingFeedIsThrownSoTheAppCanFallBackToREST() async throws {
        serve(feed: { [self] _ in err(404, "not_found") })
        do { _ = try await engine().sync(); XCTFail() } catch { XCTAssertEqual(error as? APIError, .notFound) }
    }

    func testUnauthorizedIsThrown() async throws {
        serve(feed: { [self] _ in err(401, "unauthorized") })
        do { _ = try await engine().sync(); XCTFail() } catch { XCTAssertEqual(error as? APIError, .unauthorized(reason: "unauthorized")) }
    }

    func testOfflineFeedKeepsLocalData() async throws {
        serve(feed: { _ in (-1, Data()) })
        let e = try engine()
        let r = try await e.sync()
        XCTAssertTrue(r.offline)
    }

    // MARK: Offline queue

    func seeded() async throws -> SyncEngine {
        serve(feed: { [self] c in c == "c0" ? page([upsertProject(1, pid), upsertTask(2, t1)], cursor: "c2") : page([], cursor: c) })
        let e = try engine()
        _ = try await e.sync()
        MockURLProtocol.seen = []
        return e
    }

    func testOfflineMutationIsOptimisticThenRetriedWithSameMutationID() async throws {
        let e = try await seeded()
        let newID = UUID()
        let snapA = try await e.createTask(id: newID, projectID: pid, title: "Neu")
        XCTAssertEqual(snapA.pending, 1)
        XCTAssertTrue(snapA.tasks.contains { $0.id == newID && $0.title == "Neu" })
        serve(mutation: { _ in (-1, Data()) })
        let r1 = try await e.sync()
        XCTAssertTrue(r1.offline)
        let still = await e.snapshot()
        XCTAssertEqual(still.pending, 1)
        XCTAssertTrue(still.tasks.contains { $0.id == newID })
        serve(mutation: { [self] m in mutationResult(m, task: taskJSON(newID, title: "Neu"), status: 201) })
        let r2 = try await e.sync()
        XCTAssertEqual(r2.pushed, 1)
        let ids = mutationRequests.compactMap { $0["mutationID"] as? String }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 1, "retry keeps the mutationID (idempotent)")
        XCTAssertEqual(mutationRequests.last?["type"] as? String, "task.create")
        XCTAssertEqual(mutationRequests.last?["projectID"] as? String, pid.uuidString)
        let done = await e.snapshot()
        XCTAssertEqual(done.pending, 0)
        XCTAssertEqual(done.tasks.first { $0.id == newID }?.version, 1)
    }

    func testQueueSurvivesRestartAndKeepsMutationID() async throws {
        let e = try await seeded()
        try await e.updateTask(t1, TaskUpdate(status: .done))
        let before = try store.load().queue.first!.id
        let e2 = try engine()  // "app restart"
        let snap = await e2.snapshot()
        XCTAssertEqual(snap.pending, 1)
        XCTAssertEqual(snap.tasks.first { $0.id == t1 }?.status, "done")
        serve(mutation: { [self] m in mutationResult(m, task: taskJSON(t1, status: "done", version: 2)) })
        _ = try await e2.sync()
        XCTAssertEqual(mutationRequests.first?["mutationID"] as? String, before.uuidString)
        XCTAssertEqual(mutationRequests.first?["version"] as? Int, 1)
    }

    func testChainedMutationsTakeTheVersionFromTheEarlierResult() async throws {
        let e = try await seeded()
        try await e.updateTask(t1, TaskUpdate(title: "A"))
        try await e.updateTask(t1, TaskUpdate(status: .done))
        var versions = 1
        serve(mutation: { [self] m in
            versions += 1
            return mutationResult(m, task: taskJSON(t1, title: (m["title"] as? String) ?? "A", status: (m["status"] as? String) ?? "open", version: versions))
        })
        let r = try await e.sync()
        XCTAssertEqual(r.pushed, 2)
        XCTAssertEqual(mutationRequests.map { $0["version"] as? Int }, [1, 2])
    }

    func testCreateThenUpdateOfPendingEntityWorks() async throws {
        let e = try await seeded()
        let nid = UUID()
        try await e.createTask(id: nid, projectID: pid, title: "N")
        try await e.updateTask(nid, TaskUpdate(status: .done))
        serve(mutation: { [self] m in
            m["type"] as? String == "task.create"
                ? mutationResult(m, task: taskJSON(nid, title: "N"), status: 201)
                : mutationResult(m, task: taskJSON(nid, title: "N", status: "done", version: 2))
        })
        _ = try await e.sync()
        XCTAssertEqual(mutationRequests.map { $0["version"] as? Int }, [nil, 1])
        let snap = await e.snapshot()
        XCTAssertEqual(snap.tasks.first { $0.id == nid }?.status, "done")
    }

    func testUpdateOfUnknownEntityThrows() async throws {
        let e = try engine()
        do { try await e.updateTask(UUID(), TaskUpdate(title: "x")); XCTFail() }
        catch { XCTAssertTrue(error is SyncEngineError) }
    }

    func testOptimisticProjectDeleteHidesSubtreeAndSuccessRemovesIt() async throws {
        serve(feed: { [self] c in c == "c0" ? page([upsertProject(1, pid), upsertProject(2, child, parent: pid), upsertTask(3, t1, project: child)], cursor: "c3") : page([], cursor: c) })
        let e = try engine(); _ = try await e.sync()
        let snap = try await e.deleteProject(pid)
        XCTAssertTrue(snap.projects.isEmpty); XCTAssertTrue(snap.tasks.isEmpty)
        serve(mutation: { [self] m in mutationResult(m, deleted: true) })
        _ = try await e.sync()
        XCTAssertEqual(mutationRequests.last?["type"] as? String, "project.delete")
        let s = try store.load()
        XCTAssertTrue(s.projects.isEmpty); XCTAssertTrue(s.tasks.isEmpty)
    }

    // MARK: Conflicts and rejections

    func testVersionConflictIsSurfacedBlocksFollowersAndCanBeKeptOrDiscarded() async throws {
        let e = try await seeded()
        try await e.updateTask(t1, TaskUpdate(title: "Mine"))
        try await e.updateTask(t1, TaskUpdate(status: .done))
        // Server moved on to version 3 meanwhile.
        serve(feed: { [self] c in c == "c2" ? page([upsertTask(5, t1, title: "Theirs", version: 3)], cursor: "c5") : page([], cursor: c) },
              mutation: { _ in self.err(409, "version_conflict") })
        let r = try await e.sync()
        XCTAssertEqual(r.conflicts, 1)
        XCTAssertEqual(r.pushed, 0)
        XCTAssertEqual(mutationRequests.count, 1, "the follower is held back")
        var snap = await e.snapshot()
        XCTAssertEqual(snap.conflicts.count, 1)
        XCTAssertEqual(snap.conflicts.first?.mutation.title, "Mine")
        XCTAssertEqual(snap.tasks.first { $0.id == t1 }?.title, "Theirs", "server state shown while in conflict")
        // Keep mine: re-sent on top of version 3 (taken from the pulled state), follower follows.
        MockURLProtocol.seen = []
        var v = 3
        serve(mutation: { [self] m in v += 1; return mutationResult(m, task: taskJSON(t1, title: "Mine", status: (m["status"] as? String) ?? "open", version: v)) })
        try await e.resolveConflict(snap.conflicts[0].id, keepMine: true)
        let r2 = try await e.sync()
        XCTAssertEqual(r2.pushed, 2)
        XCTAssertEqual(mutationRequests.map { $0["version"] as? Int }, [3, 4])
        snap = await e.snapshot()
        XCTAssertTrue(snap.conflicts.isEmpty)
        XCTAssertEqual(snap.pending, 0)
    }

    func testDiscardingAConflictDropsIt() async throws {
        let e = try await seeded()
        try await e.updateTask(t1, TaskUpdate(title: "Mine"))
        serve(mutation: { _ in self.err(409, "version_conflict") })
        _ = try await e.sync()
        let c = await e.snapshot().conflicts
        try await e.resolveConflict(c[0].id, keepMine: false)
        let snap = await e.snapshot()
        XCTAssertEqual(snap.pending + snap.conflicts.count + snap.rejected.count, 0)
        XCTAssertEqual(snap.tasks.first?.title, "T")
    }

    func testMutationIDReusedIsRetriedOnceUnderANewIDThenRejected() async throws {
        let e = try await seeded()
        try await e.updateTask(t1, TaskUpdate(title: "X"))
        let original = try store.load().queue[0].id
        var first = true
        serve(mutation: { [self] m in
            if first { first = false; return err(409, "mutation_id_reused") }
            return mutationResult(m, task: taskJSON(t1, title: "X", version: 2))
        })
        let r = try await e.sync()
        XCTAssertEqual(r.pushed, 1)
        let ids = mutationRequests.compactMap { $0["mutationID"] as? String }
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertEqual(ids[0], original.uuidString)

        try await e.updateTask(t1, TaskUpdate(title: "Y"))
        serve(mutation: { _ in self.err(409, "mutation_id_reused") })
        let r2 = try await e.sync()
        XCTAssertEqual(r2.rejected, 1, "a second reuse answer is final")
        let snap = await e.snapshot()
        XCTAssertEqual(snap.rejected.first?.reason, "mutation_id_reused")
    }

    func testRejectedMutationsAreSurfacedAndDismissed() async throws {
        let e = try await seeded()
        let nid = UUID()
        try await e.createTask(id: nid, projectID: pid, title: "Viewer")
        try await e.updateTask(nid, TaskUpdate(status: .done))
        serve(mutation: { _ in self.err(403, "forbidden") })
        let r = try await e.sync()
        XCTAssertEqual(r.rejected, 1)
        var snap = await e.snapshot()
        XCTAssertEqual(snap.rejected.first?.reason, "forbidden")
        XCTAssertFalse(snap.tasks.contains { $0.id == nid }, "rejected create disappears from the visible state")
        try await e.dismiss(snap.rejected[0].id)
        snap = await e.snapshot()
        XCTAssertEqual(snap.pending, 0, "dismissing the create also drops the follower")
        XCTAssertTrue(snap.rejected.isEmpty)
    }

    func testNotFoundAndIdExistsAreRejectedNotRetried() async throws {
        let e = try await seeded()
        try await e.deleteTask(t1)
        serve(mutation: { _ in self.err(404, "not_found") })
        var r = try await e.sync()
        XCTAssertEqual(r.rejected, 1)
        let nid = UUID()
        try await e.createTask(id: nid, projectID: pid, title: "x")
        serve(mutation: { _ in self.err(409, "id_exists") })
        r = try await e.sync()
        XCTAssertEqual(r.rejected, 2)
        let snap = await e.snapshot()
        XCTAssertEqual(snap.rejected.map(\.reason), ["not_found", "id_exists"])
    }

    func testServerErrorKeepsMutationPendingAsOffline() async throws {
        let e = try await seeded()
        try await e.updateTask(t1, TaskUpdate(title: "x"))
        serve(mutation: { _ in self.err(503, "unavailable") })
        let r = try await e.sync()
        XCTAssertTrue(r.offline)
        let snap = await e.snapshot()
        XCTAssertEqual(snap.pending, 1)
    }

    func testReplayedOlderResultDoesNotRegressConfirmedVersion() async throws {
        let e = try await seeded()
        try await e.acceptServer(task: TodoTask(id: t1, projectID: pid, title: "New", version: 5))
        try await e.acceptServer(task: TodoTask(id: t1, projectID: pid, title: "Old", version: 2))
        let snap = await e.snapshot()
        XCTAssertEqual(snap.tasks.first?.title, "New")
    }

    func testResetWipesStore() async throws {
        let e = try await seeded()
        try await e.updateTask(t1, TaskUpdate(title: "x"))
        try await e.reset()
        let s = try store.load()
        XCTAssertTrue(s.tasks.isEmpty); XCTAssertTrue(s.queue.isEmpty); XCTAssertEqual(s.cursor, "c0")
        let snap = await e.snapshot(); XCTAssertTrue(snap.tasks.isEmpty)
    }

    func testFailedStoreWriteLeavesStateUnchanged() async throws {
        let e = try await seeded()
        store.failNextCommit = true
        do { try await e.updateTask(t1, TaskUpdate(title: "x")); XCTFail() } catch { XCTAssertTrue(error is SyncEngineError) }
        let snap = await e.snapshot()
        XCTAssertEqual(snap.pending, 0)
        XCTAssertEqual(snap.tasks.first?.title, "T")
    }

    // MARK: SQLite

    func testSQLiteStoreRoundTripAndAtomicBatch() throws {
        let path = NSTemporaryDirectory() + "sync-\(UUID().uuidString).sqlite"
        defer { for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + ext) } }
        do {
            let s = try SQLiteSyncStore(path: path)
            var b = SyncBatch()
            b.projectUpserts = [Project(id: pid, parentID: nil, name: "P", version: 3)]
            b.taskUpserts = [TodoTask(id: t1, projectID: pid, title: "T", version: 2)]
            b.cursor = "c42"
            let q = QueuedMutation(mutation: SyncMutation(type: .taskUpdate, id: t1, version: 2, title: "Z"), order: 7, chained: false)
            b.queueUpserts = [q, QueuedMutation(mutation: SyncMutation(type: .taskDelete, id: t2), order: 3, chained: true, status: .conflict, reason: "version_conflict")]
            try s.commit(b)
            var b2 = SyncBatch(); b2.taskUpserts = [TodoTask(id: t1, projectID: pid, title: "T-new", version: 3)]; b2.cursor = "c43"
            try s.commit(b2)
        }
        let reopened = try SQLiteSyncStore(path: path)
        let state = try reopened.load()
        XCTAssertEqual(state.cursor, "c43")
        XCTAssertEqual(state.projects[pid]?.version, 3)
        XCTAssertEqual(state.tasks[t1]?.title, "T-new")
        XCTAssertEqual(state.queue.map(\.order), [3, 7], "queue is returned in order")
        XCTAssertEqual(state.queue[0].status, .conflict)
        XCTAssertEqual(state.queue[1].mutation.title, "Z")
        var rm = SyncBatch(); rm.queueRemovals = [state.queue[0].id]; rm.taskDeletes = [t1]
        try reopened.commit(rm)
        let after = try reopened.load()
        XCTAssertEqual(after.queue.count, 1); XCTAssertTrue(after.tasks.isEmpty)
        try reopened.wipe()
        XCTAssertEqual(try reopened.load(), SyncState())
    }

    func testEngineOnSQLiteStoreSurvivesRestart() async throws {
        let path = NSTemporaryDirectory() + "sync-\(UUID().uuidString).sqlite"
        defer { for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + ext) } }
        serve(feed: { [self] c in c == "c0" ? page([upsertProject(1, pid), upsertTask(2, t1)], cursor: "c2") : page([], cursor: c) },
              mutation: { _ in (-1, Data()) })
        do {
            let e = try engine(store: try SQLiteSyncStore(path: path))
            _ = try await e.sync()
            try await e.updateTask(t1, TaskUpdate(status: .done))
            let r = try await e.sync(); XCTAssertTrue(r.offline)
        }
        let e2 = try engine(store: try SQLiteSyncStore(path: path))
        let snap = await e2.snapshot()
        XCTAssertEqual(snap.cursor, "c2"); XCTAssertEqual(snap.pending, 1)
        XCTAssertEqual(snap.tasks.first?.status, "done")
    }

    // MARK: Task order and detail edits

    func testTaskOrderIsFirstSeenAndStableAcrossUpdatesAndResync() async throws {
        let (a, b, c) = (UUID(), UUID(), UUID())
        var round = 0
        serve(feed: { [self] cur in
            round += 1
            if cur == "c0" && round == 1 { return page([upsertProject(1, pid), upsertTask(2, b, title: "Zeta"), upsertTask(3, a, title: "Alpha")], cursor: "c3") }
            if cur == "c3" { return page([upsertTask(4, b, title: "Zeta edited", version: 2), upsertTask(5, c, title: "Mid")], cursor: "c5") }
            // Resync: server lists c first now, the known order must still win.
            return page([upsertProject(1, pid), upsertTask(6, c, title: "Mid"), upsertTask(7, a, title: "Alpha"), upsertTask(8, b, title: "Zeta edited", version: 2)], cursor: "c8")
        })
        let e = try engine()
        _ = try await e.sync()
        var snap = await e.snapshot()
        XCTAssertEqual(snap.tasks.map(\.id), [b, a], "first full pull keeps feed order, not alphabetical")
        _ = try await e.sync()
        snap = await e.snapshot()
        XCTAssertEqual(snap.tasks.map(\.id), [b, a, c], "an update does not move the task; new ones go last")
        try await e.updateTask(a, TaskUpdate(title: "Aaa"))
        snap = await e.snapshot()
        XCTAssertEqual(snap.tasks.map(\.id), [b, a, c], "optimistic edit keeps position")
    }

    func testLocallyCreatedTaskIsLastAndKeepsPositionAfterConfirmation() async throws {
        let n = UUID()
        serve(feed: { [self] c in c == "c0" ? page([upsertProject(1, pid), upsertTask(2, t1, title: "Zed")], cursor: "c2") : page([], cursor: c) },
              mutation: { [self] m in mutationResult(m, task: taskJSON(UUID(uuidString: m["id"] as! String)!, title: "Aaa"), status: 201) })
        let e = try engine()
        _ = try await e.sync()
        try await e.createTask(id: n, projectID: pid, title: "Aaa")
        var snap = await e.snapshot()
        XCTAssertEqual(snap.tasks.map(\.id), [t1, n])
        _ = try await e.sync()
        snap = await e.snapshot()
        XCTAssertEqual(snap.tasks.map(\.id), [t1, n])
    }

    func testRanksPersistAndOldCachesAreRankedOnce() async throws {
        let path = NSTemporaryDirectory() + "sync-\(UUID().uuidString).sqlite"
        defer { for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + ext) } }
        // A cache from before ranks existed: tasks but no ranks.
        let old = try SQLiteSyncStore(path: path)
        var batch = SyncBatch()
        batch.projectUpserts = [Project(id: pid, parentID: nil, name: "P", version: 1)]
        batch.taskUpserts = [TodoTask(id: t2, projectID: pid, title: "B"), TodoTask(id: t1, projectID: pid, title: "A")]
        try old.commit(batch)
        let e = try engine(store: try SQLiteSyncStore(path: path))
        var snap = await e.snapshot()
        XCTAssertEqual(snap.tasks.map(\.id), [t1, t2])
        // Persisted: a restart sees the same ranks, and new tasks sort after them.
        let n = UUID()
        try await e.createTask(id: n, projectID: pid, title: "0 first alphabetically")
        let e2 = try engine(store: try SQLiteSyncStore(path: path))
        snap = await e2.snapshot()
        XCTAssertEqual(snap.tasks.map(\.id), [t1, t2, n])
    }

    func testDetailEditsTitleDescriptionStatusAreOneQueuedUpdateEach() async throws {
        serve(feed: { [self] c in c == "c0" ? page([upsertProject(1, pid), upsertTask(2, t1, title: "Old")], cursor: "c2") : page([], cursor: c) },
              mutation: { _ in (-1, Data()) })
        let e = try engine()
        _ = try await e.sync()
        try await e.updateTask(t1, TaskUpdate(title: "New", description: "Body"))
        try await e.updateTask(t1, TaskUpdate(status: .inReview))
        let report = try await e.sync()
        XCTAssertTrue(report.offline)
        let snap = await e.snapshot()
        XCTAssertEqual(snap.pending, 2)
        XCTAssertEqual(snap.tasks.first?.title, "New")
        XCTAssertEqual(snap.tasks.first?.description, "Body")
        XCTAssertEqual(snap.tasks.first?.status, "in_review")
        let sent = mutationRequests
        XCTAssertEqual(sent.first?["type"] as? String, "task.update")
        XCTAssertEqual(sent.first?["title"] as? String, "New")
        XCTAssertEqual(sent.first?["description"] as? String, "Body")
        XCTAssertNil(sent.first?["status"])
    }

    /// Dropping a task on a sidebar project queues one `task.update` with `projectID` and moves it in the local snapshot.
    func testMovingTaskToAnotherProjectIsOneQueuedUpdateAndOptimistic() async throws {
        let other = UUID()
        serve(feed: { [self] c in c == "c0" ? page([upsertProject(1, pid), upsertProject(2, other), upsertTask(3, t1, title: "Move me")], cursor: "c3") : page([], cursor: c) },
              mutation: { _ in (-1, Data()) })
        let e = try engine()
        _ = try await e.sync()
        try await e.updateTask(t1, TaskUpdate(projectID: other))
        _ = try await e.sync()
        let snap = await e.snapshot()
        XCTAssertEqual(snap.pending, 1)
        XCTAssertEqual(snap.tasks.first?.projectID, other)
        let sent = mutationRequests
        XCTAssertEqual(sent.first?["type"] as? String, "task.update")
        XCTAssertEqual((sent.first?["projectID"] as? String)?.lowercased(), other.uuidString.lowercased())
    }
}
