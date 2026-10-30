import XCTest
@testable import TodoCore

final class BoardTests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let pid = UUID(), cid = UUID(), tid = UUID()

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
    private var taskJSON: String { #"{"id":"\#(tid)","projectID":"\#(pid)","columnID":"\#(cid)","title":"T","description":"d","status":"open","version":2}"# }
    private var columnJSON: String { ##"{"id":"\##(cid)","projectID":"\##(pid)","name":"Ideen","color":"#DB4C3F","isDone":false,"position":0,"version":1}"## }

    func testBoardDecodesColumnsModeWithUnassigned() async throws {
        reply(#"{"projectID":"\#(pid)","mode":"columns","columns":[{"id":"\#(cid)","key":null,"name":"Ideen","color":null,"isDone":false,"position":0,"version":1,"tasks":[\#(taskJSON)]}],"unassigned":[\#(taskJSON)]}"#)
        let board = try await client.board(projectID: pid)
        XCTAssertEqual(last.url?.path, "/v1/projects/\(pid.uuidString.lowercased())/board")
        XCTAssertTrue(board.hasOwnColumns)
        XCTAssertEqual(board.columns.first?.tasks.first?.id, tid)
        XCTAssertEqual(board.columns.first?.isReal, true)
        XCTAssertEqual(board.unassigned.count, 1)
    }

    func testBoardStatusModeHasVirtualColumns() async throws {
        reply(#"{"projectID":"\#(pid)","mode":"status","columns":[{"id":null,"key":"open","name":"Offen","color":null,"isDone":false,"position":0,"version":null,"tasks":[]}],"unassigned":[]}"#)
        let board = try await client.board(projectID: pid)
        XCTAssertFalse(board.hasOwnColumns)
        XCTAssertEqual(board.columns.first?.key, "open")
        XCTAssertEqual(board.columns.first?.isReal, false)
        XCTAssertEqual(board.columns.first?.stableID, "open")
    }

    func testCreateUpdateColumnRequestShapes() async throws {
        reply(201, columnJSON)
        let c = try await client.createColumn(projectID: pid, name: "Ideen", color: "#DB4C3F", index: 2)
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.url?.path, "/v1/projects/\(pid.uuidString.lowercased())/columns")
        XCTAssertEqual(body(last)["name"] as? String, "Ideen")
        XCTAssertEqual(body(last)["index"] as? Int, 2)
        XCTAssertEqual(c.id, cid)
        reply(columnJSON)
        _ = try await client.updateColumn(projectID: pid, columnID: cid, version: 1, name: "Neu", index: 0)
        XCTAssertEqual(last.httpMethod, "PATCH")
        XCTAssertEqual(last.url?.path, "/v1/projects/\(pid.uuidString.lowercased())/columns/\(cid.uuidString.lowercased())")
        XCTAssertEqual(body(last)["version"] as? Int, 1)
        XCTAssertEqual(body(last)["name"] as? String, "Neu")
    }

    func testDeleteColumnQuery() async throws {
        reply(204, "")
        try await client.deleteColumn(projectID: pid, columnID: cid, toUnassigned: true, version: 3)
        XCTAssertEqual(last.httpMethod, "DELETE")
        XCTAssertEqual(Set((last.url?.query ?? "").split(separator: "&").map(String.init)), ["moveTo=none", "version=3"])
        let other = UUID()
        try await client.deleteColumn(projectID: pid, columnID: cid, moveTo: other)
        XCTAssertEqual(last.url?.query, "moveTo=\(other.uuidString.lowercased())")
    }

    func testMoveTaskSendsExplicitNullForUnassigned() async throws {
        reply(taskJSON)
        _ = try await client.moveTask(tid, version: 2, toColumn: nil, index: 1)
        XCTAssertEqual(last.httpMethod, "PUT")
        XCTAssertEqual(last.url?.path, "/v1/tasks/\(tid.uuidString.lowercased())/column")
        XCTAssertTrue(body(last)["columnID"] is NSNull)
        XCTAssertEqual(body(last)["index"] as? Int, 1)
        _ = try await client.moveTask(tid, version: 2, toColumn: cid)
        XCTAssertEqual(body(last)["columnID"] as? String, cid.uuidString)
        XCTAssertNil(body(last)["index"])
    }

    func testBoardNotFoundOnOldServer() async {
        reply(404, #"{"reason":"not found"}"#)
        do { _ = try await client.board(projectID: pid); XCTFail() } catch { XCTAssertEqual(error as? APIError, .notFound) }
    }

    func testSyncFeedDecodesColumnEntriesAndSkipsUnknownEntityTypes() throws {
        let json = #"{"changes":[{"seq":1,"entityType":"column","entityID":"\#(cid)","kind":"upsert","column":\#(columnJSON)},{"seq":2,"entityType":"widget","entityID":"\#(cid)","kind":"upsert"},{"seq":3,"entityType":"task","entityID":"\#(tid)","kind":"upsert","task":\#(taskJSON)}],"cursor":"c3","hasMore":false}"#
        let feed = try JSONDecoder().decode(SyncChanges.self, from: Data(json.utf8))
        XCTAssertEqual(feed.changes.count, 2)
        XCTAssertEqual(feed.changes.first?.column?.name, "Ideen")
        XCTAssertEqual(feed.changes.last?.task?.columnID, cid)
        XCTAssertEqual(feed.cursor, "c3")
    }
}
