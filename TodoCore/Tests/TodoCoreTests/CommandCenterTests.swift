import XCTest
@testable import TodoCore

final class CommandCenterTests: XCTestCase {
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

    private func reply(_ s: String) { reply(200, s) }
    private func reply(_ status: Int, _ s: String) { MockURLProtocol.handler = { _ in (status, Data(s.utf8)) } }
    private var last: URLRequest { MockURLProtocol.seen.last! }
    private func body(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
    }
    private func query(_ r: URLRequest) -> [String: String] {
        let items = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private var questionJSON: String {
        #"{"id":"\#(qid)","taskID":"\#(tid)","taskTitle":"T","projectID":"\#(pid)","projectName":"P","askedByType":"Run","askedByID":"\#(UUID())","askedByLabel":"Claude","prompt":"Welche DB?","options":["MariaDB","SQLite"],"blocking":true,"state":"open","answer":null,"answeredBy":null,"answeredVia":null,"answeredAt":null,"createdAt":"2026-10-30T10:00:00Z","agentQuestionID":null,"version":1}"#
    }
    private var reviewJSON: String {
        #"{"id":"\#(rid)","taskID":"\#(tid)","taskTitle":"T","projectID":"\#(pid)","projectName":"P","state":"pending","requestedByType":"Integration","requestedByID":"\#(UUID())","requestedByLabel":"Claude","reviewerID":null,"summary":"Fertig","decidedBy":null,"decidedAt":null,"decisionNote":null,"agentJobID":null,"createdAt":"2026-10-30T10:00:00.123Z","version":1}"#
    }
    private var buildJSON: String {
        #"{"id":"\#(UUID())","attachmentID":"\#(aid)","taskID":"\#(tid)","buildID":"b1","label":"Login","platform":"ios","filename":"a.png","mediaType":"image/png","size":12,"previewURL":"/v1/attachments/\#(aid)/preview","createdAt":"2026-10-30T10:00:00Z"}"#
    }
    private var cardJSON: String {
        ##"{"task":{"id":"\##(tid)","title":"Login bauen","status":"in_progress","version":3,"columnID":null,"columnName":"In Arbeit","createdAt":"2026-10-29T10:00:00Z","updatedAt":"2026-10-30T10:00:00Z"},"project":{"id":"\##(pid)","name":"App","color":"#DB4C3F","parentID":null},"kind":"feature","isFeature":true,"parentTaskID":null,"lane":"question","progress":{"percent":40,"source":"subtasks","subtasksDone":2,"subtasksTotal":5,"criteriaDone":0,"criteriaTotal":0},"agent":{"claimedLabel":"Claude","claimedAt":"2026-10-30T09:00:00Z","jobID":null,"jobState":null,"jobProgress":null,"runID":null,"checkpointNextStep":"Tests"},"openQuestionCount":1,"questions":[{"id":"\##(qid)","prompt":"Welche DB?","options":["MariaDB"],"blocking":true,"askedByType":"Run","askedByLabel":"Claude","createdAt":"2026-10-30T10:00:00Z"}],"pendingReview":null,"blockedReason":null,"blockedBy":[],"latestUpdate":{"kind":"note","text":"Schema fertig","at":"2026-10-30T10:00:00Z","actorLabel":"Claude"},"builds":[\##(buildJSON)],"buildCount":1,"nextDue":null,"priority":2,"subtasks":[{"id":"\##(UUID())","title":"Sub","status":"done","lane":"done","progressPercent":100}]}"##
    }

    func testKanbanRequestShapeAndDecoding() async throws {
        reply(#"{"generatedAt":"2026-10-30T10:00:00Z","scope":"account","projectID":null,"view":"kanban","summary":{"running":1,"question":2,"review":0,"ready":3,"blocked":0,"done":4,"backlog":5,"openQuestions":2,"pendingReviews":1,"features":1,"activeAgents":1},"lanes":[{"key":"question","title":"Frage offen","count":1,"truncated":false,"cards":[\#(cardJSON)]},{"key":"future_lane","title":"Neu","count":0,"truncated":false,"cards":[]}],"updates":[{"id":"\#(UUID())","taskID":"\#(tid)","taskTitle":"Login bauen","projectID":"\#(pid)","projectName":"App","kind":"progress.posted","actorType":"Integration","actorID":"\#(UUID())","actorName":null,"subjectID":null,"text":"Schema fertig","createdAt":"2026-10-30T10:00:00.5Z"}],"builds":[{"buildID":"b1","label":null,"platform":"ios","taskIDs":["\#(tid)"],"createdAt":"2026-10-30T10:00:00Z","items":[\#(buildJSON)]}]}"#)
        let cc = try await client.commandCenter()
        XCTAssertEqual(last.url?.path, "/v1/command-center")
        XCTAssertEqual(query(last)["scope"], "account")
        XCTAssertEqual(query(last)["view"], "kanban")
        XCTAssertNil(query(last)["projectID"])
        XCTAssertEqual(last.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(cc.summary.openQuestions, 2)
        XCTAssertEqual(cc.summary.count(for: .done), 4)
        XCTAssertNil(cc.items)
        let lane = try XCTUnwrap(cc.lanes?.first)
        XCTAssertEqual(lane.lane, .question)
        XCTAssertNil(cc.lanes?.last?.lane, "unknown lanes stay readable")
        let card = try XCTUnwrap(lane.cards.first)
        XCTAssertEqual(card.id, tid)
        XCTAssertEqual(card.progress.percent, 40)
        XCTAssertEqual(card.progress.subtasksTotal, 5)
        XCTAssertEqual(card.agent?.claimedLabel, "Claude")
        XCTAssertEqual(card.questions.first?.options, ["MariaDB"])
        XCTAssertEqual(card.builds.first?.attachmentID, aid)
        XCTAssertEqual(card.latestUpdate?.text, "Schema fertig")
        XCTAssertEqual(card.subtasks.first?.progressPercent, 100)
        XCTAssertEqual(cc.updates.first?.text, "Schema fertig")
        XCTAssertEqual(cc.builds.first?.items.count, 1)
    }

    func testProjectListQueryItems() async throws {
        reply(#"{"generatedAt":"2026-10-30T10:00:00Z","scope":"project","projectID":"\#(pid)","view":"list","summary":{"running":0,"question":0,"review":0,"ready":0,"blocked":0,"done":0,"backlog":0,"openQuestions":0,"pendingReviews":0,"features":0,"activeAgents":0},"items":[],"total":0,"updates":[],"builds":[]}"#)
        var options = CommandCenterOptions(projectID: pid, view: .list)
        options.lanes = [.question, .review]
        options.hasQuestion = true
        options.sort = .updated
        options.includeSubprojects = false
        options.limit = 20
        let cc = try await client.commandCenter(options)
        let q = query(last)
        XCTAssertEqual(q["scope"], "project")
        XCTAssertEqual(q["projectID"], pid.uuidString.lowercased())
        XCTAssertEqual(q["view"], "list")
        XCTAssertEqual(q["lane"], "question,review")
        XCTAssertEqual(q["hasQuestion"], "true")
        XCTAssertEqual(q["sort"], "updated")
        XCTAssertEqual(q["includeSubprojects"], "false")
        XCTAssertEqual(q["limit"], "20")
        XCTAssertEqual(cc.total, 0)
        XCTAssertNil(cc.lanes)
    }

    func testCommandCenterNotFoundAndBadRequest() async {
        reply(404, #"{"error":true,"reason":"Not Found"}"#)
        do { _ = try await client.commandCenter(); XCTFail() } catch { XCTAssertEqual(error as? APIError, .notFound) }
        reply(400, #"{"error":true,"reason":"project_required"}"#)
        do { _ = try await client.commandCenter(); XCTFail() } catch { XCTAssertEqual(error as? APIError, .invalidInput(reason: "project_required")) }
    }

    func testQuestionsListAndAnswer() async throws {
        reply("[\(questionJSON)]")
        let list = try await client.questions(projectID: pid, state: .open, limit: 100)
        XCTAssertEqual(last.url?.path, "/v1/questions")
        XCTAssertEqual(query(last)["state"], "open")
        XCTAssertEqual(query(last)["projectID"], pid.uuidString.lowercased())
        XCTAssertEqual(list.first?.askerDisplay, "Claude")
        XCTAssertEqual(list.first?.isOpen, true)
        XCTAssertEqual(list.first?.options.count, 2)

        reply(questionJSON.replacingOccurrences(of: #""state":"open""#, with: #""state":"answered""#).replacingOccurrences(of: #""answer":null"#, with: #""answer":"MariaDB""#))
        let answered = try await client.answerQuestion(qid, answer: "MariaDB")
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.url?.path, "/v1/questions/\(qid.uuidString.lowercased())/answer")
        XCTAssertEqual(body(last)["answer"] as? String, "MariaDB")
        XCTAssertEqual(answered.state, "answered")
        XCTAssertEqual(answered.answer, "MariaDB")

        reply(409, #"{"error":true,"reason":"question_already_answered"}"#)
        do { _ = try await client.answerQuestion(qid, answer: "x"); XCTFail() } catch {
            XCTAssertEqual(error as? APIError, .conflict(reason: "question_already_answered"))
        }
        reply(400, #"{"error":true,"reason":"invalid_answer_option"}"#)
        do { _ = try await client.answerQuestion(qid, answer: "x"); XCTFail() } catch {
            XCTAssertEqual(error as? APIError, .invalidInput(reason: "invalid_answer_option"))
        }
    }

    func testReviewsAndDecision() async throws {
        reply("[\(reviewJSON)]")
        let list = try await client.reviews(state: .pending)
        XCTAssertEqual(last.url?.path, "/v1/reviews")
        XCTAssertEqual(query(last)["state"], "pending")
        XCTAssertEqual(list.first?.isPending, true)
        XCTAssertNotNil(list.first?.createdAt, "fractional-second timestamps decode")

        reply(reviewJSON.replacingOccurrences(of: #""state":"pending""#, with: #""state":"changes_requested""#))
        let r = try await client.decideReview(taskID: tid, decision: .requestChanges, note: "  Bitte Tests  ")
        XCTAssertEqual(last.url?.path, "/v1/tasks/\(tid.uuidString.lowercased())/review/decision")
        XCTAssertEqual(body(last)["decision"] as? String, "request_changes")
        XCTAssertEqual(body(last)["note"] as? String, "Bitte Tests")
        XCTAssertEqual(r.state, "changes_requested")

        reply(reviewJSON)
        _ = try await client.decideReview(taskID: tid, decision: .accept, note: "  ")
        XCTAssertEqual(body(last)["decision"] as? String, "accept")
        XCTAssertNil(body(last)["note"], "blank note is omitted")

        reply(409, #"{"error":true,"reason":"no_pending_review"}"#)
        do { _ = try await client.decideReview(taskID: tid, decision: .accept); XCTFail() } catch {
            XCTAssertEqual(error as? APIError, .conflict(reason: "no_pending_review"))
        }
    }

    func testTaskContextDecodes() async throws {
        let task = #"{"id":"\#(tid)","projectID":"\#(pid)","title":"T","description":"d","status":"in_review","version":4,"columnID":null,"boardPosition":0}"#
        reply(#"{"task":\#(task),"projectID":"\#(pid)","workflow":{"taskID":"\#(tid)","kind":"feature","isFeature":true,"parentTaskID":null,"blockedReason":null,"claimedByType":null,"claimedByID":null,"claimedLabel":null,"claimedAt":null},"progress":{"percent":10,"source":"agent","subtasksDone":0,"subtasksTotal":0,"criteriaDone":0,"criteriaTotal":0},"progressNotes":[{"id":"\#(UUID())","taskID":"\#(tid)","actorType":"Integration","actorID":"\#(UUID())","actorLabel":"Claude","note":"Start","percent":10,"createdAt":"2026-10-30T10:00:00Z"}],"criteria":[{"id":"\#(UUID())","taskID":"\#(tid)","text":"Tests gruen","completed":false,"version":1}],"subtasks":[\#(task)],"comments":[{"id":"\#(UUID())","taskID":"\#(tid)","authorID":"\#(UUID())","authorName":"Alice","body":"Hi","version":1}],"questions":[\#(questionJSON)],"review":\#(reviewJSON),"builds":[\#(buildJSON)]}"#)
        let ctx = try await client.taskContext(tid)
        XCTAssertEqual(last.url?.path, "/v1/tasks/\(tid.uuidString.lowercased())/context")
        XCTAssertEqual(ctx.task.status, "in_review")
        XCTAssertTrue(ctx.workflow.isFeature)
        XCTAssertEqual(ctx.progressNotes.first?.percent, 10)
        XCTAssertEqual(ctx.criteria.first?.completed, false)
        XCTAssertEqual(ctx.comments.first?.authorName, "Alice")
        XCTAssertEqual(ctx.review?.summary, "Fertig")
        XCTAssertEqual(ctx.builds.count, 1)
        XCTAssertEqual(ctx.questions.first?.prompt, "Welche DB?")
    }

    func testAgentBriefReadWriteAndConflict() async throws {
        reply(##"{"projectID":"\##(pid)","text":"# Goals","version":0,"updatedAt":null}"##)
        let b = try await client.agentBrief(projectID: pid)
        XCTAssertEqual(last.url?.path, "/v1/projects/\(pid.uuidString.lowercased())/agent-brief")
        XCTAssertEqual(b.version, 0)
        reply(##"{"projectID":"\##(pid)","text":"# Goals\nShip","version":1,"updatedAt":"2026-10-30T10:00:00Z"}"##)
        let saved = try await client.saveAgentBrief(projectID: pid, text: "# Goals\nShip", version: 0)
        XCTAssertEqual(last.httpMethod, "PUT")
        XCTAssertEqual(body(last)["version"] as? Int, 0)
        XCTAssertEqual(body(last)["text"] as? String, "# Goals\nShip")
        XCTAssertEqual(saved.version, 1)
        reply(409, #"{"error":true,"reason":"version_conflict"}"#)
        do { _ = try await client.saveAgentBrief(projectID: pid, text: "x", version: 0); XCTFail() } catch {
            XCTAssertEqual(error as? APIError, .versionConflict)
        }
        reply(403, #"{"error":true,"reason":"Forbidden"}"#)
        do { _ = try await client.saveAgentBrief(projectID: pid, text: "x", version: 1); XCTFail() } catch {
            XCTAssertEqual(error as? APIError, .forbidden(reason: "Forbidden"))
        }
    }

    func testAgentWorkflowTemplate() async throws {
        reply(201, "[]")
        _ = try await client.applyAgentWorkflowColumns(projectID: pid)
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.url?.path, "/v1/projects/\(pid.uuidString.lowercased())/columns/template")
        XCTAssertEqual(body(last)["source"] as? String, "agent_workflow")
    }

    func testResolvedURL() {
        XCTAssertEqual(client.resolvedURL(path: "/v1/attachments/x/preview")?.absoluteString, "http://test.invalid/v1/attachments/x/preview")
    }
}
