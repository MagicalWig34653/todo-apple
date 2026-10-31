import Foundation
import XCTest

@testable import TodoCore

/// Opt-in live checks of ADR 0012 (needs a backend built from main with project-state; skipped without
/// `TODO_LIVE_BASE_URL`, same fixture as `LiveEtappe2Tests`).
extension LiveEtappe2Tests {
    func testLiveProjectDetailsFavoritesPrefsAndOrder() async throws {
        let f = try await fixture(); let a = f.admin
        let p1 = try await a.createProject(name: "S1 \(f.suffix)", description: "Beschreibung", color: "#2470E0")
        let p2 = try await a.createProject(name: "S2 \(f.suffix)")
        let p3 = try await a.createProject(name: "S3 \(f.suffix)")
        XCTAssertEqual(p1.description, "Beschreibung"); XCTAssertEqual(p1.color, "#2470E0")
        let edited = try await a.updateProject(p2.id, version: p2.version, ProjectUpdate(description: "x", color: "#DB4C3F"))
        XCTAssertEqual(edited.color, "#DB4C3F")
        let cleared = try await a.updateProject(p2.id, version: edited.version, ProjectUpdate(description: "", color: ""))
        XCTAssertNil(cleared.color); XCTAssertNil(cleared.description)

        // Favourites.
        var favs = try await a.setFavorite(p1.id)
        XCTAssertTrue(favs.contains { $0.projectID == p1.id })
        favs = try await a.setFavorite(p3.id, index: 0)
        XCTAssertEqual(favs.first?.projectID, p3.id)
        let listed = try await a.projects()
        XCTAssertEqual(listed.first { $0.id == p3.id }?.isFavorite, true)
        try await a.removeFavorite(p1.id)
        let after = try await a.favorites()
        XCTAssertFalse(after.contains { $0.projectID == p1.id })

        // Display prefs with revisions.
        let def = try await a.projectPrefs(for: p1.id)
        XCTAssertEqual(def.viewMode, .list)  // favourite writes already advanced the revision
        XCTAssertFalse(def.showCompleted == false)
        let w1 = try await a.patchProjectPrefs(p1.id, revision: def.revision, ProjectPrefsPatch(view: "board", showCompleted: false))
        XCTAssertEqual(w1.revision, def.revision + 1); XCTAssertEqual(w1.viewMode, .board); XCTAssertFalse(w1.showCompleted)
        do { _ = try await a.patchProjectPrefs(p1.id, revision: def.revision, ProjectPrefsPatch(sort: "due")); XCTFail("stale revision") }
        catch { XCTAssertEqual(error as? APIError, .conflict(reason: "revision_conflict")) }
        let all = try await a.projectPrefs()
        XCTAssertEqual(all.first { $0.projectID == p1.id }?.revision, w1.revision)

        // Order: personal reorder, then re-parent.
        let moved = try await a.putProjectPosition(p3.id, index: 0)
        XCTAssertEqual(moved.position, 0)
        let roots = try await a.projects().filter { $0.parentID == nil }.sorted { ($0.position ?? 99) < ($1.position ?? 99) }
        XCTAssertEqual(roots.first?.id, p3.id)
        let child = try await a.putProjectPosition(p2.id, index: 0, parent: .parent(p1.id), version: cleared.version)
        XCTAssertEqual(child.parentID, p1.id)
        let back = try await a.putProjectPosition(p2.id, index: 0, parent: .root, version: child.version)
        XCTAssertNil(back.parentID)
    }

    func testLiveProjectCommentsActivityAndRunnerLists() async throws {
        let f = try await fixture(); let a = f.admin
        let p = try await a.createProject(name: "K \(f.suffix)")
        let key = UUID()
        let c = try await a.addProjectComment(p.id, body: "Erster", idempotencyKey: key)
        let again = try await a.addProjectComment(p.id, body: "Erster", idempotencyKey: key)
        XCTAssertEqual(c.id, again.id, "idempotent retry")
        let edited = try await a.editProjectComment(p.id, id: c.id, version: c.version, body: "Geaendert")
        XCTAssertEqual(edited.body, "Geaendert"); XCTAssertEqual(edited.authorName, f.adminUser.displayName)
        let list = try await a.projectComments(p.id)
        XCTAssertEqual(list.map(\.id), [c.id])
        let feed = try await a.activityFeed(projectID: p.id, limit: 10)
        XCTAssertTrue(feed.items.contains { $0.source == "project" && $0.kind.hasPrefix("comment") })
        let global = try await a.activityFeed(limit: 2)
        XCTAssertLessThanOrEqual(global.items.count, 2)
        try await a.deleteProjectComment(p.id, id: c.id, version: edited.version)
        let empty = try await a.projectComments(p.id)
        XCTAssertTrue(empty.isEmpty)
        // Runner lists exist for a fresh account (no devices, no jobs).
        let devices = try await a.agentDevices()
        XCTAssertTrue(devices.isEmpty)
        let jobs = try await a.agentJobs(limit: 5)
        XCTAssertTrue(jobs.items.isEmpty)
    }

    func testLiveColumnMutationsAndProjectPositionThroughSyncEngine() async throws {
        let f = try await fixture()
        let engine = try SyncEngine(client: f.admin, store: InMemorySyncStore())
        let pid = UUID(), c1 = UUID(), c2 = UUID(), t1 = UUID()
        try await engine.createProject(id: pid, name: "Board \(f.suffix)")
        try await engine.createColumn(id: c1, projectID: pid, name: "Todo", color: "#44AD5C")
        try await engine.createColumn(id: c2, projectID: pid, name: "Fertig", isDone: true)
        try await engine.createTask(id: t1, projectID: pid, title: "Karte")
        try await engine.moveTask(t1, toColumn: c1)
        var report = try await engine.sync()
        XCTAssertEqual(report.pushed, 5); XCTAssertEqual(report.rejected, 0)
        var snap = await engine.snapshot()
        XCTAssertEqual(snap.columns.filter { $0.projectID == pid }.map(\.name), ["Todo", "Fertig"])
        XCTAssertEqual(snap.tasks.first { $0.id == t1 }?.columnID, c1)

        // Offline-style edits, then one flush: move into the done column (completes), rename, reorder, delete.
        try await engine.moveTask(t1, toColumn: c2)
        try await engine.updateColumn(c1, name: "Backlog", index: 1)
        report = try await engine.sync()
        XCTAssertEqual(report.rejected, 0)
        snap = await engine.snapshot()
        XCTAssertEqual(snap.tasks.first { $0.id == t1 }?.status, "done")
        XCTAssertEqual(snap.columns.filter { $0.projectID == pid }.map(\.name), ["Fertig", "Backlog"])
        let board = try await f.admin.board(projectID: pid)
        XCTAssertEqual(board.columns.map(\.name), ["Fertig", "Backlog"])
        XCTAssertEqual(board.columns.first?.tasks.map(\.id), [t1])

        try await engine.deleteColumn(c2)  // tasks go to the remaining column, and reopen there
        report = try await engine.sync()
        XCTAssertEqual(report.rejected, 0)
        snap = await engine.snapshot()
        XCTAssertEqual(snap.columns.filter { $0.projectID == pid }.map(\.name), ["Backlog"])
        XCTAssertEqual(snap.tasks.first { $0.id == t1 }?.columnID, c1)
        XCTAssertEqual(snap.tasks.first { $0.id == t1 }?.status, "open")

        // Project order through the queue; a second replica sees the same columns via the feed.
        let other = UUID()
        try await engine.createProject(id: other, name: "Zweites \(f.suffix)")
        try await engine.moveProject(other, index: 0)
        report = try await engine.sync()
        XCTAssertEqual(report.rejected, 0)
        let replica = try SyncEngine(client: f.admin, store: InMemorySyncStore())
        _ = try await replica.sync()
        let rs = await replica.snapshot()
        XCTAssertEqual(rs.columns.filter { $0.projectID == pid }.map(\.name), ["Backlog"])
        XCTAssertEqual(rs.projects.filter { $0.parentID == nil }.first?.id, other)
    }
}

/// Opt-in live check of ADR 0021 push registration and preferences (skipped without `TODO_LIVE_BASE_URL`).
extension LiveEtappe2Tests {
    func testLivePushDevicesAndPrefs() async throws {
        let f = try await fixture(); let a = f.admin
        let token = String(repeating: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), count: 2)
        let reg = PushRegistration(token: token, platform: .ios, environment: .sandbox, bundleId: "de.linolaske.todo", appVersion: "0.1.0", locale: "de-DE")
        let d1: PushDevice
        do { d1 = try await a.registerPushDevice(reg) }
        catch { if APIClient.isPushUnavailable(error) { throw XCTSkip("server without push endpoints") }; throw error }
        let d2 = try await a.registerPushDevice(reg)
        XCTAssertEqual(d1.id, d2.id, "registration is idempotent per token")
        let listed = try await a.pushDevices()
        XCTAssertTrue(listed.contains { $0.id == d1.id })
        let prefs = try await a.pushPrefs()
        XCTAssertEqual(prefs, PushPrefs())
        let changed = try await a.updatePushPrefs(PushPrefsUpdate(categories: [.comments: true], showContent: true, badge: false))
        XCTAssertTrue(changed.categories.comments); XCTAssertTrue(changed.showContent); XCTAssertFalse(changed.badge)
        XCTAssertTrue(changed.categories.reminders, "untouched categories keep their value")
        // Another account does not see or revoke this device.
        let bobList = try await f.bob.pushDevices()
        XCTAssertFalse(bobList.contains { $0.id == d1.id })
        do { try await f.bob.revokePushDevice(d1.id); XCTFail("foreign device") } catch { XCTAssertEqual(error as? APIError, .notFound) }
        try await a.revokePushDevice(d1.id)
        do { try await a.revokePushDevice(d1.id); XCTFail("already revoked") } catch { XCTAssertEqual(error as? APIError, .notFound) }
        _ = try await a.updatePushPrefs(PushPrefsUpdate(categories: [.comments: false], showContent: false, badge: true))
    }
}
