import Foundation
import XCTest

@testable import TodoCore

/// Opt-in (see `LiveEtappe2Tests`): planning and labels through the sync queue and feed (contract 1.4.0, ADR 0020),
/// two replicas of one account against a real backend.
extension LiveEtappe2Tests {
    func testPlanningAndLabelsThroughSyncQueueTwoReplicas() async throws {
        let f = try await fixture()
        let a = try SyncEngine(client: f.admin, store: InMemorySyncStore())
        let b = try SyncEngine(client: APIClient(baseURL: f.admin.baseURL, tokenStore: f.adminStore), store: InMemorySyncStore())
        let pid = UUID(), tid = UUID()
        try await a.createProject(id: pid, name: "Planung \(f.suffix)")
        try await a.createTask(id: tid, projectID: pid, title: "Offline geplant")
        _ = try await a.sync()
        _ = try await b.sync()
        let bSupport = await b.planningSyncSupport
        XCTAssertEqual(bSupport, .supported, "the server delivers planning in the feed")
        var snapB = await b.snapshot()
        XCTAssertEqual(snapB.planning[tid]?.priority, 0, "default planning arrives with the task")

        // A edits offline: two plannings (only the last is sent), a new label by name, and the task is created in the same run.
        let due = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 + 86_400)
        try await a.setPlanning(tid, PlanningData(priority: 1))
        try await a.setPlanning(tid, PlanningData(dueAt: due, priority: 2, recurrence: RecurrenceRule(frequency: .weekly, timeZone: "Europe/Berlin"), reminders: [due.addingTimeInterval(-3600)]))
        let name = "Live-\(f.suffix)"
        let queued = try await a.addLabel(named: name, to: tid)
        XCTAssertEqual(queued.pending, 3, "one planning + label.create + task.label_add")
        XCTAssertEqual(queued.metaOverlay.planning[tid]?.priority, 2)
        let r1 = try await a.sync()
        XCTAssertEqual(r1.pushed, 3); XCTAssertEqual(r1.rejected, 0); XCTAssertEqual(r1.conflicts, 0)

        let rest = try await f.admin.planning(taskID: tid)
        XCTAssertEqual(rest.planning.priority, 2)
        XCTAssertEqual(rest.planning.recurrence?.frequency, .weekly)
        XCTAssertEqual(rest.planning.dueAt?.timeIntervalSince1970 ?? 0, due.timeIntervalSince1970, accuracy: 1)
        let restLabels = try await f.admin.labels(taskID: tid).items.map(\.name)
        XCTAssertEqual(restLabels, [name])

        // B sees it through the feed.
        _ = try await b.sync()
        snapB = await b.snapshot()
        XCTAssertEqual(snapB.planning[tid]?.priority, 2)
        XCTAssertEqual(snapB.planning[tid]?.reminders.count, 1)
        XCTAssertEqual(snapB.planning[tid]?.recurrence?.timeZone, "Europe/Berlin")
        let label = try XCTUnwrap(snapB.labels.first { $0.name == name })
        XCTAssertEqual(label.taskIDs, [tid])

        // B renames the label and removes it from the task; A follows.
        try await b.renameLabel(label.id, name: name + "-neu")
        try await b.setLabel(label.id, on: tid, enabled: false)
        let r2 = try await b.sync()
        XCTAssertEqual(r2.pushed, 2); XCTAssertEqual(r2.rejected, 0)
        _ = try await a.sync()
        var snapA = await a.snapshot()
        XCTAssertEqual(snapA.labels.first { $0.id == label.id }?.name, name + "-neu")
        XCTAssertEqual(snapA.labels.first { $0.id == label.id }?.taskIDs, [])

        // Conflict: A is stale; B changes the title (task version +1); A's planning hits 409, is retried on the feed version.
        try await b.updateTask(tid, TaskUpdate(title: "Titel von B"))
        _ = try await b.sync()
        try await a.setPlanning(tid, PlanningData(priority: 3))
        let r3 = try await a.sync()
        XCTAssertEqual(r3.pushed, 1); XCTAssertEqual(r3.conflicts, 0); XCTAssertEqual(r3.rejected, 0)
        let restAfter = try await f.admin.planning(taskID: tid).planning.priority
        XCTAssertEqual(restAfter, 3)
        snapA = await a.snapshot()
        XCTAssertEqual(snapA.tasks.first { $0.id == tid }?.title, "Titel von B", "B's title survived: planning did not overwrite it")

        // Refusal: a foreign/unknown label is rejected with a reason and does not block the rest.
        try await a.setLabel(UUID(), on: tid, enabled: true)
        let r4 = try await a.sync()
        XCTAssertEqual(r4.rejected, 1)
        let refused = await a.snapshot().rejected
        XCTAssertEqual(refused.first?.reason, "not_found")
        for q in refused { _ = try await a.dismiss(q.id) }

        // Label delete reaches B as a tombstone; deleting the task removes planning and links locally.
        try await a.setLabel(label.id, on: tid, enabled: true)
        _ = try await a.sync()
        _ = try await b.sync()
        snapB = await b.snapshot()
        XCTAssertEqual(snapB.labels.first { $0.id == label.id }?.taskIDs, [tid])
        try await a.deleteTask(tid)
        _ = try await a.sync()
        _ = try await b.sync()
        snapB = await b.snapshot()
        XCTAssertNil(snapB.planning[tid])
        XCTAssertEqual(snapB.labels.first { $0.id == label.id }?.taskIDs, [])
        try await a.deleteLabel(label.id)
        let r5 = try await a.sync()
        XCTAssertEqual(r5.pushed, 1)
        _ = try await b.sync()
        snapB = await b.snapshot()
        XCTAssertNil(snapB.labels.first { $0.id == label.id }, "label tombstone")
        let restAll = try await f.admin.labels().items
        XCTAssertFalse(restAll.contains { $0.id == label.id })
    }
}
