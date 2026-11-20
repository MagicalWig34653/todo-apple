import Foundation
import XCTest

@testable import TodoCore

/// Opt-in (see `LiveEtappe2Tests`): the calendar client against the native backend (planning-ext 1.2.0, sync 1.5.0) with a fresh
/// SQLite database, card 8CECAD24 phase 2. First real run of the `/v1/planning/schedule` and `/unscheduled` answers against the
/// client types; the rest of the suite only saw mocks. Auto-start stays off (no job is ever started).
extension LiveEtappe2Tests {
    private func minute(_ offsetMinutes: Int = 0, daysAhead: Int = 3) -> Date {
        // A whole quarter hour a few days ahead, so nothing is "in the past" and seconds never matter.
        let base = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 900).rounded(.down) * 900)
        return base.addingTimeInterval(TimeInterval(daysAhead * 86_400 + offsetMinutes * 60))
    }

    private func window(around date: Date) -> (Date, Date) { (date.addingTimeInterval(-86_400), date.addingTimeInterval(2 * 86_400)) }

    private func entry(_ c: APIClient, _ id: UUID, around date: Date) async throws -> ScheduleEntry? {
        let (from, to) = window(around: date)
        return try await c.schedule(from: from, to: to).items.first { $0.taskID == id }
    }

    private func must(_ c: APIClient, _ id: UUID, around date: Date, file: StaticString = #filePath, line: UInt = #line) async throws -> ScheduleEntry {
        guard let found = try await entry(c, id, around: date) else { throw XCTSkip("entry missing", file: file, line: line) }
        return found
    }

    private func makeCard(_ f: Fixture, _ title: String) async throws -> (Project, TodoTask) {
        let p = try await f.admin.createProject(name: "Kal \(title) \(f.suffix)")
        let t = try await f.admin.createTask(projectID: p.id, title: title)
        return (p, t)
    }

    // MARK: Real answer shapes, move, all-day, duration, unschedule, persistence

    func testLiveCalendarMoveAllDayDurationUnscheduleAndPersistence() async throws {
        let f = try await fixture()
        let (project, task) = try await makeCard(f, "Verschieben")
        let due = minute(480)  // due date, later than every planned slot below
        _ = try await f.admin.setPlanning(taskID: task.id, PlanningData(dueAt: due, priority: 2))

        // Unscheduled card appears in the sidebar list.
        let before = try await f.admin.unscheduled(projectID: project.id)
        XCTAssertEqual(before.map(\.task.id), [task.id])
        XCTAssertNil(before.first?.planning.plannedAt)
        XCTAssertFalse(before.first?.planning.autoStart ?? true, "auto-start stays off in the test backend")

        // Sidebar -> grid: start only (duration stays unset = 30 minutes shown).
        let start = minute(0)
        var current = try await f.admin.planning(taskID: task.id)
        var result = try await f.admin.updateSchedule(taskID: task.id, version: current.task.version, SchedulePatch(plannedAt: .set(start), plannedAllDay: false))
        XCTAssertEqual(result.planning.plannedAt, start)
        XCTAssertNil(result.planning.plannedMinutes)
        XCTAssertFalse(result.planning.plannedAllDay)
        XCTAssertEqual(result.planning.dueAt, due, "dragging never touches dueAt")
        XCTAssertEqual(result.planning.priority, 2, "priority untouched")
        XCTAssertEqual(result.task.version, current.task.version + 1)

        var e = try await must(f.admin, task.id, around: start)
        XCTAssertEqual(e.plannedAt, start)
        XCTAssertEqual(e.minutes, 30)
        XCTAssertTrue(e.canEdit)
        XCTAssertFalse(e.autoStart)
        XCTAssertNil(e.autoStartedAt)
        XCTAssertEqual(e.version, result.task.version, "the entry carries the version for the next PATCH")
        XCTAssertEqual(e.projectID, project.id)
        XCTAssertEqual(e.dueAt, due)
        let stillUnscheduled = try await f.admin.unscheduled(projectID: project.id)
        XCTAssertTrue(stillUnscheduled.isEmpty, "planned cards leave the sidebar")

        // Grid -> grid with duration; start moves, duration is the new value.
        let moved = minute(120)
        result = try await f.admin.updateSchedule(taskID: task.id, version: e.version, SchedulePatch(plannedAt: .set(moved), plannedMinutes: .set(90)))
        e = try await must(f.admin, task.id, around: moved)
        XCTAssertEqual(e.plannedAt, moved)
        XCTAssertEqual(e.plannedMinutes, 90)
        XCTAssertEqual(e.end, moved.addingTimeInterval(5400))

        // Resize only: start and all-day untouched.
        result = try await f.admin.updateSchedule(taskID: task.id, version: e.version, SchedulePatch(plannedMinutes: .set(45)))
        e = try await must(f.admin, task.id, around: moved)
        XCTAssertEqual(e.plannedAt, moved)
        XCTAssertEqual(e.plannedMinutes, 45)

        // All-day: start of the day, flag set.
        let dayStart = Calendar.current.startOfDay(for: moved)
        result = try await f.admin.updateSchedule(taskID: task.id, version: e.version, SchedulePatch(plannedAt: .set(dayStart), plannedAllDay: true))
        e = try await must(f.admin, task.id, around: moved)
        XCTAssertTrue(e.plannedAllDay)
        XCTAssertEqual(e.plannedAt, dayStart)

        // All-day -> grid: all-day off again at the drop time.
        result = try await f.admin.updateSchedule(taskID: task.id, version: e.version, SchedulePatch(plannedAt: .set(moved), plannedAllDay: false))
        e = try await must(f.admin, task.id, around: moved)
        XCTAssertFalse(e.plannedAllDay)
        XCTAssertEqual(e.plannedAt, moved)

        // Conflict marker computed by the server and by the client rules agree: ends after the due date? (it does not here)
        XCTAssertFalse(CalendarConflicts.conflicts(for: e, among: [e]).contains(.afterDue))
        XCTAssertFalse(e.conflicts.contains(.afterDue))

        // Persistence: a brand-new client (fresh start) sees exactly this.
        let fresh = APIClient(baseURL: f.admin.baseURL, tokenStore: f.adminStore)
        let persisted = try await must(fresh, task.id, around: moved)
        XCTAssertEqual(persisted.plannedAt, moved)
        XCTAssertEqual(persisted.plannedMinutes, 45)
        XCTAssertEqual(persisted.dueAt, due)

        // Unschedule: start gone, duration and all-day gone with it, card back in the sidebar, due date still there.
        result = try await f.admin.updateSchedule(taskID: task.id, version: persisted.version, SchedulePatch(plannedAt: .clear))
        XCTAssertNil(result.planning.plannedAt)
        XCTAssertNil(result.planning.plannedMinutes)
        XCTAssertFalse(result.planning.plannedAllDay)
        XCTAssertEqual(result.planning.dueAt, due)
        let back = try await fresh.unscheduled(projectID: project.id)
        XCTAssertEqual(back.map(\.task.id), [task.id])
        let dueOnly = try await must(fresh, task.id, around: moved)
        XCTAssertNil(dueOnly.plannedAt, "without a start the card is in the window only through its due date")
        XCTAssertEqual(dueOnly.dueAt, due)
        XCTAssertNil(dueOnly.plannedMinutes)
    }

    func testLiveCalendarFixedDueDateAppearsAsEntryAndAfterDueConflictAgrees() async throws {
        let f = try await fixture()
        let (_, task) = try await makeCard(f, "Nach Frist")
        let start = minute(0, daysAhead: 4), due = minute(10, daysAhead: 4)
        _ = try await f.admin.setPlanning(taskID: task.id, PlanningData(dueAt: due))
        let version = try await f.admin.planning(taskID: task.id).task.version
        _ = try await f.admin.updateSchedule(taskID: task.id, version: version, SchedulePatch(plannedAt: .set(start), plannedMinutes: .set(60)))
        let e = try await must(f.admin, task.id, around: start)
        XCTAssertEqual(e.conflicts.contains(.afterDue), true, "end 60 minutes after start is behind the due date 10 minutes after start")
        XCTAssertTrue(CalendarConflicts.conflicts(for: e, among: [e]).contains(.afterDue), "client and server agree")
        XCTAssertTrue(CalendarConflicts.isAfterDue(e))
    }

    func testLiveCalendarTypedErrors() async throws {
        let f = try await fixture()
        let (_, task) = try await makeCard(f, "Fehler")
        let start = minute(0, daysAhead: 5)
        var v = try await f.admin.planning(taskID: task.id).task.version

        func expect(_ expected: ScheduleError, _ patch: SchedulePatch, version: Int? = nil, file: StaticString = #filePath, line: UInt = #line) async {
            do {
                _ = try await f.admin.updateSchedule(taskID: task.id, version: version ?? v, patch)
                XCTFail("expected \(expected)", file: file, line: line)
            } catch let error as ScheduleError { XCTAssertEqual(error, expected, file: file, line: line) } catch { XCTFail("\(error)", file: file, line: line) }
        }
        await expect(.invalidPlannedMinutes, SchedulePatch(plannedAt: .set(start), plannedMinutes: .set(4)))
        await expect(.invalidPlannedMinutes, SchedulePatch(plannedAt: .set(start), plannedMinutes: .set(1441)))
        await expect(.allDayRequiresPlannedAt, SchedulePatch(plannedAllDay: true))
        await expect(.versionConflict, SchedulePatch(plannedAt: .set(start)), version: v + 5)

        // Repeating card without due date keeps its start (the server says so; the client rule refuses before sending).
        // (The server refuses a repeating card with neither due date nor start, so it gets a start and no due date.)
        let planned = try await f.admin.setPlanning(taskID: task.id, PlanningData(plannedAt: start, recurrence: RecurrenceRule(frequency: .weekly, timeZone: "Europe/Berlin")))
        XCTAssertNotNil(planned.planning.plannedAt)
        v = planned.task.version
        await expect(.recurrenceRequiresDate, SchedulePatch(plannedAt: .clear))
        let repeating = try await must(f.admin, task.id, around: start)
        XCTAssertEqual(CalendarDrop.decide(repeating, onto: .unscheduled, hasRecurrence: true), .refused(.recurrenceNeedsDate))

        // Done cards are not moved.
        let (_, done) = try await makeCard(f, "Erledigt")
        let doneVersion = try await f.admin.planning(taskID: done.id).task.version
        _ = try await f.admin.updateSchedule(taskID: done.id, version: doneVersion, SchedulePatch(plannedAt: .set(start)))
        let planned2 = try await f.admin.planning(taskID: done.id).task
        _ = try await f.admin.updateTask(done.id, version: planned2.version, TaskUpdate(status: .done))
        let doneNow = try await f.admin.planning(taskID: done.id).task.version
        do {
            _ = try await f.admin.updateSchedule(taskID: done.id, version: doneNow, SchedulePatch(plannedAt: .clear))
            XCTFail("done card was moved")
        } catch let error as ScheduleError { XCTAssertEqual(error, .taskDone) }
        let doneEntry = try await must(f.admin, done.id, around: start)
        XCTAssertTrue(doneEntry.isDone, "done cards stay visible in the window")
        XCTAssertFalse(doneEntry.canDrag)

        // Window errors.
        do { _ = try await f.admin.schedule(from: start, to: start); XCTFail("empty window") } catch let error as ScheduleError { XCTAssertEqual(error, .invalidWindow) }
        do { _ = try await f.admin.schedule(from: start, to: start.addingTimeInterval(63 * 86_400)); XCTFail("63 days") } catch let error as ScheduleError { XCTAssertEqual(error, .windowTooLarge) }
        // Unknown card.
        do { _ = try await f.admin.updateSchedule(taskID: UUID(), version: 1, SchedulePatch(plannedAt: .clear)); XCTFail("unknown") } catch let error as ScheduleError { XCTAssertEqual(error, .notFound) }
    }

    // MARK: Roles: edit may move, read may not (canEdit), grants decide

    func testLiveCalendarRolesDecideWhoCanMove() async throws {
        let f = try await fixture()
        let (project, task) = try await makeCard(f, "Rolle")
        let start = minute(0, daysAhead: 6)
        let v0 = try await f.admin.planning(taskID: task.id).task.version
        _ = try await f.admin.updateSchedule(taskID: task.id, version: v0, SchedulePatch(plannedAt: .set(start)))

        _ = try await f.admin.setGrant(projectID: project.id, principalType: .person, principalID: f.bobUser.id, role: .read)
        let readOnly = try await must(f.bob, task.id, around: start)
        XCTAssertFalse(readOnly.canEdit, "read role: not draggable")
        XCTAssertFalse(readOnly.canDrag)
        let vis = try await f.bob.visibility(projectID: project.id)
        XCTAssertEqual(vis.role, .read, "the role the sidebar cards are classified by")
        do {
            _ = try await f.bob.updateSchedule(taskID: task.id, version: readOnly.version, SchedulePatch(plannedAt: .clear))
            XCTFail("a reader moved a card")
        } catch let error as ScheduleError { XCTAssertEqual(error, .readOnly) }

        _ = try await f.admin.setGrant(projectID: project.id, principalType: .person, principalID: f.bobUser.id, role: .edit)
        let editable = try await must(f.bob, task.id, around: start)
        XCTAssertTrue(editable.canEdit)
        let bobVisibility = try await f.bob.visibility(projectID: project.id)
        XCTAssertEqual(bobVisibility.role, .edit)
        let moved = try await f.bob.updateSchedule(taskID: task.id, version: editable.version, SchedulePatch(plannedAt: .set(start.addingTimeInterval(3600))))
        XCTAssertEqual(moved.planning.plannedAt, start.addingTimeInterval(3600))
    }

    // MARK: 409: a second client changes the card in between

    func testLiveCalendarSecondClientCausesVersionConflictAndReloadShowsTheirMove() async throws {
        let f = try await fixture()
        let (_, task) = try await makeCard(f, "Zweiter Client")
        let start = minute(0, daysAhead: 7)
        let v = try await f.admin.planning(taskID: task.id).task.version
        _ = try await f.admin.updateSchedule(taskID: task.id, version: v, SchedulePatch(plannedAt: .set(start)))
        let mine = try await must(f.admin, task.id, around: start)

        // The other device (same account) moves it first.
        let other = APIClient(baseURL: f.admin.baseURL, tokenStore: f.adminStore)
        _ = try await other.updateSchedule(taskID: task.id, version: mine.version, SchedulePatch(plannedAt: .set(start.addingTimeInterval(7200))))

        // My stale drop: rejected with the typed conflict; rollback = the inverse of the optimistic patch restores my view,
        // and the reload shows the other device's move.
        let patch = SchedulePatch(plannedAt: .set(start.addingTimeInterval(1800)))
        let optimistic = patch.applied(to: mine)
        XCTAssertEqual(optimistic.plannedAt, start.addingTimeInterval(1800))
        do {
            _ = try await f.admin.updateSchedule(taskID: task.id, version: mine.version, patch)
            XCTFail("stale version accepted")
        } catch let error as ScheduleError { XCTAssertEqual(error, .versionConflict) }
        let rolledBack = SchedulePatch.inverse(of: mine).applied(to: optimistic)
        XCTAssertEqual(rolledBack.plannedAt, mine.plannedAt)
        let reloaded = try await must(f.admin, task.id, around: start)
        XCTAssertEqual(reloaded.plannedAt, start.addingTimeInterval(7200), "the server kept the other device's move")
        XCTAssertGreaterThan(reloaded.version, mine.version)
    }

    // MARK: Offline queue: write offline, reconnect, check the server

    func testLiveCalendarOfflineQueueReplaysOnReconnectAndShowsTheConflictOfASecondEditor() async throws {
        let f = try await fixture()
        let (project, task) = try await makeCard(f, "Offline")
        let start = minute(0, daysAhead: 8), due = minute(600, daysAhead: 8)
        _ = try await f.admin.setPlanning(taskID: task.id, PlanningData(dueAt: due, priority: 3))
        let v = try await f.admin.planning(taskID: task.id).task.version
        _ = try await f.admin.updateSchedule(taskID: task.id, version: v, SchedulePatch(plannedAt: .set(start), plannedMinutes: .set(60)))

        // The device has synced once, then loses the network.
        let store = InMemorySyncStore()
        let online = try SyncEngine(client: f.admin, store: store)
        _ = try await online.sync()
        let known = await online.snapshot()
        XCTAssertEqual(known.planning[task.id]?.plannedMinutes, 60, "the real sync feed carries the duration (1.5.0)")
        XCTAssertEqual(known.planning[task.id]?.plannedAt, start)

        let dead = APIClient(baseURL: URL(string: "http://127.0.0.1:1")!, tokenStore: f.adminStore)
        let offline = try SyncEngine(client: dead, store: store)
        let target = start.addingTimeInterval(3 * 3600)
        let queued = try await offline.setSchedule(task.id, SchedulePatch(plannedAt: .set(target)))
        XCTAssertEqual(queued.metaOverlay.planning[task.id]?.plannedAt, target, "shown at once")
        XCTAssertEqual(queued.metaOverlay.planning[task.id]?.plannedMinutes, 60)
        let tried = try await offline.sync()
        XCTAssertTrue(tried.offline)
        let stillQueued = await offline.snapshot()
        XCTAssertEqual(stillQueued.pending, 1)
        let unchanged = try await must(f.admin, task.id, around: start)
        XCTAssertEqual(unchanged.plannedAt, start, "the server has not seen it yet")

        // Reconnect (new session over the same persisted queue): the move reaches the server.
        let back = try SyncEngine(client: f.admin, store: store)
        let report = try await back.sync()
        XCTAssertEqual(report.pushed, 1)
        XCTAssertEqual(report.conflicts, 0)
        let after = try await must(f.admin, task.id, around: start)
        XCTAssertEqual(after.plannedAt, target)
        XCTAssertEqual(after.plannedMinutes, 60, "duration kept through the full replacement")
        XCTAssertEqual(after.dueAt, due, "due date untouched")
        let planning = try await f.admin.planning(taskID: task.id)
        XCTAssertEqual(planning.planning.priority, 3, "priority untouched")

        // Offline all-day and unschedule go through the queue as well.
        let day = Calendar.current.startOfDay(for: target)
        let offline2 = try SyncEngine(client: dead, store: store)  // a new session: the queue is read from the store
        try await offline2.setSchedule(task.id, SchedulePatch(plannedAt: .set(day), plannedAllDay: true))
        _ = try await offline2.sync()
        let again = try SyncEngine(client: f.admin, store: store)
        _ = try await again.sync()
        let allDay = try await must(f.admin, task.id, around: start)
        XCTAssertTrue(allDay.plannedAllDay)
        XCTAssertEqual(allDay.plannedAt, day)

        // A second editor moves the card while my offline change is queued: the replay stops with a visible conflict.
        let task2 = try await f.admin.createTask(projectID: project.id, title: "Offline Konflikt")
        let v2 = try await f.admin.planning(taskID: task2.id).task.version
        _ = try await f.admin.updateSchedule(taskID: task2.id, version: v2, SchedulePatch(plannedAt: .set(start)))
        let store2 = InMemorySyncStore()
        let e2 = try SyncEngine(client: f.admin, store: store2)
        _ = try await e2.sync()
        let dead2 = try SyncEngine(client: dead, store: store2)
        try await dead2.setSchedule(task2.id, SchedulePatch(plannedAt: .set(start.addingTimeInterval(1800))))
        _ = try await dead2.sync()
        let other = APIClient(baseURL: f.admin.baseURL, tokenStore: f.adminStore)
        let theirVersion = try await other.planning(taskID: task2.id).task.version
        _ = try await other.updateSchedule(taskID: task2.id, version: theirVersion, SchedulePatch(plannedAt: .set(start.addingTimeInterval(9000))))
        let live2 = try SyncEngine(client: f.admin, store: store2)
        let replay = try await live2.sync()
        XCTAssertEqual(replay.conflicts, 1, "the conflict is shown, not dropped and not applied")
        let conflictSnap = await live2.snapshot()
        XCTAssertEqual(conflictSnap.conflicts.first?.reason, "version_conflict")
        let server = try await must(f.admin, task2.id, around: start)
        XCTAssertEqual(server.plannedAt, start.addingTimeInterval(9000), "the other editor's move stands until I decide")
        try await live2.resolveConflict(try XCTUnwrap(conflictSnap.conflicts.first).id, keepMine: true)
        _ = try await live2.sync()
        let decided = try await must(f.admin, task2.id, around: start)
        XCTAssertEqual(decided.plannedAt, start.addingTimeInterval(1800), "keep mine: my move is applied on the new version")
    }
}
