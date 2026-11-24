import XCTest
@testable import TodoCore

/// Block "Jetzt" (`now`, contract session-status 1.4.0): decoding, tolerance, compact fetch, grouping helpers.
final class NowBlockTests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let now = ISO8601DateFormatter().date(from: "2026-11-24T12:00:00Z")!
    private let p1 = "11111111-1111-1111-1111-111111111111"
    private let t1 = "22222222-2222-2222-2222-222222222222"
    private let t2 = "33333333-3333-3333-3333-333333333333"

    override func setUp() {
        MockURLProtocol.seen = []
        MockURLProtocol.handler = nil
        try? store.save("tok")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: URL(string: "http://test.invalid")!, session: URLSession(configuration: config), tokenStore: store)
    }

    private func decode(_ s: String) throws -> OverviewNow {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(OverviewNow.self, from: Data(s.utf8))
    }

    private var task: String {
        #"{"kind":"task","projectID":"\#(p1)","projectName":"Todolino","taskID":"\#(t1)","title":"Passkey absichern","text":"Tests laufen","worker":"Claude","since":"2026-11-24T10:00:00Z","lastSignAt":"2026-11-24T11:58:00Z","ageSeconds":120,"dueAt":"2026-11-24T18:00:00Z","percent":60}"#
    }
    private var session: String {
        #"{"kind":"session","projectID":"\#(p1)","projectName":"Todolino","title":"web-passkey","text":"Fuehrt vitest aus","worker":null,"lastSignAt":"2026-11-24T11:59:00Z","ageSeconds":60}"#
    }
    private var question: String {
        #"{"kind":"question","id":"44444444-4444-4444-4444-444444444444","projectID":"\#(p1)","projectName":"Todolino","taskID":"\#(t2)","taskTitle":"Runner","text":"Pausieren?","createdAt":"2026-11-24T11:00:00Z"}"#
    }
    private var review: String {
        #"{"kind":"review","id":"55555555-5555-5555-5555-555555555555","projectID":"\#(p1)","projectName":"Todolino","taskID":"\#(t1)","taskTitle":"Kalender","text":"Fertig","createdAt":"2026-11-24T10:00:00Z"}"#
    }
    private var done: String {
        #"{"taskID":"\#(t1)","title":"Label loeschen","projectID":"\#(p1)","projectName":"Todolino Apple","doneAt":"2026-11-24T09:30:00Z"}"#
    }
    private func block(running: String = "[]", waiting: String = "[]", done: String = "[]", silent: String = "[]",
                        counts: String = #"{"running":0,"waiting":0,"recentlyDone":0,"silent":0}"#) -> String {
        #"{"serverTime":"2026-11-24T12:00:00Z","now":{"counts":\#(counts),"running":\#(running),"waiting":\#(waiting),"recentlyDone":\#(done),"silent":\#(silent)}}"#
    }

    // MARK: Decoding

    func testDecodesFullBlockWithoutProjects() throws {
        let o = try decode(block(running: "[\(task),\(session)]", waiting: "[\(question),\(review)]", done: "[\(done)]", silent: "[\(session)]",
                                 counts: #"{"running":2,"waiting":2,"recentlyDone":1,"silent":7}"#))
        XCTAssertTrue(o.projects.isEmpty, "compact has no projects")
        let b = try XCTUnwrap(o.now)
        XCTAssertEqual(b.counts, NowCounts(running: 2, waiting: 2, recentlyDone: 1, silent: 7))
        XCTAssertEqual(b.running.map(\.kind), [.task, .session])
        let t = b.running[0]
        XCTAssertEqual(t.title, "Passkey absichern")
        XCTAssertEqual(t.text, "Tests laufen")
        XCTAssertEqual(t.worker, "Claude")
        XCTAssertEqual(t.percent, 60)
        XCTAssertEqual(t.ageSeconds, 120)
        XCTAssertEqual(t.taskID, UUID(uuidString: t1))
        XCTAssertNotNil(t.dueAt)
        XCTAssertNotNil(t.since)
        XCTAssertNil(b.running[1].taskID)
        XCTAssertNil(b.running[1].worker)
        XCTAssertEqual(b.waiting.map(\.kind), [.question, .review])
        XCTAssertEqual(b.waiting[0].taskTitle, "Runner")
        XCTAssertEqual(b.recentlyDone.first?.projectName, "Todolino Apple")
        XCTAssertEqual(b.silent.count, 1)
    }

    func testOldServerWithoutNowIsNil() throws {
        XCTAssertNil(try decode(#"{"serverTime":"2026-11-24T12:00:00Z","projects":[]}"#).now)
    }

    func testBlockToleratesBrokenElementsAndUnknownKinds() throws {
        // A broken element (no title key is fine, missing identity is not), an unknown kind and a wrong type drop out; siblings survive.
        let bad = #"{"kind":"task","title":"ohne Projekt"}"#
        let unknown = #"{"kind":"hologram","projectID":"\#(p1)","projectName":"x","title":"y","text":"","lastSignAt":"2026-11-24T11:59:00Z","ageSeconds":1}"#
        let o = try decode(block(running: "[\(bad),\(unknown),\(task),\"quatsch\"]", waiting: "[\(question),{\"kind\":\"question\"}]", done: "\"x\""))
        let b = try XCTUnwrap(o.now)
        XCTAssertEqual(b.running.map(\.title), ["Passkey absichern"])
        XCTAssertEqual(b.waiting.count, 1)
        XCTAssertTrue(b.recentlyDone.isEmpty)
    }

    func testCountsMissingFallBackToListLengthsAndNeverUndercount() throws {
        let o = try decode(#"{"now":{"running":[\#(task)],"waiting":[],"recentlyDone":[],"silent":[\#(session),\#(session)],"counts":{"silent":1}}}"#)
        let c = try XCTUnwrap(o.now).counts
        XCTAssertEqual(c.running, 1)
        XCTAssertEqual(c.silent, 2, "a count below the list length is raised to it")
    }

    func testPercentOutOfRangeIsDropped() throws {
        let t = task.replacingOccurrences(of: #""percent":60"#, with: #""percent":140"#)
        XCTAssertNil(try XCTUnwrap(decode(block(running: "[\(t)]")).now).running[0].percent)
    }

    // MARK: Grouping helpers

    func testHasContentAndEmptyPage() throws {
        let empty = try decode(block())
        XCTAssertFalse(try XCTUnwrap(empty.now).hasContent)
        XCTAssertTrue(empty.showsEmptyPage)
        let silentOnly = try decode(block(silent: "[\(session)]", counts: #"{"running":0,"waiting":0,"recentlyDone":0,"silent":1}"#))
        XCTAssertTrue(try XCTUnwrap(silentOnly.now).hasContent, "silent entries count as content")
        XCTAssertFalse(silentOnly.showsEmptyPage)
        let old = try decode(#"{"projects":[]}"#)
        XCTAssertTrue(old.showsEmptyPage)
    }

    func testHiddenCountsBeyondLimit() throws {
        let b = try XCTUnwrap(decode(block(running: "[\(task)]", waiting: "[\(question)]", done: "[\(done)]", silent: "[\(session)]",
                                          counts: #"{"running":4,"waiting":1,"recentlyDone":3,"silent":9}"#)).now)
        XCTAssertEqual(b.hiddenRunning, 3)
        XCTAssertEqual(b.hiddenWaiting, 0)
        XCTAssertEqual(b.hiddenDone, 2)
        XCTAssertEqual(b.hiddenSilent, 8)
    }

    func testOverdueOnlyWithDueDateInThePast() throws {
        let b = try XCTUnwrap(decode(block(running: "[\(task),\(session)]")).now)
        XCTAssertFalse(b.running[0].isOverdue(at: now), "due 18:00, now 12:00")
        XCTAssertTrue(b.running[0].isOverdue(at: now.addingTimeInterval(7 * 3600)))
        XCTAssertFalse(b.running[1].isOverdue(at: now.addingTimeInterval(7 * 3600)), "no due date")
    }

    func testWaitingDestinationQuestionByIDReviewByTask() throws {
        let b = try XCTUnwrap(decode(block(waiting: "[\(question),\(review)]")).now)
        XCTAssertEqual(b.waiting[0].taskID, UUID(uuidString: t2))
        XCTAssertEqual(b.waiting[0].isQuestion, true)
        XCTAssertEqual(b.waiting[1].isQuestion, false)
    }

    // MARK: API (compact)

    func testFetchCompactSendsQueryAndDecodesNow() async throws {
        MockURLProtocol.handler = { _ in (200, Data(self.block(running: "[\(self.task)]", counts: #"{"running":1,"waiting":0,"recentlyDone":0,"silent":0}"#).utf8)) }
        guard case .loaded(let o) = try await client.fetchOverviewNow(compact: true, limit: 5) else { return XCTFail("expected loaded") }
        XCTAssertEqual(o.now?.running.count, 1)
        let url = try XCTUnwrap(MockURLProtocol.seen.last?.url)
        XCTAssertEqual(url.path, "/v1/overview/now")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "compact" }?.value, "true")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "5")
    }

    func testFetchDefaultSendsNoQuery() async throws {
        MockURLProtocol.handler = { _ in (200, Data(self.block().utf8)) }
        _ = try await client.fetchOverviewNow()
        XCTAssertNil(MockURLProtocol.seen.last?.url?.query)
    }
}
