import XCTest
@testable import TodoCore

/// ADR 0012 client side: project fields, favourites, display prefs, order, project comments, activity, runner lists.
final class ServerStateTests: XCTestCase {
    var client: APIClient!
    let pid = UUID(), uid = UUID(), cid = UUID()

    override func setUp() {
        MockURLProtocol.seen = []
        MockURLProtocol.handler = nil
        let tokens = InMemoryTokenStore()
        try? tokens.save("tok")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: URL(string: "http://test.invalid")!, session: URLSession(configuration: config), tokenStore: tokens)
    }

    private func reply(_ s: String) { reply(200, s) }
    private func reply(_ status: Int, _ s: String) { MockURLProtocol.handler = { _ in (status, Data(s.utf8)) } }
    private var last: URLRequest { MockURLProtocol.seen.last! }
    private func body(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
    }
    private var path: String { last.url!.path }

    func testProjectDecodesNewFieldsAndOldServersWithout() throws {
        let d = JSONDecoder()
        let new = Data(##"{"id":"\##(pid)","parentID":null,"name":"A","version":3,"description":"d","color":"#DB4C3F","position":2,"isFavorite":true,"favoritePosition":0}"##.utf8)
        let p = try d.decode(Project.self, from: new)
        XCTAssertEqual(p.description, "d"); XCTAssertEqual(p.color, "#DB4C3F"); XCTAssertEqual(p.position, 2)
        XCTAssertTrue(p.isFavorite); XCTAssertEqual(p.favoritePosition, 0)
        let old = try d.decode(Project.self, from: Data(#"{"id":"\#(pid)","parentID":null,"name":"A","version":1}"#.utf8))
        XCTAssertNil(old.description); XCTAssertNil(old.position); XCTAssertFalse(old.isFavorite)
    }

    func testProjectCreateAndUpdateCarryDescriptionAndColor() async throws {
        reply(201, #"{"id":"\#(pid)","name":"A","version":1}"#)
        _ = try await client.createProject(name: "A", description: "hello", color: "#2470E0")
        XCTAssertEqual(body(last)["description"] as? String, "hello")
        XCTAssertEqual(body(last)["color"] as? String, "#2470E0")
        reply(#"{"id":"\#(pid)","name":"A","version":2}"#)
        _ = try await client.updateProject(pid, version: 1, ProjectUpdate(description: "", color: ""))
        XCTAssertEqual(body(last)["description"] as? String, "")
        XCTAssertEqual(body(last)["color"] as? String, "")
        XCTAssertNil(body(last)["name"])
    }

    func testFavoritesRequestShapes() async throws {
        reply(#"{"items":[{"projectID":"\#(pid)","position":0}]}"#)
        let list = try await client.favorites()
        XCTAssertEqual(path, "/v1/me/favorites"); XCTAssertEqual(list, [FavoriteEntry(projectID: pid, position: 0)])
        _ = try await client.setFavorite(pid, index: 1)
        XCTAssertEqual(last.httpMethod, "PUT"); XCTAssertEqual(path, "/v1/me/favorites/\(pid.uuidString.lowercased())")
        XCTAssertEqual(body(last)["index"] as? Int, 1)
        reply(204, "")
        try await client.removeFavorite(pid)
        XCTAssertEqual(last.httpMethod, "DELETE")
    }

    func testProjectPrefsPatchSendsRevisionAndOnlyChangedKeys() async throws {
        reply(#"{"projectID":"\#(pid)","view":"board","sort":"manual","grouping":"column","showCompleted":true,"isFavorite":false,"revision":4}"#)
        let p = try await client.patchProjectPrefs(pid, revision: 3, ProjectPrefsPatch(view: "board"))
        XCTAssertEqual(last.httpMethod, "PATCH"); XCTAssertEqual(path, "/v1/me/project-prefs/\(pid.uuidString.lowercased())")
        XCTAssertEqual(Set(body(last).keys), ["revision", "view"])
        XCTAssertEqual(body(last)["revision"] as? Int, 3)
        XCTAssertEqual(p.revision, 4); XCTAssertEqual(p.viewMode, .board)
        reply(409, #"{"error":true,"reason":"revision_conflict"}"#)
        do { _ = try await client.patchProjectPrefs(pid, revision: 1, ProjectPrefsPatch(showCompleted: false)); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .conflict(reason: "revision_conflict")) }
    }

    func testProjectPrefsListAndDefaults() async throws {
        reply(#"{"items":[{"projectID":"\#(pid)","view":"list","sort":"title","grouping":"none","showCompleted":false,"isFavorite":true,"favoritePosition":0,"revision":2}]}"#)
        let list = try await client.projectPrefs()
        XCTAssertEqual(path, "/v1/me/project-prefs")
        XCTAssertEqual(list.first?.sortMode, .title); XCTAssertEqual(list.first?.groupMode, ProjectDisplayPrefs.Grouping.none)
        let defaults = ProjectDisplayPrefs(projectID: pid)
        XCTAssertEqual(defaults.groupMode, .column); XCTAssertTrue(defaults.showCompleted); XCTAssertEqual(defaults.revision, 0)
        let merged = ProjectPrefsPatch(view: "board").merged(with: ProjectPrefsPatch(view: "list", sort: "due"))
        XCTAssertEqual(merged, ProjectPrefsPatch(view: "list", sort: "due"))
    }

    func testProjectPositionBodies() async throws {
        reply(#"{"id":"\#(pid)","name":"A","version":1,"position":1}"#)
        _ = try await client.putProjectPosition(pid, index: 1)
        XCTAssertEqual(last.httpMethod, "PUT"); XCTAssertEqual(path, "/v1/projects/\(pid.uuidString.lowercased())/position")
        XCTAssertEqual(body(last)["index"] as? Int, 1)
        XCTAssertNil(body(last)["parentID"]); XCTAssertNil(body(last)["version"])
        _ = try await client.putProjectPosition(pid, index: 0, parent: .root, version: 2)
        XCTAssertTrue(body(last)["parentID"] is NSNull); XCTAssertEqual(body(last)["version"] as? Int, 2)
        _ = try await client.putProjectPosition(pid, index: 0, parent: .parent(uid), version: 2)
        XCTAssertEqual((body(last)["parentID"] as? String)?.lowercased(), uid.uuidString.lowercased())
    }

    func testProjectCommentsCrud() async throws {
        let json = #"{"id":"\#(cid)","projectID":"\#(pid)","authorID":"\#(uid)","authorName":"Ada","body":"Hi","version":1,"createdAt":"2026-10-30T10:00:00Z"}"#
        reply("[\(json)]")
        let list = try await client.projectComments(pid)
        XCTAssertEqual(path, "/v1/projects/\(pid.uuidString.lowercased())/comments")
        XCTAssertEqual(list.first?.authorName, "Ada"); XCTAssertNotNil(list.first?.createdAt)
        let key = UUID()
        reply(201, json)
        _ = try await client.addProjectComment(pid, body: "Hi", idempotencyKey: key)
        XCTAssertEqual(last.httpMethod, "POST"); XCTAssertEqual(last.value(forHTTPHeaderField: "Idempotency-Key"), key.uuidString)
        XCTAssertEqual(body(last)["body"] as? String, "Hi")
        reply(json)
        _ = try await client.editProjectComment(pid, id: cid, version: 1, body: "Yo")
        XCTAssertEqual(last.httpMethod, "PATCH"); XCTAssertEqual(body(last)["version"] as? Int, 1)
        reply(204, "")
        try await client.deleteProjectComment(pid, id: cid, version: 2)
        XCTAssertEqual(last.httpMethod, "DELETE"); XCTAssertEqual(body(last)["version"] as? Int, 2)
        reply(403, #"{"error":true,"reason":"not_comment_author"}"#)
        do { try await client.deleteProjectComment(pid, id: cid, version: 2); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .forbidden(reason: "not_comment_author")) }
    }

    func testActivityFeedDecodesBothSourcesAndPaging() async throws {
        reply(#"{"items":[{"id":"\#(cid)","source":"task","projectID":"\#(pid)","projectName":"P","taskID":"\#(uid)","taskTitle":"T","sequence":3,"actorType":"Person","actorID":"\#(uid)","actorName":"Ada","kind":"task.created","createdAt":"2026-10-30T10:00:00Z"},{"id":"\#(uid)","source":"project","projectID":"\#(pid)","projectName":"P","sequence":1,"actorType":"Run","actorID":"\#(uid)","kind":"agent.future_kind"}],"nextCursor":"1:abc"}"#)
        let feed = try await client.activityFeed(projectID: pid, limit: 20, before: "9:x")
        let q = URLComponents(url: last.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(Set(q.map(\.name)), ["projectID", "limit", "before"])
        XCTAssertEqual(feed.items.count, 2); XCTAssertEqual(feed.nextCursor, "1:abc")
        XCTAssertEqual(feed.items[0].taskTitle, "T"); XCTAssertNil(feed.items[1].taskID); XCTAssertEqual(feed.items[1].kind, "agent.future_kind")
    }

    func testAgentDevicesAndJobs() async throws {
        reply(#"[{"id":"\#(cid)","label":"Mac mini","paired":true,"activeRunCount":1,"bindings":[{"id":"\#(uid)","projectID":"\#(pid)","deviceID":"\#(cid)","repositoryKey":"todo","label":"todo repo"}]},{"id":"\#(uid)","label":"Old","paired":false,"revokedAt":"2026-10-01T00:00:00Z","activeRunCount":0,"bindings":[]}]"#)
        let devices = try await client.agentDevices()
        XCTAssertEqual(path, "/v1/agents/devices")
        XCTAssertEqual(devices.count, 2); XCTAssertEqual(devices[0].bindings.first?.repositoryKey, "todo"); XCTAssertNotNil(devices[1].revokedAt)
        reply(#"{"items":[{"job":{"id":"\#(cid)","taskID":"\#(uid)","projectID":"\#(pid)","bindingID":"\#(uid)","requestedBy":"\#(uid)","taskRevision":2,"mode":"implement","scope":"s","state":"awaiting_review","progress":"done","result":{"summary":"ok","references":[],"checks":["tests"],"limitations":[]}},"taskTitle":"T","projectName":"P","createdAt":"2026-10-30T10:00:00Z"}],"nextCursor":"n"}"#)
        let jobs = try await client.agentJobs(projectID: pid, state: "awaiting_review", limit: 10)
        XCTAssertEqual(path, "/v1/agents/jobs")
        XCTAssertEqual(jobs.items.first?.job.state, "awaiting_review"); XCTAssertEqual(jobs.items.first?.job.result?.checks, ["tests"])
        XCTAssertEqual(jobs.nextCursor, "n")
    }

    func testLocalBoardFromSyncedData() {
        let todo = ProjectColumn(id: UUID(), projectID: pid, name: "Todo", position: 0)
        let done = ProjectColumn(id: UUID(), projectID: pid, name: "Done", isDone: true, position: 1)
        let other = ProjectColumn(id: UUID(), projectID: UUID(), name: "Foreign", position: 0)
        let a = TodoTask(id: UUID(), projectID: pid, title: "a", columnID: todo.id, boardPosition: 1)
        let b = TodoTask(id: UUID(), projectID: pid, title: "b", columnID: todo.id, boardPosition: 0)
        let c = TodoTask(id: UUID(), projectID: pid, title: "c")
        let board = Board.local(projectID: pid, columns: [done, other, todo], tasks: [a, b, c])
        XCTAssertTrue(board.hasOwnColumns)
        XCTAssertEqual(board.columns.map(\.name), ["Todo", "Done"])
        XCTAssertEqual(board.columns[0].tasks.map(\.title), ["b", "a"])
        XCTAssertEqual(board.unassigned.map(\.title), ["c"])
        let status = Board.local(projectID: pid, columns: [], tasks: [a, TodoTask(id: UUID(), projectID: pid, title: "x", status: "done")], statusNames: ["open": "Offen"])
        XCTAssertFalse(status.hasOwnColumns)
        XCTAssertEqual(status.columns.map(\.name), ["Offen", "in_progress", "in_review", "done"])
        XCTAssertEqual(status.columns[3].tasks.map(\.title), ["x"])
    }
}
