import XCTest
@testable import TodoCore

final class FeedTests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let pid = UUID(), tid = UUID(), qid = UUID(), rid = UUID(), aid = UUID()

    override func setUp() {
        MockURLProtocol.seen = []
        MockURLProtocol.handler = nil
        try? store.save("tok")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: URL(string: "http://test.invalid")!, session: URLSession(configuration: config), tokenStore: store)
    }

    private func reply(_ s: String, status: Int = 200) { MockURLProtocol.handler = { _ in (status, Data(s.utf8)) } }
    private var last: URLRequest { MockURLProtocol.seen.last! }
    private func query(_ r: URLRequest) -> [String: String] {
        let items = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
    private func body(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    private func post(_ id: UUID = UUID(), text: String = "Schema fertig") -> String {
        #"{"id":"\#(id)","kind":"build","event":"build.added","state":null,"projectID":"\#(pid)","projectName":"App","taskID":"\#(tid)","taskTitle":"Login","actor":{"type":"Integration","id":"\#(UUID())","name":"Claude"},"text":"\#(text)","detail":null,"percent":null,"images":[{"attachmentID":"\#(aid)","buildArtifactID":"\#(UUID())","filename":"a.png","mediaType":"image/png","previewURL":"/v1/attachments/\#(aid)/preview","buildID":"b1","label":"Login","platform":"ios"}],"createdAt":"2026-10-30T10:00:00.5Z"}"#
    }
    private var needsJSON: String {
        #"[{"id":"question:\#(qid)","kind":"question","projectID":"\#(pid)","projectName":"App","taskID":"\#(tid)","taskTitle":"Login","taskVersion":3,"title":"Welche DB?","detail":null,"options":["MariaDB","SQLite"],"blocking":true,"questionID":"\#(qid)","reviewID":null,"dueAt":null,"actor":{"type":"Run","id":"\#(UUID())","name":"Runner"},"createdAt":"2026-10-30T10:00:00Z","actions":[{"key":"answer","label":"MariaDB","method":"POST","path":"/v1/questions/\#(qid)/answer","body":{"answer":"MariaDB"},"requiresInput":false,"inputField":null},{"key":"answer","label":"Anderes","method":"POST","path":"/v1/questions/\#(qid)/answer","body":null,"requiresInput":true,"inputField":"answer"}]},{"id":"review:\#(rid)","kind":"review","projectID":"\#(pid)","projectName":"App","taskID":"\#(tid)","taskTitle":"Login","taskVersion":3,"title":"Fertig","detail":null,"options":[],"blocking":false,"questionID":null,"reviewID":"\#(rid)","dueAt":null,"actor":null,"createdAt":null,"actions":[{"key":"request_changes","label":"Änderungen","method":"POST","path":"/v1/tasks/\#(tid)/review/decision","body":{"decision":"request_changes"},"requiresInput":true,"inputField":"note"}]}]"#
    }

    func testRequestShapeAndDecoding() async throws {
        let p1 = UUID()
        reply(#"{"generatedAt":"2026-10-30T10:00:00Z","mode":"all","projectID":null,"needsYou":\#(needsJSON),"needsYouTotal":14,"posts":[\#(post(p1))],"nextCursor":"abc_def"}"#)
        let page = try await client.feed(cursor: "x_y", limit: 20, projectID: pid, mode: .classic)
        XCTAssertEqual(last.url?.path, "/v1/feed")
        XCTAssertEqual(query(last), ["cursor": "x_y", "limit": "20", "projectID": pid.uuidString.lowercased(), "mode": "classic"])
        XCTAssertEqual(last.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(page.needsYou.count, 2)
        XCTAssertEqual(page.needsYouTotal, 14)
        XCTAssertEqual(page.needsYou[0].actions.count, 2)
        XCTAssertEqual(page.needsYou[0].actor?.isAgent, true)
        XCTAssertNil(page.needsYou[1].actor)
        XCTAssertEqual(page.posts[0].postKind, .build)
        XCTAssertEqual(page.posts[0].images.first?.attachmentID, aid)
        XCTAssertEqual(page.nextCursor, "abc_def")
        XCTAssertEqual(page.posts[0].id, p1)
    }

    func testUnknownKindsStayReadable() async throws {
        reply(#"{"generatedAt":"2026-10-30T10:00:00Z","mode":"all","projectID":null,"needsYou":[],"needsYouTotal":0,"posts":[\#(post().replacingOccurrences(of: "\"build\",\"event\"", with: "\"future\",\"event\""))],"nextCursor":null}"#)
        let page = try await client.feed()
        XCTAssertNil(page.posts[0].postKind)
        XCTAssertEqual(page.posts[0].kind, "future")
        XCTAssertTrue(MockURLProtocol.seen.last!.url!.query == nil)
    }

    func testActionsAreSentAsDescribed() async throws {
        reply(#"{"needsYou":[]}"#)
        reply(#"{"ok":true}"#)
        let page = FeedPage(generatedAt: Date(), mode: "all", projectID: nil, needsYou: try JSONDecoder.feed.decode([FeedNeedsYou].self, from: Data(needsJSON.utf8)), needsYouTotal: 2, posts: [], nextCursor: nil)
        let option = page.needsYou[0].actions[0]
        try await client.perform(option)
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.url?.path, "/v1/questions/\(qid)/answer")
        XCTAssertEqual(body(last)["answer"] as? String, "MariaDB")
        try await client.perform(page.needsYou[0].actions[1], input: "  Postgres ")
        XCTAssertEqual(body(last)["answer"] as? String, "Postgres")
        do { try await client.perform(page.needsYou[0].actions[1], input: "  "); XCTFail("empty answer sent") }
        catch { XCTAssertEqual(error as? APIError, .invalidInput(reason: "answer_required")) }
        try await client.perform(page.needsYou[1].actions[0], input: "")
        XCTAssertEqual(body(last)["decision"] as? String, "request_changes")
        XCTAssertNil(body(last)["note"])
        try await client.perform(page.needsYou[1].actions[0], input: "Test fehlt")
        XCTAssertEqual(body(last)["note"] as? String, "Test fehlt")
    }

    func testOldServerAndForbiddenMapping() async throws {
        reply(#"{"reason":"Not Found"}"#, status: 404)
        do { _ = try await client.feed(); XCTFail() } catch { XCTAssertEqual(error as? APIError, .notFound) }
    }

    func testStateReplaceAppendDedupe() throws {
        func page(_ ids: [UUID], next: String?, needs: [FeedNeedsYou] = []) throws -> FeedPage {
            let posts = try ids.map { try JSONDecoder.feed.decode(FeedPost.self, from: Data(post($0).utf8)) }
            return FeedPage(generatedAt: Date(), mode: "all", projectID: nil, needsYou: needs, needsYouTotal: needs.count, posts: posts, nextCursor: next)
        }
        let a = UUID(), b = UUID(), c = UUID()
        var state = FeedState()
        XCTAssertFalse(state.isEmpty)
        let needs = try JSONDecoder.feed.decode([FeedNeedsYou].self, from: Data(needsJSON.utf8))
        state.replace(with: try page([a, b], next: "n1", needs: needs))
        XCTAssertEqual(state.needsYouTotal, 2)
        state.append(try page([b, c], next: nil))
        XCTAssertEqual(state.posts.map(\.id), [a, b, c])
        XCTAssertNil(state.nextCursor)
        state.remove(needsYouID: needs[0].id)
        XCTAssertEqual(state.needsYou.count, 1)
        XCTAssertEqual(state.needsYouTotal, 1)
        state.replace(with: try page([], next: nil))
        XCTAssertTrue(state.isEmpty)
    }
}

private extension JSONDecoder {
    static var feed: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let g = ISO8601DateFormatter()
            if let date = f.date(from: raw) ?? g.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: raw))
        }
        return d
    }
}
