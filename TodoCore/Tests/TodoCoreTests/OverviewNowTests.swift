import XCTest
@testable import TodoCore

final class OverviewNowTests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let now = ISO8601DateFormatter().date(from: "2026-11-18T12:00:00Z")!

    override func setUp() {
        MockURLProtocol.seen = []
        MockURLProtocol.handler = nil
        try? store.save("tok")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: URL(string: "http://test.invalid")!, session: URLSession(configuration: config), tokenStore: store)
    }

    private func reply(_ status: Int, _ s: String) { MockURLProtocol.handler = { _ in (status, Data(s.utf8)) } }

    private let p1 = "11111111-1111-1111-1111-111111111111"
    private let t1 = "22222222-2222-2222-2222-222222222222"

    /// A project JSON with the given pieces; the rest stays empty.
    private func project(id: String = "11111111-1111-1111-1111-111111111111", name: String = "Todolino", last: String = "2026-11-18T11:59:00Z",
                         running: String = "[]", sessions: String = "[]", questions: String = "[]", reviews: String = "[]") -> String {
        #"{"projectID":"\#(id)","projectName":"\#(name)","lastActivityAt":"\#(last)","runningTasks":\#(running),"sessions":\#(sessions),"agentJobs":[],"builds":[],"openQuestions":\#(questions),"pendingReviews":\#(reviews),"recentActivity":[]}"#
    }
    private func doc(_ projects: String...) -> String { #"{"serverTime":"2026-11-18T12:00:00Z","projects":[\#(projects.joined(separator: ","))]}"# }
    private func decode(_ s: String) throws -> OverviewNow {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(OverviewNow.self, from: Data(s.utf8))
    }
    private let item = #"[{"id":"33333333-3333-3333-3333-333333333333","taskID":"22222222-2222-2222-2222-222222222222","taskTitle":"Runner","text":"Pausieren?","createdAt":"2026-11-18T11:00:00Z"}]"#
    private let runningJSON = #"[{"taskID":"22222222-2222-2222-2222-222222222222","title":"Passkey","worker":"Claude","lastProgress":{"note":"Tests laufen","at":"2026-11-18T11:58:00Z"},"ageSeconds":240,"percent":60}]"#

    // MARK: Decoding

    func testDecodesFullDocument() throws {
        let full = #"{"serverTime":"2026-11-18T12:00:00Z","projects":[{"projectID":"\#(p1)","projectName":"Todolino","lastActivityAt":"2026-11-18T11:59:00Z","runningTasks":\#(runningJSON),"sessions":[{"sessionName":"web","activity":"vitest","updatedAt":"2026-11-18T11:59:00Z","ageSeconds":60,"orphaned":false}],"agentJobs":[{"jobID":"44444444-4444-4444-4444-444444444444","taskID":"\#(t1)","state":"running","mode":"work","progress":"x"}],"builds":[{"taskID":"\#(t1)","buildID":"d955b88c0ffee","label":"CI","platform":"ios","createdAt":"2026-11-18T11:00:00Z","commit":"d955b88c0ffee"}],"openQuestions":\#(item),"pendingReviews":[],"recentActivity":[{"taskID":"\#(t1)","taskTitle":"Passkey","kind":"progress","actorType":"agent","createdAt":"2026-11-18T11:58:00Z"}],"zukunft":{"a":1}}],"neu":true}"#
        let o = try decode(full)
        let p = try XCTUnwrap(o.projects.first)
        XCTAssertEqual(p.projectName, "Todolino")
        XCTAssertEqual(p.runningTasks.first?.percent, 60)
        XCTAssertEqual(p.runningTasks.first?.lastProgress?.note, "Tests laufen")
        XCTAssertEqual(p.sessions.first?.sessionName, "web")
        XCTAssertEqual(p.builds.first?.commitShort, "d955b88")
        XCTAssertEqual(p.builds.first?.platform, "ios")
        XCTAssertEqual(p.openQuestions.first?.text, "Pausieren?")
        XCTAssertEqual(p.recentActivity.first?.kind, "progress")
        XCTAssertEqual(p.agentJobs.count, 1)
    }

    func testMissingAndMalformedFieldsDropOut() throws {
        // Missing arrays, wrong types, a broken element between good ones, percent out of range, bad commit.
        let s = #"{"projects":[{"projectID":"\#(p1)","projectName":"A","runningTasks":[{"taskID":"\#(t1)","title":"ok","percent":"viel"},{"title":"ohne id"},{"taskID":"\#(t1)","title":"zwei","percent":140}],"builds":[{"taskID":"\#(t1)","buildID":"zz","createdAt":"2026-11-18T11:00:00Z","commit":"ZZ"}]},{"projectName":"ohne id"},"quatsch"]}"#
        let o = try decode(s)
        XCTAssertNil(o.serverTime)
        XCTAssertEqual(o.projects.count, 1)
        let p = o.projects[0]
        XCTAssertNil(p.lastActivityAt)
        XCTAssertEqual(p.runningTasks.map(\.title), ["ok", "zwei"])
        XCTAssertNil(p.runningTasks[0].percent)
        XCTAssertNil(p.runningTasks[1].percent)
        XCTAssertNil(p.builds[0].commit)
        XCTAssertTrue(p.sessions.isEmpty && p.openQuestions.isEmpty && p.pendingReviews.isEmpty)
    }

    func testGarbageRootDoesNotThrow() throws {
        XCTAssertTrue(try decode("[]").projects.isEmpty)
        XCTAssertTrue(try decode(#"{"projects":"x"}"#).projects.isEmpty)
    }

    // MARK: API

    func testFetchLoadsAndSendsBearer() async throws {
        reply(200, doc(project(running: runningJSON)))
        let r = try await client.fetchOverviewNow()
        guard case .loaded(let o) = r else { return XCTFail("expected loaded") }
        XCTAssertEqual(o.projects.count, 1)
        let req = try XCTUnwrap(MockURLProtocol.seen.last)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.path, "/v1/overview/now")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testFetchOldServerIsUnsupportedNotCrash() async throws {
        reply(404, #"{"error":true,"reason":"Not Found"}"#)
        let r = try await client.fetchOverviewNow()
        guard case .unsupported = r else { return XCTFail("expected unsupported") }
    }

    func testFetchUnauthorizedStillThrows() async {
        reply(401, #"{"error":true,"reason":"unauthorized"}"#)
        do { _ = try await client.fetchOverviewNow(); XCTFail() } catch { XCTAssertTrue(error is APIError) }
    }

    // MARK: Grouping

    func testProjectWithOpenQuestionIsNeverQuietAndOnTop() throws {
        // Last activity three days ago, nothing running, but an open question.
        let old = project(id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", name: "Alt", last: "2026-11-15T12:00:00Z", questions: item)
        let busy = project(name: "Aktiv", running: runningJSON)
        let g = try decode(doc(busy, old)).grouped(at: now)
        XCTAssertEqual(g.waiting.map(\.projectName), ["Alt"])
        XCTAssertEqual(g.active.map(\.projectName), ["Aktiv"])
        XCTAssertTrue(g.quiet.isEmpty)
        XCTAssertEqual(g.ordered.map(\.projectName), ["Alt", "Aktiv"])
        XCTAssertTrue(g.defaultExpanded(g.waiting[0]))
        XCTAssertTrue(g.defaultExpanded(g.active[0]))
    }

    func testOpenReviewAlsoWaits() throws {
        let g = try decode(doc(project(last: "2026-11-01T12:00:00Z", reviews: item))).grouped(at: now)
        XCTAssertEqual(g.waiting.count, 1)
        XCTAssertTrue(g.quiet.isEmpty)
    }

    func testQuietRules() throws {
        let recent = #"[{"sessionName":"s","activity":"a","updatedAt":"2026-11-18T10:00:00Z","ageSeconds":7200,"orphaned":true}]"#
        let stale = #"[{"sessionName":"s","activity":"a","updatedAt":"2026-11-16T10:00:00Z","ageSeconds":180000,"orphaned":true}]"#
        let g = try decode(doc(
            project(id: "a0000000-0000-0000-0000-000000000001", name: "ruhig", last: "2026-11-17T11:00:00Z"),
            project(id: "a0000000-0000-0000-0000-000000000002", name: "mit Session", last: "2026-11-17T11:00:00Z", sessions: recent),
            project(id: "a0000000-0000-0000-0000-000000000003", name: "alte Session", last: "2026-11-17T11:00:00Z", sessions: stale),
            project(id: "a0000000-0000-0000-0000-000000000004", name: "frisch", last: "2026-11-18T09:00:00Z"),
            project(id: "a0000000-0000-0000-0000-000000000005", name: "laeuft", last: "2026-11-10T09:00:00Z", running: runningJSON)
        )).grouped(at: now)
        XCTAssertEqual(Set(g.quiet.map(\.projectName)), ["ruhig", "alte Session"])
        XCTAssertEqual(Set(g.active.map(\.projectName)), ["mit Session", "frisch", "laeuft"])
        XCTAssertFalse(g.defaultExpanded(g.quiet[0]))
    }

    func testBoundaryExactly24HoursIsStillActive() throws {
        let g = try decode(doc(project(last: "2026-11-17T12:00:00Z"))).grouped(at: now)
        XCTAssertEqual(g.active.count, 1)
        let h = try decode(doc(project(last: "2026-11-17T11:59:59Z"))).grouped(at: now)
        XCTAssertEqual(h.quiet.count, 1)
    }

    func testSortedByLastActivityNewestFirstWithinGroups() throws {
        let g = try decode(doc(
            project(id: "a0000000-0000-0000-0000-000000000001", name: "alt", last: "2026-11-18T09:00:00Z"),
            project(id: "a0000000-0000-0000-0000-000000000002", name: "neu", last: "2026-11-18T11:30:00Z"),
            project(id: "a0000000-0000-0000-0000-000000000003", name: "q1", last: "2026-11-10T09:00:00Z"),
            project(id: "a0000000-0000-0000-0000-000000000004", name: "q2", last: "2026-11-12T09:00:00Z")
        )).grouped(at: now)
        XCTAssertEqual(g.active.map(\.projectName), ["neu", "alt"])
        XCTAssertEqual(g.quiet.map(\.projectName), ["q2", "q1"])
    }

    func testMissingLastActivityWithoutContentIsQuiet() throws {
        let g = try decode(#"{"projects":[{"projectID":"\#(p1)","projectName":"x"}]}"#).grouped(at: now)
        XCTAssertEqual(g.quiet.count, 1)
        XCTAssertFalse(g.isEmpty)
    }

    func testEmptyGroups() throws {
        XCTAssertTrue(try decode(doc()).grouped(at: now).isEmpty)
    }

    func testOrphanedByFlagOrAge() throws {
        let s = try decode(doc(project(sessions: #"[{"sessionName":"a","activity":"x","updatedAt":"2026-11-18T11:00:00Z","ageSeconds":3600,"orphaned":true},{"sessionName":"b","activity":"x","updatedAt":"2026-11-18T11:00:00Z","ageSeconds":3600},{"sessionName":"c","activity":"x","updatedAt":"2026-11-18T11:50:00Z","ageSeconds":600,"orphaned":false}]"#))).projects[0].sessions
        XCTAssertEqual(s.map { $0.isOrphaned(at: now) }, [true, true, false])
    }

    func testBuildCommitShortIsSevenChars() {
        XCTAssertEqual(OverviewBuild(taskID: UUID(), buildID: "x", createdAt: nil, commit: "0123456789abcdef").commitShort, "0123456")
        XCTAssertNil(OverviewBuild(taskID: UUID(), buildID: "x", createdAt: nil, commit: nil).commitShort)
    }

    // MARK: Build status (session-status 1.2.0)

    private func buildOf(_ extra: String) throws -> OverviewBuild {
        let s = #"{"projects":[{"projectID":"\#(p1)","projectName":"A","builds":[{"taskID":"\#(t1)","buildID":"b"\#(extra)}]}]}"#
        return try XCTUnwrap(decode(s).projects[0].builds.first)
    }

    func testBuildStatusMissingIsNil() throws {
        let b = try buildOf("")
        XCTAssertNil(b.status)
        XCTAssertNil(b.commit)
    }

    func testBuildStatusValidValues() throws {
        XCTAssertEqual(try buildOf(#","status":"building""#).status, .building)
        XCTAssertEqual(try buildOf(#","status":"succeeded""#).status, .succeeded)
        let failed = try buildOf(#","status":"failed","commit":"d955b88c0ffee""#)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.commitShort, "d955b88")
    }

    func testBuildStatusUnknownOrWrongTypeIsNilAndKeepsBuild() throws {
        XCTAssertNil(try buildOf(#","status":"queued""#).status)
        XCTAssertNil(try buildOf(#","status":7"#).status)
    }

    func testBuildInvalidCommitIsNilButStatusKept() throws {
        let b = try buildOf(#","status":"succeeded","commit":"XYZ""#)
        XCTAssertNil(b.commit)
        XCTAssertEqual(b.status, .succeeded)
    }

    func testBuildArtifactDecodesStatusAndCommitTolerantly() throws {
        let aid = UUID()
        func art(_ extra: String) throws -> BuildArtifact {
            let j = #"{"id":"\#(UUID())","attachmentID":"\#(aid)","taskID":"\#(UUID())","buildID":"b1","filename":"a.png","mediaType":"image/png","size":1,"previewURL":"/x"\#(extra)}"#
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            return try d.decode(BuildArtifact.self, from: Data(j.utf8))
        }
        XCTAssertNil(try art("").status)
        XCTAssertEqual(try art(#","status":"failed","commit":"0123456""#).status, .failed)
        XCTAssertEqual(try art(#","status":"failed","commit":"0123456""#).commit, "0123456")
        XCTAssertNil(try art(#","status":"???","commit":"nope""#).status)
        XCTAssertNil(try art(#","status":"???","commit":"nope""#).commit)
    }
}
