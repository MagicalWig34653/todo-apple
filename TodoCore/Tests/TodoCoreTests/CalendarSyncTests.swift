import XCTest

@testable import TodoCore

/// Calendar writes in the sync queue (card 8CECAD24, phase 2; contract sync 1.5.0): `task.planning` carries
/// `plannedMinutes` and `plannedAllDay`, the engine builds the full replacement from the card's current planning, and a
/// 409 on replay is shown instead of silently overwriting the other person's change.
extension SyncEngineTests {
    private func plannedJSON(start: String?, minutes: Int?, allDay: Bool = false, due: String? = nil, priority: Int = 0) -> String {
        let q = { (v: String?) in v.map { "\"\($0)\"" } ?? "null" }
        return #"{"dueAt":\#(q(due)),"plannedAt":\#(q(start)),"plannedMinutes":\#(minutes.map(String.init) ?? "null"),"plannedAllDay":\#(allDay),"priority":\#(priority),"reminders":[]}"#
    }
    private func plannedUpsert(_ seq: Int, _ id: UUID, version: Int = 1, planning: String) -> String {
        #"{"seq":\#(seq),"entityType":"task","entityID":"\#(id)","kind":"upsert","task":\#(taskJSON(id, version: version)),"planning":\#(planning)}"#
    }
    private func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private func plannedEngine(start: String? = "2026-11-23T09:00:00Z", minutes: Int? = 45, allDay: Bool = false) async throws -> SyncEngine {
        let planning = plannedJSON(start: start, minutes: minutes, allDay: allDay, due: "2026-11-25T17:00:00Z", priority: 2)
        serve(feed: { [self] c in c == "c0" ? page([upsertProject(1, pid), plannedUpsert(2, t1, planning: planning)], cursor: "c2") : page([], cursor: c) },
              mutation: { [self] m in ok14(m, task: taskJSON(t1, version: 2), planning: plannedJSON(start: "2026-11-24T10:15:00Z", minutes: 45, due: "2026-11-25T17:00:00Z", priority: 2)) })
        let e = try engine()
        _ = try await e.sync()
        return e
    }

    func testMutationFromScheduleCarriesDurationAndAllDayAndPlainPlanningStillDoesNot() throws {
        let data = PlanningData(plannedAt: at("2026-11-24T10:15:00Z"), priority: 1, plannedMinutes: 45, plannedAllDay: false)
        let schedule = SyncMutation.schedule(taskID: t1, data)
        XCTAssertEqual(schedule.type, .taskPlanning)
        XCTAssertEqual(schedule.plannedMinutes, 45)
        XCTAssertEqual(schedule.plannedAllDay, false)
        let plain = SyncMutation.planning(taskID: t1, data)
        XCTAssertNil(plain.plannedMinutes, "existing planning edits keep the 1.4.0 wire: the server keeps duration and all-day")
        XCTAssertNil(plain.plannedAllDay)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let wire = try JSONSerialization.jsonObject(with: e.encode(schedule)) as? [String: Any]
        XCTAssertEqual(wire?["plannedMinutes"] as? Int, 45)
        XCTAssertEqual(wire?["plannedAllDay"] as? Bool, false)
        // A queue persisted by an older build (no such keys) still decodes.
        let old = try JSONDecoder().decode(SyncMutation.self, from: Data(#"{"mutationID":"\#(UUID())","type":"task.planning","id":"\#(t1)","priority":1,"reminders":[]}"#.utf8))
        XCTAssertNil(old.plannedMinutes)
        XCTAssertNil(old.plannedAllDay)
    }

    func testQueuedMoveSendsAFullReplacementWithDurationAndKeepsTheRest() async throws {
        let e = try await plannedEngine()
        let snap = try await e.setSchedule(t1, SchedulePatch(plannedAt: .set(at("2026-11-24T10:15:00Z"))))
        XCTAssertEqual(snap.pending, 1)
        XCTAssertEqual(snap.metaOverlay.planning[t1]?.plannedAt, at("2026-11-24T10:15:00Z"), "optimistic")
        XCTAssertEqual(snap.metaOverlay.planning[t1]?.plannedMinutes, 45, "duration stays in the overlay")
        XCTAssertEqual(snap.planning[t1]?.plannedAt, at("2026-11-23T09:00:00Z"), "confirmed state untouched until the server answered")
        _ = try await e.sync()
        let body = try XCTUnwrap(mutationRequests.first)
        XCTAssertEqual(body["type"] as? String, "task.planning")
        XCTAssertEqual(body["version"] as? Int, 1)
        XCTAssertEqual(body["plannedAt"] as? String, "2026-11-24T10:15:00Z")
        XCTAssertEqual(body["plannedMinutes"] as? Int, 45)
        XCTAssertEqual(body["plannedAllDay"] as? Bool, false)
        XCTAssertEqual(body["dueAt"] as? String, "2026-11-25T17:00:00Z", "dueAt is carried unchanged, never moved")
        XCTAssertEqual(body["priority"] as? Int, 2)
        let after = await e.snapshot()
        XCTAssertEqual(after.planning[t1]?.plannedAt, at("2026-11-24T10:15:00Z"))
        XCTAssertEqual(after.pending, 0)
    }

    func testQueuedAllDayAndDurationAndUnschedule() async throws {
        let e = try await plannedEngine()
        var snap = try await e.setSchedule(t1, SchedulePatch(plannedAt: .set(at("2026-11-24T00:00:00Z")), plannedAllDay: true))
        XCTAssertEqual(snap.metaOverlay.planning[t1]?.plannedAllDay, true)
        snap = try await e.setSchedule(t1, SchedulePatch(plannedMinutes: .set(90)))
        XCTAssertEqual(snap.pending, 1, "a later edit of the same card replaces the queued one")
        XCTAssertEqual(snap.metaOverlay.planning[t1]?.plannedMinutes, 90)
        XCTAssertEqual(snap.metaOverlay.planning[t1]?.plannedAllDay, true, "the second edit builds on the first, not on the confirmed state")
        _ = try await e.sync()
        XCTAssertEqual(mutationRequests.count, 1)
        XCTAssertEqual(mutationRequests[0]["plannedMinutes"] as? Int, 90)
        XCTAssertEqual(mutationRequests[0]["plannedAllDay"] as? Bool, true)

        MockURLProtocol.seen = []
        snap = try await e.setSchedule(t1, SchedulePatch(plannedAt: .clear))
        XCTAssertNil(snap.metaOverlay.planning[t1]?.plannedAt)
        XCTAssertNil(snap.metaOverlay.planning[t1]?.plannedMinutes, "clearing the start clears the duration")
        XCTAssertEqual(snap.metaOverlay.planning[t1]?.plannedAllDay, false)
        _ = try await e.sync()
        let body = try XCTUnwrap(mutationRequests.first)
        XCTAssertNil(body["plannedAt"], "absent start clears it on the server")
        XCTAssertNil(body["plannedMinutes"])
        XCTAssertEqual(body["plannedAllDay"] as? Bool, false)
        XCTAssertEqual(body["dueAt"] as? String, "2026-11-25T17:00:00Z")
    }

    func testClearingOnlyTheDurationCannotBeQueued() async throws {
        let e = try await plannedEngine()
        do {
            _ = try await e.setSchedule(t1, SchedulePatch(plannedMinutes: .clear))
            XCTFail("a null duration is not part of the queue wire")
        } catch { XCTAssertEqual(error as? ScheduleError, .notAvailableOffline) }
        let snap = await e.snapshot()
        XCTAssertEqual(snap.pending, 0, "nothing was queued")
    }

    func testScheduleOfAnUnknownTaskIsRefused() async throws {
        let e = try await plannedEngine()
        do {
            _ = try await e.setSchedule(UUID(), SchedulePatch(plannedAt: .clear))
            XCTFail("unknown task")
        } catch { XCTAssertEqual(error as? ScheduleError, .notFound) }
    }

    func testReplayConflictIsShownAndNotRetriedSilently() async throws {
        let planning = plannedJSON(start: "2026-11-23T09:00:00Z", minutes: 45)
        var feedRounds = 0
        serve(feed: { [self] c in
            if c == "c0" { return page([upsertProject(1, pid), plannedUpsert(2, t1, planning: planning)], cursor: "c2") }
            feedRounds += 1
            // The other person moved the card meanwhile: newer version, other start.
            return feedRounds == 1 ? page([plannedUpsert(3, t1, version: 2, planning: plannedJSON(start: "2026-11-23T15:00:00Z", minutes: 45))], cursor: "c3") : page([], cursor: c)
        }, mutation: { [self] _ in err(409, "version_conflict") })
        let e = try engine()
        _ = try await e.sync()
        try await e.setSchedule(t1, SchedulePatch(plannedAt: .set(at("2026-11-24T10:15:00Z"))))
        let report = try await e.sync()
        XCTAssertEqual(mutationRequests.count, 1, "a calendar move is not retried on the newer version without asking")
        XCTAssertEqual(report.conflicts, 1)
        let snap = await e.snapshot()
        XCTAssertEqual(snap.conflicts.count, 1)
        XCTAssertEqual(snap.conflicts.first?.reason, "version_conflict")
        XCTAssertEqual(snap.conflicts.first?.mutation.plannedAt, at("2026-11-24T10:15:00Z"), "my move is kept to choose from")
        XCTAssertEqual(snap.metaOverlay.planning[t1]?.plannedAt, nil, "while it is in conflict the card shows the server state")
        XCTAssertEqual(snap.planning[t1]?.plannedAt, at("2026-11-23T15:00:00Z"))
    }

    func testPlainPlanningEditStillRetriesOnceAfterAConflict() async throws {
        // Unchanged behaviour of the 1.4.0 edit (priority, due date): the newest local edit wins after one refresh.
        var mutations = 0
        serve(feed: { [self] c in c == "c0" ? page([upsertProject(1, pid), upsertTaskPlanned(2, t1)], cursor: "c2") : page([upsertTaskPlanned(3, t1, version: 2)], cursor: "c3") },
              mutation: { [self] m in
                  mutations += 1
                  return mutations == 1 ? err(409, "version_conflict") : ok14(m, task: taskJSON(t1, version: 3), planning: planningJSON(priority: 3))
              })
        let e = try engine()
        _ = try await e.sync()
        try await e.setPlanning(t1, PlanningData(priority: 3))
        _ = try await e.sync()
        XCTAssertEqual(mutations, 2)
    }

    func testKeepMineAfterAConflictSendsTheMoveOnTheNewVersion() async throws {
        var mutations = 0
        var pulls = 0
        serve(feed: { [self] c in
            if c == "c0" { return page([upsertProject(1, pid), plannedUpsert(2, t1, planning: plannedJSON(start: "2026-11-23T09:00:00Z", minutes: 45))], cursor: "c2") }
            pulls += 1
            return pulls == 1 ? page([plannedUpsert(3, t1, version: 2, planning: plannedJSON(start: "2026-11-23T15:00:00Z", minutes: 45))], cursor: "c3") : page([], cursor: c)
        }, mutation: { [self] m in
            mutations += 1
            return mutations == 1 ? err(409, "version_conflict")
                : ok14(m, task: taskJSON(t1, version: 3), planning: plannedJSON(start: "2026-11-24T10:15:00Z", minutes: 45))
        })
        let e = try engine()
        _ = try await e.sync()
        try await e.setSchedule(t1, SchedulePatch(plannedAt: .set(at("2026-11-24T10:15:00Z"))))
        _ = try await e.sync()
        let stopped = await e.snapshot()
        let conflict = try XCTUnwrap(stopped.conflicts.first)
        try await e.resolveConflict(conflict.id, keepMine: true)
        _ = try await e.sync()
        XCTAssertEqual(mutationRequests.last?["version"] as? Int, 2, "re-sent on top of the server's version")
        XCTAssertEqual(mutationRequests.last?["plannedAt"] as? String, "2026-11-24T10:15:00Z")
        let after = await e.snapshot()
        XCTAssertTrue(after.conflicts.isEmpty)
        XCTAssertEqual(after.planning[t1]?.plannedAt, at("2026-11-24T10:15:00Z"))
    }

    func testFeedPlanningWithDurationReachesTheSnapshotAndTheStore() async throws {
        let e = try await plannedEngine(start: "2026-11-23T09:00:00Z", minutes: 60, allDay: false)
        let snap = await e.snapshot()
        XCTAssertEqual(snap.planning[t1]?.plannedMinutes, 60)
        let again = try engine()
        let persisted = await again.snapshot()
        XCTAssertEqual(persisted.planning[t1]?.plannedMinutes, 60, "persisted with the planning row")
    }
}
