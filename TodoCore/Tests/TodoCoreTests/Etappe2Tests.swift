import XCTest
@testable import TodoCore

final class Etappe2Tests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let tid = UUID(), pid = UUID()

    override func setUp() {
        MockURLProtocol.seen = []
        MockURLProtocol.handler = nil
        try? store.save("tok")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: URL(string: "http://test.invalid")!, session: URLSession(configuration: config), tokenStore: store)
    }

    private func reply(_ s: String) { reply(200, s) }
    private func reply(_ status: Int, _ s: String) { MockURLProtocol.handler = { _ in (status, Data(s.utf8)) } }
    private var last: URLRequest { MockURLProtocol.seen.last! }
    private func body(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
    }
    private func taskJSON(_ id: UUID, status: String = "open") -> String {
        #"{"id":"\#(id)","projectID":"\#(pid)","title":"T","description":"","status":"\#(status)","version":2}"#
    }

    func testTodayDecodesPlanningFlatNextToTask() async throws {
        reply(#"[{"task":\#(taskJSON(tid)),"position":3,"dueAt":"2026-10-27T08:00:00Z","plannedAt":null,"priority":2,"recurrence":{"frequency":"weekly","interval":2,"timeZone":"Europe/Berlin","until":null},"reminders":["2026-10-27T07:00:00Z"]}]"#)
        let list = try await client.today(timeZone: TimeZone(identifier: "Europe/Berlin")!)
        XCTAssertEqual(last.url?.path, "/v1/planning/today")
        XCTAssertEqual(last.url?.query, "timeZone=Europe/Berlin")
        XCTAssertEqual(last.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let p = try XCTUnwrap(list.first)
        XCTAssertEqual(p.id, tid)
        XCTAssertEqual(p.position, 3)
        XCTAssertEqual(p.planning.priority, 2)
        XCTAssertNotNil(p.planning.dueAt)
        XCTAssertNil(p.planning.plannedAt)
        XCTAssertEqual(p.planning.recurrence?.frequency, .weekly)
        XCTAssertEqual(p.planning.recurrence?.interval, 2)
        XCTAssertEqual(p.planning.reminders.count, 1)
    }

    func testUpcomingAndUpNextPaths() async throws {
        reply("[]")
        _ = try await client.upcoming(); XCTAssertEqual(last.url?.path, "/v1/planning/upcoming")
        _ = try await client.upNext(); XCTAssertEqual(last.url?.path, "/v1/planning/up-next")
    }

    func testSetPlanningPutsIsoDatesAndExplicitNulls() async throws {
        reply(#"{"task":\#(taskJSON(tid)),"position":0,"priority":1,"reminders":[]}"#)
        let due = Date(timeIntervalSince1970: 1_792_000_000)
        let result = try await client.setPlanning(taskID: tid, PlanningData(dueAt: due, priority: 1))
        XCTAssertEqual(last.httpMethod, "PUT")
        XCTAssertEqual(last.url?.path, "/v1/planning/tasks/\(tid.uuidString)")
        let b = body(last)
        XCTAssertEqual(b["dueAt"] as? String, ISO8601DateFormatter().string(from: due))
        XCTAssertTrue(b["plannedAt"] is NSNull)
        XCTAssertTrue(b["recurrence"] is NSNull)
        XCTAssertEqual(b["priority"] as? Int, 1)
        XCTAssertEqual((b["reminders"] as? [Any])?.count, 0)
        XCTAssertEqual(result.planning.priority, 1)
    }

    func testLabelsAndTaskLabels() async throws {
        let lid = UUID()
        reply(#"{"items":[{"id":"\#(lid)","name":"Home","version":1}],"nextCursor":"n1"}"#)
        let page = try await client.labels(limit: 10, cursor: "x")
        XCTAssertEqual(Set((last.url?.query ?? "").split(separator: "&").map(String.init)), ["limit=10", "cursor=x"])
        XCTAssertEqual(page.items.first?.name, "Home")
        XCTAssertEqual(page.nextCursor, "n1")

        reply(204, "")
        try await client.addLabel(lid, toTask: tid)
        XCTAssertEqual(last.httpMethod, "PUT")
        XCTAssertEqual(last.url?.path, "/v1/tasks/\(tid.uuidString)/labels/\(lid.uuidString)")
        XCTAssertEqual(last.value(forHTTPHeaderField: "Content-Type"), "application/json")
        try await client.removeLabel(lid, fromTask: tid)
        XCTAssertEqual(last.httpMethod, "DELETE")

        reply(200, #"{"id":"\#(lid)","name":"Work","version":2}"#)
        _ = try await client.renameLabel(lid, version: 1, name: "Work")
        XCTAssertEqual(body(last)["version"] as? Int, 1)
        XCTAssertEqual(body(last)["name"] as? String, "Work")
        _ = try await client.createLabel(name: "N")
        XCTAssertNil(body(last)["version"])
    }

    func testSearchQueryAndHits() async throws {
        let lid = UUID()
        reply(#"{"items":[{"kind":"task","id":"\#(tid)","project":{"id":"\#(pid)","name":"P","version":1},"task":\#(taskJSON(tid))},{"kind":"project","id":"\#(pid)","project":{"id":"\#(pid)","name":"P","version":1}}]}"#)
        let page = try await client.search("milk", projectID: pid, labelID: lid, status: .inProgress, limit: 5)
        let q = Set((last.url?.query ?? "").split(separator: "&").map(String.init))
        XCTAssertEqual(q, ["q=milk", "projectID=\(pid.uuidString)", "labelID=\(lid.uuidString)", "status=in_progress", "limit=5"])
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[0].kind, .task)
        XCTAssertNotNil(page.items[0].task)
        XCTAssertNil(page.items[1].task)
        XCTAssertNil(page.nextCursor)
    }

    func testCommentsCreateSendsIdempotencyKeyAndDeleteBody() async throws {
        let cid = UUID(), key = UUID(), author = UUID()
        let json = #"{"id":"\#(cid)","taskID":"\#(tid)","authorID":"\#(author)","authorName":null,"body":"hi","version":1}"#
        reply(201, json)
        let c = try await client.addComment(taskID: tid, body: "hi", idempotencyKey: key)
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.url?.path, "/v1/tasks/\(tid.uuidString)/comments")
        XCTAssertEqual(last.value(forHTTPHeaderField: "Idempotency-Key"), key.uuidString)
        XCTAssertEqual(body(last)["body"] as? String, "hi")
        XCTAssertNil(c.authorName)

        reply(200, json)
        _ = try await client.updateComment(taskID: tid, id: cid, version: 1, body: "yo")
        XCTAssertEqual(last.httpMethod, "PATCH")
        XCTAssertEqual(body(last)["version"] as? Int, 1)

        reply(204, "")
        try await client.deleteComment(taskID: tid, id: cid, version: 1)
        XCTAssertEqual(last.httpMethod, "DELETE")
        XCTAssertEqual(body(last)["version"] as? Int, 1)
        XCTAssertEqual(last.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testActivityAndAttachmentsDecode() async throws {
        let a = UUID(), actor = UUID()
        reply(#"{"items":[{"id":"\#(a)","sequence":4,"actorType":"Run","actorID":"\#(actor)","actorName":null,"kind":"agent.future_kind","subjectID":null,"createdAt":"2026-10-27T08:00:00.500Z"}],"nextCursor":"c"}"#)
        let page = try await client.activity(taskID: tid, limit: 20)
        XCTAssertEqual(page.items.first?.kind, "agent.future_kind")
        XCTAssertNotNil(page.items.first?.createdAt)
        XCTAssertEqual(page.nextCursor, "c")

        reply(#"[{"id":"\#(a)","taskID":"\#(tid)","filename":"s.png","role":"progress","mediaType":"image/png","size":10,"checksum":"\#(String(repeating: "a", count: 64))","status":"complete"}]"#)
        let atts = try await client.attachments(taskID: tid)
        XCTAssertEqual(last.url?.path, "/v1/tasks/\(tid.uuidString)/attachments")
        XCTAssertTrue(atts[0].isImage)
    }

    func testTeamsSharesAndUserSearch() async throws {
        let team = UUID(), user = UUID(), gid = UUID()
        reply(#"[{"id":"\#(user)","displayName":"Anna"}]"#)
        let users = try await client.searchUsers("An", limit: 5)
        XCTAssertEqual(Set((last.url?.query ?? "").split(separator: "&").map(String.init)), ["q=An", "limit=5"])
        XCTAssertEqual(users.first?.displayName, "Anna")

        reply(#"{"id":"\#(gid)","teamID":"\#(team)","userID":"\#(user)","isAdmin":false,"accepted":false}"#)
        let m = try await client.inviteMember(teamID: team, userID: user)
        XCTAssertEqual(last.httpMethod, "PUT")
        XCTAssertEqual(body(last)["isAdmin"] as? Bool, false)
        XCTAssertNil(m.teamName)

        reply(#"{"id":"\#(gid)","projectID":"\#(pid)","principalType":"team","principalID":"\#(team)","role":"comment"}"#)
        let g = try await client.setGrant(projectID: pid, principalType: .team, principalID: team, role: .comment)
        XCTAssertEqual(last.url?.path, "/v1/projects/\(pid.uuidString)/grants")
        XCTAssertEqual(body(last)["principalType"] as? String, "team")
        XCTAssertEqual(body(last)["role"] as? String, "comment")
        XCTAssertEqual(g.role, .comment)
        XCTAssertTrue(ShareRole.read < ShareRole.manage)

        reply(#"{"projectID":"\#(pid)","canTransferOwnership":false,"canDelete":false,"canManageTeam":false,"canStartAgent":false,"inherits":true,"userID":"\#(user)"}"#)
        let v = try await client.visibility(projectID: pid)
        XCTAssertNil(v.role)

        reply(204, "")
        try await client.acceptTeamInvitation(teamID: team)
        XCTAssertEqual(last.httpMethod, "POST")
        try await client.removeGrant(projectID: pid, grantID: gid)
        XCTAssertEqual(last.httpMethod, "DELETE")
    }

    func testSyncChangesPagingFollowsHasMore() async throws {
        let p2 = UUID()
        var call = 0
        MockURLProtocol.handler = { req in
            call += 1
            if call == 1 {
                return (200, Data(#"{"changes":[{"seq":1,"entityType":"project","entityID":"\#(self.pid)","kind":"upsert","project":{"id":"\#(self.pid)","name":"P","version":1}}],"cursor":"c1","hasMore":true}"#.utf8))
            }
            return (200, Data(#"{"changes":[{"seq":2,"entityType":"task","entityID":"\#(p2)","kind":"delete"}],"cursor":"c2","hasMore":false}"#.utf8))
        }
        let all = try await client.syncAll()
        XCTAssertEqual(all.cursor, "c2")
        XCTAssertEqual(all.changes.map(\.seq), [1, 2])
        XCTAssertEqual(all.changes[1].kind, .delete)
        XCTAssertNil(all.changes[1].task)
        XCTAssertTrue(MockURLProtocol.seen[0].url!.query!.contains("cursor=c0"))
        XCTAssertTrue(MockURLProtocol.seen[1].url!.query!.contains("cursor=c1"))
    }

    func testSyncCursorErrors() async {
        reply(409, #"{"error":true,"reason":"cursor_ahead"}"#)
        do { _ = try await client.syncChanges(cursor: "c99"); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .conflict(reason: "cursor_ahead")) }
        reply(400, #"{"error":true,"reason":"invalid_cursor"}"#)
        do { _ = try await client.syncChanges(cursor: "zz"); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .invalidInput(reason: "invalid_cursor")) }
    }

    func testMutationShapeStatusAndErrors() async throws {
        let mid = UUID()
        reply(201, #"{"mutationID":"\#(mid)","type":"task.create","id":"\#(tid)","deleted":false,"task":\#(taskJSON(tid)),"cursor":"c5"}"#)
        let m = SyncMutation(mutationID: mid, type: .taskCreate, id: tid, projectID: pid, title: "T")
        let r = try await client.applyMutation(m)
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.url?.path, "/v1/sync/mutations")
        let b = body(last)
        XCTAssertEqual(b["type"] as? String, "task.create")
        XCTAssertEqual(b["mutationID"] as? String, mid.uuidString)
        XCTAssertEqual(b["title"] as? String, "T")
        XCTAssertNil(b["version"])
        XCTAssertNil(b["name"])
        XCTAssertTrue(r.created)
        XCTAssertEqual(r.cursor, "c5")

        reply(200, #"{"mutationID":"\#(mid)","type":"task.delete","id":"\#(tid)","deleted":true,"cursor":"c6"}"#)
        let d = try await client.applyMutation(SyncMutation(type: .taskDelete, id: tid, version: 2))
        XCTAssertTrue(d.deleted)
        XCTAssertFalse(d.created)

        reply(409, #"{"error":true,"reason":"version_conflict"}"#)
        do { _ = try await client.applyMutation(SyncMutation(type: .taskUpdate, id: tid, version: 1, title: "x")); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .versionConflict) }
        reply(409, #"{"error":true,"reason":"mutation_id_reused"}"#)
        do { _ = try await client.applyMutation(m); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .conflict(reason: "mutation_id_reused")) }
    }
}
