import XCTest
@testable import TodoCore

/// Chat of a card, a question or a review (contracts/collaboration.yaml: listComments with questionID/reviewID/thread,
/// createComment with questionID/reviewID).
final class ConversationTests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let tid = UUID(), me = UUID(), other = UUID()

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
    private func comment(_ id: UUID = UUID(), author: UUID, extra: String = "") -> String {
        #"{"id":"\#(id)","taskID":"\#(tid)","authorID":"\#(author)","authorName":"Lino","body":"hi","version":1\#(extra)}"#
    }

    func testListQueryPerThread() async throws {
        reply("[]")
        let q = UUID(), r = UUID()
        _ = try await client.comments(taskID: tid)
        XCTAssertEqual(last.url?.path, "/v1/tasks/\(tid.uuidString)/comments")
        XCTAssertNil(last.url?.query)
        _ = try await client.comments(taskID: tid, thread: .task)
        XCTAssertEqual(last.url?.query, "thread=task")
        _ = try await client.comments(taskID: tid, thread: .question(q))
        XCTAssertEqual(last.url?.query, "questionID=\(q.uuidString)")
        _ = try await client.comments(taskID: tid, thread: .review(r))
        XCTAssertEqual(last.url?.query, "reviewID=\(r.uuidString)")
    }

    func testCreateSendsThreadTarget() async throws {
        let q = UUID(), r = UUID()
        reply(201, comment(author: me))
        _ = try await client.addComment(taskID: tid, body: "a", thread: .task)
        XCTAssertNil(body(last)["questionID"])
        XCTAssertNil(body(last)["reviewID"])
        _ = try await client.addComment(taskID: tid, body: "b", thread: .question(q))
        XCTAssertEqual(body(last)["questionID"] as? String, q.uuidString)
        XCTAssertNil(body(last)["reviewID"])
        _ = try await client.addComment(taskID: tid, body: "c", thread: .review(r))
        XCTAssertEqual(body(last)["reviewID"] as? String, r.uuidString)
        XCTAssertNil(body(last)["questionID"])
        XCTAssertEqual(body(last)["body"] as? String, "c")
        XCTAssertNotNil(last.value(forHTTPHeaderField: "Idempotency-Key"))
    }

    func testDecodesChatFieldsAndAttachments() async throws {
        let q = UUID(), a = UUID()
        reply("[" + comment(author: other, extra: #","questionID":"\#(q)","reviewID":null,"authorKind":"agent","authorLabel":"claude-code@mac","createdAt":"2026-11-12T08:00:00.250Z""#)
              + "," + comment(author: me, extra: #","kind":"attachment","attachmentID":"\#(a)","attachments":[{"id":"\#(a)","filename":"shot.png","mediaType":"image/png","size":12}]"#)
              + "," + comment(author: me) + "]")
        let list = try await client.comments(taskID: tid, thread: .question(q))
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].questionID, q)
        XCTAssertNil(list[0].reviewID)
        XCTAssertTrue(list[0].isAgent)
        XCTAssertEqual(list[0].authorLabel, "claude-code@mac")
        XCTAssertNotNil(list[0].createdAt)
        XCTAssertTrue(list[1].isAttachment)
        XCTAssertEqual(list[1].attachments?.first?.filename, "shot.png")
        XCTAssertEqual(list[1].attachments?.first?.isImage, true)
        // Old messages without the chat fields still decode as plain person messages.
        XCTAssertFalse(list[2].isAgent)
        XCTAssertFalse(list[2].isAttachment)
        XCTAssertNil(list[2].createdAt)
    }

    func testAuthorRoleMineAgentOther() throws {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        func decode(_ s: String) throws -> Comment { try d.decode(Comment.self, from: Data(s.utf8)) }
        let mine = try decode(comment(author: me))
        let agentByMyToken = try decode(comment(author: me, extra: #","authorKind":"agent","authorLabel":"  ""#))
        let person = try decode(comment(author: other))
        XCTAssertEqual(mine.author(me: me), .me)
        // An agent writes with the person's MCP token: same authorID, but it is not "you".
        XCTAssertEqual(agentByMyToken.author(me: me), .agent(nil))
        XCTAssertEqual(try decode(comment(author: other, extra: #","authorKind":"agent","authorLabel":"Claude""#)).author(me: me), .agent("Claude"))
        XCTAssertEqual(person.author(me: me), .person("Lino"))
        XCTAssertEqual(person.author(me: nil), .person("Lino"))
        XCTAssertTrue(mine.isMine(me))
        XCTAssertFalse(agentByMyToken.isMine(me))
    }

    func testThreadIdentity() {
        let q = UUID()
        XCTAssertEqual(CommentThread.question(q), .question(q))
        XCTAssertNotEqual(CommentThread.question(q), .review(q))
        XCTAssertEqual(CommentThread.question(q).queryItems, [URLQueryItem(name: "questionID", value: q.uuidString)])
        XCTAssertEqual(CommentThread.all.queryItems, [])
    }
}
