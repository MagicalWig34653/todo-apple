import SQLite3
import XCTest

@testable import TodoCore

/// Planning and labels in the sync queue (contract 1.4.0, ADR 0020) against the mock transport.
extension SyncEngineTests {
    func planningJSON(due: String? = nil, priority: Int = 0) -> String {
        #"{"dueAt":\#(due.map { "\"\($0)\"" } ?? "null"),"priority":\#(priority),"reminders":[]}"#
    }
    func upsertTaskPlanned(_ seq: Int, _ id: UUID, version: Int = 1, due: String? = nil, priority: Int = 0) -> String {
        #"{"seq":\#(seq),"entityType":"task","entityID":"\#(id)","kind":"upsert","task":\#(taskJSON(id, version: version)),"planning":\#(planningJSON(due: due, priority: priority))}"#
    }
    func labelJSON(_ id: UUID, _ name: String, version: Int = 1, tasks: [UUID] = []) -> String {
        #"{"id":"\#(id)","name":"\#(name)","version":\#(version),"taskIDs":[\#(tasks.map { "\"\($0)\"" }.joined(separator: ","))]}"#
    }
    func upsertLabel(_ seq: Int, _ id: UUID, _ name: String, version: Int = 1, tasks: [UUID] = []) -> String {
        #"{"seq":\#(seq),"entityType":"label","entityID":"\#(id)","kind":"upsert","label":\#(labelJSON(id, name, version: version, tasks: tasks))}"#
    }
    func ok14(_ m: [String: Any], task: String? = nil, planning: String? = nil, label: String? = nil, deleted: Bool = false, status: Int = 200) -> (Int, Data) {
        let body = #"{"mutationID":"\#(m["mutationID"] as! String)","type":"\#(m["type"] as! String)","id":"\#(m["id"] as! String)","deleted":\#(deleted),"task":\#(task ?? "null"),"planning":\#(planning ?? "null"),"label":\#(label ?? "null"),"cursor":"c99"}"#
        return (status, Data(body.utf8))
    }
    func baseFeed(extra: [String] = []) -> (String) -> (Int, Data) {
        { [self] c in c == "c0" ? page([upsertProject(1, pid), upsertTaskPlanned(2, t1), upsertTaskPlanned(3, t2)] + extra, cursor: "c3") : page([], cursor: c) }
    }

    // MARK: Feed parsing

    func testFeedDeliversPlanningAndLabelsAndTombstonesCleanUp() async throws {
        let l1 = UUID()
        var round = 0
        serve(feed: { [self] c in
            if c == "c0" {
                return page([upsertProject(1, pid), upsertTaskPlanned(2, t1, due: "2026-11-01T09:00:00Z", priority: 2), upsertTaskPlanned(3, t2), upsertLabel(4, l1, "Haus", tasks: [t1, t2])], cursor: "c4")
            }
            round += 1
            if round == 1 { return page([delete(5, "task", t2), upsertLabel(6, l1, "Zuhause", version: 2, tasks: [t1, t2])], cursor: "c6") }
            return page([delete(7, "label", l1)], cursor: "c7")
        })
        let e = try engine()
        _ = try await e.sync()
        var snap = await e.snapshot()
        XCTAssertEqual(snap.planning[t1]?.priority, 2)
        XCTAssertEqual(snap.planning[t1]?.dueAt, ISO8601DateFormatter().date(from: "2026-11-01T09:00:00Z"))
        XCTAssertEqual(snap.labels.first?.taskIDs.sorted { $0.uuidString < $1.uuidString }, [t1, t2].sorted { $0.uuidString < $1.uuidString })
        let pe = await e.planningSyncSupport
        XCTAssertEqual(pe, .supported)

        _ = try await e.sync()  // task tombstone first, then a (stale) label upsert that still lists the gone task
        snap = await e.snapshot()
        XCTAssertNil(snap.planning[t2], "planning goes with the task")
        XCTAssertEqual(snap.labels.first?.name, "Zuhause")
        // The tombstone removed the link; a later label upsert listing it again is the server's truth (kept as delivered).
        _ = try await e.sync()
        snap = await e.snapshot()
        XCTAssertTrue(snap.labels.isEmpty, "label tombstone")
        // Persisted: a new engine on the same store sees the same.
        let e2 = try engine()
        let s2 = await e2.snapshot()
        XCTAssertNotNil(s2.planning[t1]); XCTAssertTrue(s2.labels.isEmpty)
    }

    func testTaskTombstoneAndProjectTombstoneRemoveLabelLinksLocally() async throws {
        let l1 = UUID()
        var round = 0
        serve(feed: { [self] c in
            if c == "c0" { return page([upsertProject(1, pid), upsertTaskPlanned(2, t1), upsertTaskPlanned(3, t2), upsertLabel(4, l1, "X", tasks: [t1, t2])], cursor: "c4") }
            round += 1
            return round == 1 ? page([delete(5, "task", t1)], cursor: "c5") : page([delete(6, "project", pid)], cursor: "c6")
        })
        let e = try engine()
        _ = try await e.sync()
        _ = try await e.sync()
        var snap = await e.snapshot()
        XCTAssertEqual(snap.labels.first?.taskIDs, [t2])
        _ = try await e.sync()
        snap = await e.snapshot()
        XCTAssertEqual(snap.labels.first?.taskIDs, [])
        XCTAssertTrue(snap.planning.isEmpty)
    }

    func testFullResyncReplacesPlanningAndLabels() async throws {
        let l1 = UUID(), l2 = UUID()
        var first = true
        serve(feed: { [self] c in
            if c == "c0" {
                defer { first = false }
                return first ? page([upsertProject(1, pid), upsertTaskPlanned(2, t1, priority: 1), upsertLabel(3, l1, "Alt", tasks: [t1])], cursor: "c3")
                    : page([upsertProject(1, pid), upsertTaskPlanned(2, t1, priority: 3), upsertLabel(4, l2, "Neu", tasks: [t1])], cursor: "c4")
            }
            return err(410, "cursor_expired")
        })
        let e = try engine()
        _ = try await e.sync()
        let r = try await e.sync()
        XCTAssertTrue(r.fullResync)
        let snap = await e.snapshot()
        XCTAssertEqual(snap.planning[t1]?.priority, 3)
        XCTAssertEqual(snap.labels.map(\.name), ["Neu"])
    }

    // MARK: Mutations and merge rules

    func testPlanningMutationWireOptimisticStateAndResult() async throws {
        serve(feed: baseFeed(), mutation: { [self] m in
            ok14(m, task: taskJSON(t1, version: 2), planning: planningJSON(due: "2026-12-24T18:00:00Z", priority: 2))
        })
        let e = try engine()
        _ = try await e.sync()
        let due = ISO8601DateFormatter().date(from: "2026-12-24T18:00:00Z")!
        let snap = try await e.setPlanning(t1, PlanningData(dueAt: due, priority: 2, recurrence: RecurrenceRule(frequency: .weekly, interval: 1, timeZone: "Europe/Berlin"), reminders: [due]))
        XCTAssertEqual(snap.pending, 1)
        XCTAssertEqual(snap.metaOverlay.planning[t1]?.priority, 2, "optimistic overlay")
        XCTAssertNil(snap.planning[t1]?.dueAt, "confirmed state untouched until the server answered")
        let r = try await e.sync()
        XCTAssertEqual(r.pushed, 1)
        let body = try XCTUnwrap(mutationRequests.first)
        XCTAssertEqual(body["type"] as? String, "task.planning")
        XCTAssertEqual(body["id"] as? String, t1.uuidString)
        XCTAssertEqual(body["version"] as? Int, 1)
        XCTAssertEqual(body["dueAt"] as? String, "2026-12-24T18:00:00Z")
        XCTAssertEqual(body["priority"] as? Int, 2)
        XCTAssertNil(body["plannedAt"], "absent fields clear on the server")
        XCTAssertEqual((body["recurrence"] as? [String: Any])?["frequency"] as? String, "weekly")
        XCTAssertEqual((body["reminders"] as? [String])?.count, 1)
        let after = await e.snapshot()
        XCTAssertEqual(after.planning[t1]?.priority, 2)
        XCTAssertEqual(after.tasks.first { $0.id == t1 }?.version, 2)
        XCTAssertEqual(after.pending, 0)
        let support = await e.planningSyncSupport
        XCTAssertEqual(support, .supported)
    }

    func testOnlyTheLastPlanningPerTaskIsSent() async throws {
        serve(feed: baseFeed(), mutation: { [self] m in ok14(m, task: taskJSON(t1, version: 2), planning: planningJSON(priority: 3)) })
        let e = try engine()
        _ = try await e.sync()
        try await e.setPlanning(t1, PlanningData(priority: 1))
        try await e.setPlanning(t2, PlanningData(priority: 1))
        let snap = try await e.setPlanning(t1, PlanningData(priority: 3))
        XCTAssertEqual(snap.pending, 2)
        XCTAssertEqual(snap.metaOverlay.planning[t1]?.priority, 3)
        _ = try await e.sync()
        let sent = mutationRequests
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.filter { $0["id"] as? String == t1.uuidString }.compactMap { $0["priority"] as? Int }, [3])
    }

    func testLabelAddRemovePairsAndLabelLifecycleMerge() async throws {
        let l1 = UUID(), l2 = UUID()
        serve(feed: baseFeed(extra: [upsertLabel(4, l1, "Haus", tasks: [t1])]), mutation: { [self] m in ok14(m, label: labelJSON(l1, "Haus", tasks: [])) })
        let e = try engine()
        _ = try await e.sync()
        // remove then add of a confirmed member nets out: nothing is sent.
        try await e.setLabel(l1, on: t1, enabled: false)
        var snap = try await e.setLabel(l1, on: t1, enabled: true)
        XCTAssertEqual(snap.pending, 0)
        // add then remove of a non-member nets out as well.
        try await e.setLabel(l1, on: t2, enabled: true)
        snap = try await e.setLabel(l1, on: t2, enabled: false)
        XCTAssertEqual(snap.pending, 0)
        // A label created offline: create + rename fold into one create; add stays; remove after add forgets both.
        try await e.createLabel(id: l2, name: "Neu")
        try await e.renameLabel(l2, name: "Neuer Name")
        try await e.setLabel(l2, on: t1, enabled: true)
        snap = try await e.setLabel(l2, on: t2, enabled: true)
        XCTAssertEqual(snap.pending, 3)
        XCTAssertEqual(snap.metaOverlay.newLabels.map(\.name), ["Neuer Name"])
        snap = try await e.setLabel(l2, on: t2, enabled: false)
        XCTAssertEqual(snap.pending, 2)
        // Deleting a label that never reached the server forgets everything about it.
        snap = try await e.deleteLabel(l2)
        XCTAssertEqual(snap.pending, 0)
        XCTAssertTrue(mutationRequests.isEmpty)
    }

    func testLabelCreateAddRenameDeleteGoOutInOrderWithVersions() async throws {
        let l2 = UUID()
        var labelVersion = 0
        serve(feed: baseFeed(), mutation: { [self] m in
            switch m["type"] as! String {
            case "label.create": labelVersion = 1; return ok14(m, label: labelJSON(l2, m["name"] as! String, version: 1), status: 201)
            case "task.label_add": return ok14(m, label: labelJSON(l2, "Neu", version: labelVersion, tasks: [t1]))
            case "label.rename": labelVersion += 1; return ok14(m, label: labelJSON(l2, m["name"] as! String, version: labelVersion, tasks: [t1]))
            default: return ok14(m, deleted: true)
            }
        })
        let e = try engine()
        _ = try await e.sync()
        try await e.addLabel(named: "Neu", to: t1)
        var r = try await e.sync()
        XCTAssertEqual(r.pushed, 2)
        XCTAssertEqual(mutationRequests.map { $0["type"] as? String }, ["label.create", "task.label_add"])
        var snap = await e.snapshot()
        XCTAssertEqual(snap.labels.first?.taskIDs, [t1])
        let created = try XCTUnwrap(snap.labels.first?.id)
        // The same name afterwards reuses the label (no second create).
        try await e.addLabel(named: "neu", to: t2)
        XCTAssertEqual(snap.labels.count, 1)
        try await e.renameLabel(created, name: "Umbenannt")
        r = try await e.sync()
        XCTAssertEqual(r.pushed, 2)
        XCTAssertEqual(mutationRequests.suffix(2).map { $0["type"] as? String }, ["task.label_add", "label.rename"])
        XCTAssertEqual(mutationRequests.last?["version"] as? Int, 1)
        try await e.deleteLabel(created)
        r = try await e.sync()
        snap = await e.snapshot()
        XCTAssertTrue(snap.labels.isEmpty)
        XCTAssertEqual(mutationRequests.last?["type"] as? String, "label.delete")
    }

    func testAddLabelOnTaskCreatedOfflineWaitsInOrder() async throws {
        let l1 = UUID(), tNew = UUID()
        serve(feed: baseFeed(extra: [upsertLabel(4, l1, "A")]), mutation: { [self] m in
            m["type"] as! String == "task.create" ? ok14(m, task: taskJSON(tNew, title: "N"), status: 201) : ok14(m, label: labelJSON(l1, "A", tasks: [tNew]))
        })
        let e = try engine()
        _ = try await e.sync()
        try await e.createTask(id: tNew, projectID: pid, title: "N")
        try await e.setPlanning(tNew, PlanningData(priority: 1))
        try await e.setLabel(l1, on: tNew, enabled: true)
        _ = try await e.sync()
        XCTAssertEqual(mutationRequests.map { $0["type"] as? String }, ["task.create", "task.planning", "task.label_add"])
        XCTAssertEqual(mutationRequests[1]["version"] as? Int, 1, "version is taken from the confirmed task at send time")
    }

    // MARK: Conflicts and refusals

    func testPlanningConflictIsRetriedOnceOnTheFeedVersionThenAsksTheUser() async throws {
        var feedCalls = 0
        var attempts = 0
        serve(feed: { [self] c in
            if c == "c0" { return page([upsertProject(1, pid), upsertTaskPlanned(2, t1)], cursor: "c2") }
            feedCalls += 1
            return feedCalls == 1 ? page([upsertTaskPlanned(3, t1, version: 5, priority: 1)], cursor: "c3") : page([], cursor: "c3")
        }, mutation: { [self] m in
            attempts += 1
            if (m["version"] as? Int) == 5 { return ok14(m, task: taskJSON(t1, version: 6), planning: planningJSON(priority: 2)) }
            return err(409, "version_conflict")
        })
        let e = try engine()
        _ = try await e.sync()
        try await e.setPlanning(t1, PlanningData(priority: 2))
        let r = try await e.sync()
        XCTAssertEqual(r.pushed, 1)
        XCTAssertEqual(r.conflicts, 0)
        XCTAssertEqual(mutationRequests.compactMap { $0["version"] as? Int }, [1, 5], "second attempt carries the version from the feed")
        let snap = await e.snapshot()
        XCTAssertEqual(snap.planning[t1]?.priority, 2)
        XCTAssertEqual(snap.tasks.first?.version, 6)

        // Persistent conflict: after the single automatic retry the user decides.
        MockURLProtocol.seen = []
        serve(feed: { [self] c in page([upsertTaskPlanned(9, t1, version: 7)], cursor: "c9") }, mutation: { _ in self.err(409, "version_conflict") })
        try await e.setPlanning(t1, PlanningData(priority: 3))
        let r2 = try await e.sync()
        XCTAssertEqual(r2.conflicts, 1)
        XCTAssertEqual(mutationRequests.count, 2)
    }

    func testRefusedPlanningIsRejectedWithReason() async throws {
        serve(feed: baseFeed(), mutation: { [self] _ in err(403, "forbidden") })
        let e = try engine()
        _ = try await e.sync()
        try await e.setPlanning(t1, PlanningData(priority: 1))
        try await e.setLabel(UUID(), on: t2, enabled: true)
        let r = try await e.sync()
        XCTAssertEqual(r.rejected, 2)
        let snap = await e.snapshot()
        XCTAssertEqual(snap.rejected.first?.reason, "forbidden")
        XCTAssertNil(snap.metaOverlay.planning[t1], "rejected edits no longer show")
        let unsupported = await e.unsupportedMutations()
        XCTAssertTrue(unsupported.isEmpty, "a refusal is not the older-server fallback")
    }

    func testRemoveOfGoneLabelCountsAsDone() async throws {
        let l1 = UUID()
        serve(feed: baseFeed(extra: [upsertLabel(4, l1, "A", tasks: [t1])]), mutation: { [self] _ in (404, Data(#"{"error":true,"reason":"not_found"}"#.utf8)) })
        let e = try engine()
        _ = try await e.sync()
        try await e.setLabel(l1, on: t1, enabled: false)
        let r = try await e.sync()
        XCTAssertEqual(r.rejected, 0); XCTAssertEqual(r.pushed, 1)
    }

    // MARK: Older servers

    func testUnknownMutationTypeFallsBackAndNothingIsLost() async throws {
        let l1 = UUID()
        serve(feed: { [self] c in page([upsertProject(1, pid), upsertTask(2, t1)], cursor: "c2") }, mutation: { [self] m in
            (m["type"] as! String).hasPrefix("task.update") ? mutationResult(m, task: taskJSON(t1, version: 2)) : err(400, "unknown_mutation_type")
        })
        let e = try engine()
        _ = try await e.sync()
        let s0 = await e.planningSyncSupport
        XCTAssertEqual(s0, .unsupported, "feed task upserts without planning mark an older server")
        try await e.setPlanning(t1, PlanningData(dueAt: Date(timeIntervalSince1970: 1_800_000_000), priority: 2))
        try await e.createLabel(id: l1, name: "Alt")
        try await e.setLabel(l1, on: t1, enabled: true)
        try await e.updateTask(t1, TaskUpdate(title: "weiter"))
        let r = try await e.sync()
        XCTAssertTrue(r.legacyFallback)
        XCTAssertEqual(mutationRequests.map { $0["type"] as? String }, ["task.update"], "no request for the 1.4.0 types once the server is known to be old")
        let parked = await e.unsupportedMutations()
        XCTAssertEqual(parked.count, 3)
        XCTAssertEqual(parked.first?.reason, unsupportedByServerReason)

        // The app hands them to the REST outbox.
        let outbox = PlanningOutbox(store: InMemoryOutboxStore())
        await outbox.adopt(parked.map(\.mutation))
        let ops = await outbox.pendingOps()
        XCTAssertEqual(ops.map(\.kind), [.setPlanning, .addLabelNamed])
        XCTAssertEqual(ops[0].planning?.priority, 2)
        XCTAssertEqual(ops[1].labelName, "Alt")
        for q in parked { _ = try await e.dismiss(q.id) }
        let snap = await e.snapshot()
        XCTAssertTrue(snap.rejected.isEmpty)
    }

    func testFirstMutationProbesAnOldServerWhenTheFeedIsEmpty() async throws {
        serve(feed: { [self] c in page([], cursor: "c0") }, mutation: { [self] _ in err(400, "unknown_mutation_type") })
        let store = InMemorySyncStore()
        let e = try engine(store: store)
        // Entities known from an earlier session (no tasks delivered in this feed pass).
        var s = SyncState(); s.projects[pid] = Project(id: pid, parentID: nil, name: "P", version: 1)
        s.tasks[t1] = TodoTask(id: t1, projectID: pid, title: "T", description: "", status: "open", version: 1)
        try store.commit({ var b = SyncBatch(); b.projectUpserts = [s.projects[pid]!]; b.taskUpserts = [s.tasks[t1]!]; return b }())
        let e2 = try engine(store: store)
        _ = e
        let support0 = await e2.planningSyncSupport
        XCTAssertEqual(support0, .unknown)
        try await e2.setPlanning(t1, PlanningData(priority: 1))
        let r = try await e2.sync()
        XCTAssertTrue(r.legacyFallback)
        let support1 = await e2.planningSyncSupport
        XCTAssertEqual(support1, .unsupported)
        let parked = await e2.unsupportedMutations()
        XCTAssertEqual(parked.count, 1)
    }

    func testOutboxEntriesMoveIntoTheQueueInOrder() async throws {
        let l1 = UUID()
        serve(feed: baseFeed(extra: [upsertLabel(4, l1, "Haus")]), mutation: { [self] m in ok14(m, task: taskJSON(t1, version: 2), planning: planningJSON(priority: 2), label: labelJSON(l1, "Haus", tasks: [t1])) })
        let outbox = PlanningOutbox(store: InMemoryOutboxStore())
        await outbox.setPlanning(taskID: t1, PlanningData(priority: 1))
        await outbox.addLabel(named: "haus", toTask: t1)
        await outbox.removeLabel(l1, fromTask: t2)
        let e = try engine()
        _ = try await e.sync()
        for op in await outbox.pendingOps() {
            switch op.kind {
            case .setPlanning: try await e.setPlanning(op.taskID, op.planning!)
            case .addLabelNamed: try await e.addLabel(named: op.labelName!, to: op.taskID)
            case .removeLabel: try await e.setLabel(op.labelID!, on: op.taskID, enabled: false)
            case .addLabel: try await e.setLabel(op.labelID!, on: op.taskID, enabled: true)
            }
            await outbox.dismiss(op.id)
        }
        let remaining = await outbox.pendingOps()
        XCTAssertTrue(remaining.isEmpty)
        let r = try await e.sync()
        XCTAssertEqual(r.pushed, 3, "name matched the existing label: no create")
        XCTAssertEqual(mutationRequests.map { $0["type"] as? String }, ["task.planning", "task.label_add", "task.label_remove"])
    }

    // MARK: Store

    func testQueueRowsWithoutAutoRetriesStillDecode() throws {
        let json = #"{"mutation":{"mutationID":"\#(UUID())","type":"task.update","id":"\#(t1)"},"order":1,"chained":false,"status":"pending","idRegenerated":false,"createdAt":0}"#
        let q = try JSONDecoder().decode(QueuedMutation.self, from: Data(json.utf8))
        XCTAssertNil(q.autoRetries)
        XCTAssertNil(q.mutation.priority)
    }

    func testSQLiteStoreMigratesSchema2AdditivelyAndPersistsPlanningAndLabels() throws {
        let path = NSTemporaryDirectory() + "mig-\(UUID().uuidString).sqlite"
        defer { for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + ext) } }
        // A schema-2 database as an older build wrote it: no planning/labels tables, a cursor, a task, a queued mutation.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let task = TodoTask(id: t1, projectID: pid, title: "Alt", description: "", status: "open", version: 3)
        let taskJSON = String(data: try JSONEncoder().encode(task), encoding: .utf8)!.replacingOccurrences(of: "'", with: "''")
        let queued = QueuedMutation(mutation: SyncMutation(type: .taskUpdate, id: t1, title: "offline"), order: 1, chained: false)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let queueJSON = String(data: try enc.encode(queued), encoding: .utf8)!.replacingOccurrences(of: "'", with: "''")
        let sql = """
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE projects (id TEXT PRIMARY KEY, json BLOB NOT NULL);
            CREATE TABLE tasks (id TEXT PRIMARY KEY, json BLOB NOT NULL);
            CREATE TABLE columns (id TEXT PRIMARY KEY, json BLOB NOT NULL);
            CREATE TABLE ranks (id TEXT PRIMARY KEY, rank INTEGER NOT NULL);
            CREATE TABLE queue (mutation_id TEXT PRIMARY KEY, ord INTEGER NOT NULL, json BLOB NOT NULL);
            INSERT INTO meta VALUES ('schema', '2'), ('cursor', 'c42');
            INSERT INTO tasks VALUES ('\(t1.uuidString)', '\(taskJSON)');
            INSERT INTO queue VALUES ('\(queued.id.uuidString)', 1, '\(queueJSON)');
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = try SQLiteSyncStore(path: path)
        var state = try store.load()
        XCTAssertEqual(state.tasks[t1]?.title, "Alt", "cached entities stay")
        XCTAssertEqual(state.queue.map(\.id), [queued.id], "the offline queue is kept")
        XCTAssertEqual(state.cursor, "c0", "feed restarts once so planning and labels arrive")
        var batch = SyncBatch()
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        batch.planningUpserts[t1] = PlanningData(dueAt: due, priority: 2, recurrence: RecurrenceRule(frequency: .daily, interval: 2, timeZone: "UTC"), reminders: [due])
        batch.labelUpserts = [SyncLabel(id: t2, name: "L", version: 4, taskIDs: [t1])]
        try store.commit(batch)
        state = try SQLiteSyncStore(path: path).load()
        XCTAssertEqual(state.planning[t1]?.priority, 2)
        XCTAssertEqual(state.planning[t1]?.recurrence?.interval, 2)
        XCTAssertEqual(state.labels[t2]?.taskIDs, [t1])
        var del = SyncBatch(); del.planningDeletes = [t1]; del.labelDeletes = [t2]
        try store.commit(del)
        state = try store.load()
        XCTAssertTrue(state.planning.isEmpty && state.labels.isEmpty)
    }
}
