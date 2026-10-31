import XCTest
@testable import TodoCore

final class PlanningOutboxTests: XCTestCase {
    let t1 = UUID(), t2 = UUID(), l1 = UUID(), l2 = UUID()
    var client: APIClient!
    var store: InMemoryOutboxStore!

    override func setUp() {
        MockURLProtocol.seen = []
        MockURLProtocol.handler = nil
        let tokens = InMemoryTokenStore()
        try? tokens.save("tok")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: URL(string: "http://test.invalid")!, session: URLSession(configuration: config), tokenStore: tokens)
        store = InMemoryOutboxStore()
    }

    func planningResponse(_ id: UUID, priority: Int = 0, version: Int = 2) -> (Int, Data) {
        (200, Data(#"{"task":{"id":"\#(id)","projectID":"\#(UUID())","title":"T","description":"","status":"open","version":\#(version)},"position":0,"priority":\#(priority),"reminders":[]}"#.utf8))
    }
    var paths: [String] { MockURLProtocol.seen.map { "\($0.httpMethod ?? "") \($0.url!.path)" } }

    func testCoalescesPlanningPerTaskAndLabelPairs() async {
        let box = PlanningOutbox(store: store)
        await box.setPlanning(taskID: t1, PlanningData(priority: 1))
        await box.setPlanning(taskID: t1, PlanningData(priority: 3))
        await box.setPlanning(taskID: t2, PlanningData(priority: 2))
        await box.addLabel(l1, toTask: t1)
        await box.removeLabel(l1, fromTask: t1)   // supersedes the add
        await box.addLabel(named: "Home", toTask: t1)
        await box.addLabel(named: "home", toTask: t1)   // duplicate by name
        let s = await box.snapshot()
        XCTAssertEqual(s.planning[t1]?.priority, 3)
        XCTAssertEqual(s.planning[t2]?.priority, 2)
        XCTAssertEqual(s.labelAdds[t1] ?? [], [])
        XCTAssertEqual(s.labelRemoves[t1], [l1])
        XCTAssertEqual(s.namedAdds[t1], ["Home"])
        XCTAssertEqual(s.pending, 4)
    }

    func testFlushSendsInOrderAndClearsQueue() async throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        MockURLProtocol.handler = { [self] req in
            req.httpMethod == "PUT" && req.url!.path.contains("/planning/") ? planningResponse(t1, priority: 2) : (204, Data())
        }
        let box = PlanningOutbox(store: store)
        await box.setPlanning(taskID: t1, PlanningData(dueAt: due, priority: 2, recurrence: RecurrenceRule(frequency: .weekly, timeZone: "Europe/Berlin"), reminders: [due]))
        await box.addLabel(l1, toTask: t1)
        await box.removeLabel(l2, fromTask: t1)
        let r = try await box.flush(client: client)
        XCTAssertEqual(paths, ["PUT /v1/planning/tasks/\(t1.uuidString)", "PUT /v1/tasks/\(t1.uuidString)/labels/\(l1.uuidString)", "DELETE /v1/tasks/\(t1.uuidString)/labels/\(l2.uuidString)"])
        XCTAssertEqual(r.sent, 3); XCTAssertFalse(r.offline)
        XCTAssertEqual(r.confirmed.first?.task.version, 2)
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.seen[0].httpBody!) as! [String: Any]
        XCTAssertEqual(body["priority"] as? Int, 2)
        XCTAssertEqual((body["recurrence"] as? [String: Any])?["frequency"] as? String, "weekly")
        XCTAssertEqual((body["reminders"] as? [Any])?.count, 1)
        let pending = await box.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testOfflineKeepsQueueAndPersists() async throws {
        MockURLProtocol.handler = { _ in (-1, Data()) }
        let box = PlanningOutbox(store: store)
        await box.setPlanning(taskID: t1, PlanningData(priority: 1))
        await box.addLabel(l1, toTask: t1)
        let r = try await box.flush(client: client)
        XCTAssertTrue(r.offline)
        XCTAssertEqual(MockURLProtocol.seen.count, 1, "stops at the first transport failure")
        // A new outbox on the same store (app restart) still has both and replays them once the server is back.
        MockURLProtocol.seen = []
        MockURLProtocol.handler = { [self] req in req.url!.path.contains("/planning/") ? planningResponse(t1) : (204, Data()) }
        let again = PlanningOutbox(store: store)
        let pendingBefore = await again.pendingCount
        XCTAssertEqual(pendingBefore, 2)
        let r2 = try await again.flush(client: client)
        XCTAssertEqual(r2.sent, 2)
    }

    func testServerErrorIsTreatedAsOffline() async throws {
        MockURLProtocol.handler = { _ in (503, Data()) }
        let box = PlanningOutbox(store: store)
        await box.setPlanning(taskID: t1, PlanningData(priority: 1))
        let r = try await box.flush(client: client)
        XCTAssertTrue(r.offline)
        let pending = await box.pendingCount
        XCTAssertEqual(pending, 1)
    }

    func testRejectedOpsAreKeptForTheUserAndTheRestContinues() async throws {
        MockURLProtocol.handler = { [self] req in
            if req.url!.path.contains(t1.uuidString) { return (404, Data(#"{"error":true,"reason":"not_found"}"#.utf8)) }
            return planningResponse(t2)
        }
        let box = PlanningOutbox(store: store)
        await box.setPlanning(taskID: t1, PlanningData(priority: 1))
        await box.setPlanning(taskID: t2, PlanningData(priority: 1))
        let r = try await box.flush(client: client)
        XCTAssertEqual(r.rejected, 1); XCTAssertEqual(r.sent, 1)
        let s = await box.snapshot()
        XCTAssertEqual(s.rejected.map(\.taskID), [t1])
        XCTAssertEqual(s.rejected.first?.reason, "not_found")
        XCTAssertNil(s.planning[t1], "rejected edits no longer overlay the confirmed state")
        await box.dismiss(s.rejected[0].id)
        let after = await box.snapshot()
        XCTAssertTrue(after.rejected.isEmpty)
    }

    func testRemovingAnAlreadyRemovedLabelIsSuccess() async throws {
        MockURLProtocol.handler = { _ in (404, Data(#"{"error":true}"#.utf8)) }
        let box = PlanningOutbox(store: store)
        await box.removeLabel(l1, fromTask: t1)
        let r = try await box.flush(client: client)
        XCTAssertEqual(r.sent, 1); XCTAssertEqual(r.rejected, 0)
    }

    func testSkipsTasksThatAreStillWaitingInTheSyncQueue() async throws {
        MockURLProtocol.handler = { [self] _ in planningResponse(t2) }
        let box = PlanningOutbox(store: store)
        await box.setPlanning(taskID: t1, PlanningData(priority: 1))
        await box.setPlanning(taskID: t2, PlanningData(priority: 1))
        let r = try await box.flush(client: client, skipping: [t1])
        XCTAssertEqual(r.sent, 1)
        XCTAssertEqual(paths, ["PUT /v1/planning/tasks/\(t2.uuidString)"])
        let pending = await box.pendingCount
        XCTAssertEqual(pending, 1)
    }

    func testNamedLabelIsReusedOrCreated() async throws {
        let existing = UUID(), created = UUID()
        MockURLProtocol.handler = { req in
            let p = req.url!.path
            if req.httpMethod == "GET" { return (200, Data(#"{"items":[{"id":"\#(existing)","name":"Home","version":1}]}"#.utf8)) }
            if req.httpMethod == "POST" { return (201, Data(#"{"id":"\#(created)","name":"Work","version":1}"#.utf8)) }
            return p.contains("/labels/") ? (204, Data()) : (500, Data())
        }
        let box = PlanningOutbox(store: store)
        await box.addLabel(named: "home", toTask: t1)
        await box.addLabel(named: "Work", toTask: t1)
        let r = try await box.flush(client: client)
        XCTAssertEqual(r.sent, 2)
        XCTAssertEqual(r.createdLabels.map(\.id), [created])
        XCTAssertTrue(paths.contains("PUT /v1/tasks/\(t1.uuidString)/labels/\(existing.uuidString)"))
        XCTAssertTrue(paths.contains("PUT /v1/tasks/\(t1.uuidString)/labels/\(created.uuidString)"))
    }

    func testNamedLabelLookupFollowsPagesAndRespectsTheServerPageCap() async throws {
        let onPage2 = UUID()
        MockURLProtocol.handler = { req in
            if req.httpMethod == "GET" {
                let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if q.first(where: { $0.name == "limit" })?.value != "100" { return (400, Data(#"{"error":true,"reason":"invalid_limit"}"#.utf8)) }
                if q.first(where: { $0.name == "cursor" })?.value == "p2" { return (200, Data(#"{"items":[{"id":"\#(onPage2)","name":"Deep","version":1}]}"#.utf8)) }
                return (200, Data(#"{"items":[{"id":"\#(UUID())","name":"Other","version":1}],"nextCursor":"p2"}"#.utf8))
            }
            return (204, Data())
        }
        let box = PlanningOutbox(store: store)
        await box.addLabel(named: "deep", toTask: t1)
        let r = try await box.flush(client: client)
        XCTAssertEqual(r.sent, 1); XCTAssertTrue(r.createdLabels.isEmpty)
        XCTAssertFalse(paths.contains { $0.hasPrefix("POST") })
    }

    func testUnauthorizedIsThrownAndKeepsOps() async {
        MockURLProtocol.handler = { _ in (401, Data()) }
        let box = PlanningOutbox(store: store)
        await box.setPlanning(taskID: t1, PlanningData(priority: 1))
        do { _ = try await box.flush(client: client); XCTFail("expected 401") } catch { XCTAssertEqual(error as? APIError, .unauthorized(reason: nil)) }
        let pending = await box.pendingCount
        XCTAssertEqual(pending, 1)
    }

    func testFileStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let s = FileOutboxStore(url: url)
        let op = OutboxOp(kind: .setPlanning, taskID: t1, planning: PlanningData(dueAt: Date(timeIntervalSince1970: 1_800_000_000), priority: 3, reminders: [Date(timeIntervalSince1970: 1_800_000_100)]))
        try s.save([op])
        XCTAssertEqual(try s.load().first?.planning, op.planning)
        try s.save([])
        XCTAssertTrue(try s.load().isEmpty)
    }
}
