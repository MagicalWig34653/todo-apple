import Foundation
import XCTest

@testable import TodoCore

/// Opt-in (see `LiveEtappe2Tests`): the planning/label outbox against a real backend, including a task that is
/// created through the sync queue in the same run (the outbox has to wait for it).
extension LiveEtappe2Tests {
    func testOutboxReplaysPlanningAndLabelsAfterSyncQueue() async throws {
        let f = try await fixture()
        let engine = try SyncEngine(client: f.admin, store: InMemorySyncStore())
        let box = PlanningOutbox(store: InMemoryOutboxStore())
        let pid = UUID(), tid = UUID()
        try await engine.createProject(id: pid, name: "Outbox \(f.suffix)")
        try await engine.createTask(id: tid, projectID: pid, title: "Offline geplant")

        // Offline-style edits for a task the server does not know yet.
        let due = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 + 86_400)
        await box.setPlanning(taskID: tid, PlanningData(dueAt: due, priority: 2, recurrence: RecurrenceRule(frequency: .weekly, timeZone: "Europe/Berlin"), reminders: [due.addingTimeInterval(-3600)]))
        await box.addLabel(named: "Outbox-\(f.suffix)", toTask: tid)
        let waiting = await engine.queuedEntityIDs()
        XCTAssertTrue(waiting.contains(tid))
        let skipped = try await box.flush(client: f.admin, skipping: waiting)
        XCTAssertEqual(skipped.sent, 0)
        let stillPending = await box.pendingCount
        XCTAssertEqual(stillPending, 2)

        // After the sync queue was sent, the outbox goes through.
        _ = try await engine.sync()
        let report = try await box.flush(client: f.admin, skipping: await engine.queuedEntityIDs())
        XCTAssertEqual(report.sent, 2)
        XCTAssertEqual(report.rejected, 0)
        XCTAssertEqual(report.createdLabels.count, 1)

        let planned = try await f.admin.planning(taskID: tid)
        XCTAssertEqual(planned.planning.priority, 2)
        XCTAssertEqual(planned.planning.recurrence?.frequency, .weekly)
        XCTAssertEqual(planned.planning.reminders.count, 1)
        XCTAssertEqual(planned.planning.dueAt?.timeIntervalSince1970 ?? 0, due.timeIntervalSince1970, accuracy: 1)
        let labels = try await f.admin.labels(taskID: tid).items
        XCTAssertEqual(labels.map(\.name), ["Outbox-\(f.suffix)"])

        // Replaying the same edits is idempotent; removing the label works; a foreign task is rejected, not retried.
        let label = try XCTUnwrap(labels.first)
        await box.addLabel(label.id, toTask: tid)
        await box.removeLabel(label.id, fromTask: tid)
        await box.setPlanning(taskID: UUID(), PlanningData(priority: 1))
        let again = try await box.flush(client: f.admin)
        XCTAssertEqual(again.sent, 1)
        XCTAssertEqual(again.rejected, 1)
        let none = try await f.admin.labels(taskID: tid).items
        XCTAssertTrue(none.isEmpty)
        let rejected = await box.snapshot().rejected
        XCTAssertEqual(rejected.first?.reason, "not_found")
    }
}
