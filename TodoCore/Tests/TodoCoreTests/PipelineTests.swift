import XCTest
@testable import TodoCore

/// Plan approval and pipeline status per card (card B6FC965A, contract pipeline 1.0.0 in the main repository):
/// tolerant decoding, step helpers, decision request and errors, and the names of the new activity kinds.
final class PipelineTests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let tid = UUID()

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
    private func body(_ r: URLRequest) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:] }
    private func decode(_ json: String) throws -> TaskPipeline { try APIClient.decoder.decode(TaskPipeline.self, from: Data(json.utf8)) }

    private let planJSON = ##"{"version":2,"body":"# Plan\n- Schritt 1\n- Schritt 2","state":"proposed","authorType":"integration","authorLabel":"Claude","writtenAt":"2026-11-25T09:00:00Z"}"##

    private func stepsJSON(overrides: [String: String] = [:]) -> String {
        let names = ["planner", "approval", "developer", "validation", "tester", "review"]
        let items = names.map { name in overrides[name] ?? #"{"step":"\#(name)","state":"pending"}"# }
        return "[" + items.joined(separator: ",") + "]"
    }

    private func pipelineJSON(plan: String? = nil, steps: String? = nil, events: String = "[]") -> String {
        let planPart = plan.map { #""plan":\#($0),"# } ?? ""
        return #"{"taskID":"\#(tid.uuidString.lowercased())",\#(planPart)"steps":\#(steps ?? stepsJSON()),"events":\#(events)}"#
    }

    // MARK: Decoding

    func testPipelineWithoutPlanHasSixPendingSteps() throws {
        let p = try decode(pipelineJSON())
        XCTAssertEqual(p.taskID, tid)
        XCTAssertNil(p.plan)
        XCTAssertEqual(p.steps.map(\.step), ["planner", "approval", "developer", "validation", "tester", "review"])
        XCTAssertTrue(p.steps.allSatisfy { $0.state == "pending" && $0.note == nil && $0.actorLabel == nil && $0.updatedAt == nil })
        XCTAssertTrue(p.events.isEmpty)
        XCTAssertFalse(p.isWaitingForDecision)
    }

    func testProposedPlanDecodesAndWaitsForDecision() throws {
        let approval = #"{"step":"approval","state":"waiting","actorLabel":"Claude","updatedAt":"2026-11-25T09:00:01Z"}"#
        let p = try decode(pipelineJSON(plan: planJSON, steps: stepsJSON(overrides: ["approval": approval])))
        let plan = try XCTUnwrap(p.plan)
        XCTAssertEqual(plan.version, 2)
        XCTAssertEqual(plan.body, "# Plan\n- Schritt 1\n- Schritt 2")
        XCTAssertEqual(plan.state, "proposed")
        XCTAssertEqual(plan.authorType, "integration")
        XCTAssertEqual(plan.authorLabel, "Claude")
        XCTAssertNotNil(plan.writtenAt)
        XCTAssertNil(plan.decidedAt); XCTAssertNil(plan.decidedByLabel); XCTAssertNil(plan.decisionComment)
        XCTAssertTrue(plan.isProposed)
        XCTAssertTrue(p.isWaitingForDecision)
        XCTAssertEqual(p.stepStatus(.approval)?.state, "waiting")
        XCTAssertEqual(p.stepStatus(.approval)?.actorLabel, "Claude")
    }

    func testDecidedPlanCarriesDecisionFields() throws {
        let plan = #"{"version":3,"body":"x","state":"changes_requested","authorType":"person","writtenAt":"2026-11-25T09:00:00.250Z","decidedAt":"2026-11-25T09:05:00Z","decidedByLabel":"Lino","decisionComment":"Bitte Tests zuerst"}"#
        let p = try decode(pipelineJSON(plan: plan))
        XCTAssertEqual(p.plan?.state, "changes_requested")
        XCTAssertEqual(p.plan?.decidedByLabel, "Lino")
        XCTAssertEqual(p.plan?.decisionComment, "Bitte Tests zuerst")
        XCTAssertNotNil(p.plan?.decidedAt)
        XCTAssertFalse(p.plan?.isProposed ?? true)
        XCTAssertFalse(p.isWaitingForDecision)
    }

    func testStepStatesAndNotesDecode() throws {
        let dev = #"{"step":"developer","state":"running","note":"Baut den Test","actorLabel":"claude-code@apple","updatedAt":"2026-11-25T10:00:00Z"}"#
        let val = #"{"step":"validation","state":"failed","note":"1 Test rot"}"#
        let p = try decode(pipelineJSON(plan: planJSON, steps: stepsJSON(overrides: ["developer": dev, "validation": val])))
        XCTAssertEqual(p.stepStatus(.developer)?.state, "running")
        XCTAssertEqual(p.stepStatus(.developer)?.note, "Baut den Test")
        XCTAssertEqual(p.stepStatus(.validation)?.state, "failed")
        XCTAssertEqual(p.stepStatus(.tester)?.state, "pending")
        XCTAssertEqual(PipelineStepStatus.State(raw: "running"), .running)
        XCTAssertEqual(PipelineStepStatus.State(raw: "waiting"), .waiting)
        XCTAssertEqual(PipelineStepStatus.State(raw: "changes_requested"), .changesRequested)
        XCTAssertEqual(PipelineStepStatus.State(raw: "neu-vom-server"), .unknown, "a state from a newer server stays displayable")
        XCTAssertEqual(p.steps[0].stateKind, .pending)
    }

    func testUnknownStepAndStateStayAndBrokenElementsDrop() throws {
        let steps = #"[{"step":"planner","state":"done"},{"step":"deploy","state":"running"},{"step":"approval"},"quatsch",{"state":"done"}]"#
        let events = #"[{"id":"\#(UUID().uuidString.lowercased())","action":"plan_written","planVersion":1,"actorType":"integration","createdAt":"2026-11-25T09:00:00Z"},{"action":"plan_written","actorType":"person","createdAt":"2026-11-25T09:00:00Z"},{"id":"\#(UUID().uuidString.lowercased())","action":"neue_art","actorType":"run","createdAt":"2026-11-25T09:01:00Z"}]"#
        let p = try decode(pipelineJSON(steps: steps, events: events))
        XCTAssertEqual(p.steps.map(\.step), ["planner", "deploy"], "unknown step kept, entries without step or state dropped")
        XCTAssertNil(p.stepStatus(.approval), "a missing step is not invented")
        XCTAssertEqual(p.events.count, 2, "event without id dropped")
        XCTAssertEqual(p.events[1].action, "neue_art")
        XCTAssertEqual(p.events[1].kind, .unknown)
    }

    func testEventsDecodeInOrderWithKindsAndLabels() throws {
        let a = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased(), c = UUID().uuidString.lowercased(), d = UUID().uuidString.lowercased()
        let events = """
        [{"id":"\(a)","action":"step_changed","step":"developer","state":"running","note":"los","actorType":"run","actorLabel":"Runner","createdAt":"2026-11-25T10:00:00Z"},
         {"id":"\(b)","action":"plan_approved","planVersion":2,"note":"ok","actorType":"person","actorLabel":"Lino","createdAt":"2026-11-25T09:30:00Z"},
         {"id":"\(c)","action":"plan_changes_requested","planVersion":1,"note":"mehr Tests","actorType":"person","createdAt":"2026-11-25T09:10:00Z"},
         {"id":"\(d)","action":"plan_written","planVersion":1,"actorType":"integration","actorLabel":"Claude","createdAt":"2026-11-25T09:00:00Z"}]
        """
        let p = try decode(pipelineJSON(events: events))
        XCTAssertEqual(p.events.map(\.kind), [.stepChanged, .planApproved, .planChangesRequested, .planWritten])
        XCTAssertEqual(p.events[0].step, "developer"); XCTAssertEqual(p.events[0].state, "running"); XCTAssertNil(p.events[0].planVersion)
        XCTAssertEqual(p.events[1].planVersion, 2); XCTAssertEqual(p.events[1].note, "ok")
        XCTAssertEqual(p.events[3].actorLabel, "Claude")
        XCTAssertNil(p.events[2].actorLabel)
    }

    func testBrokenPlanDoesNotBreakTheRest() throws {
        let p = try decode(pipelineJSON(plan: #"{"version":0,"body":"","state":"proposed"}"#))
        XCTAssertNil(p.plan, "a plan without body or valid version is treated as no plan")
        XCTAssertEqual(p.steps.count, 6)
        let unknownState = try decode(pipelineJSON(plan: #"{"version":1,"body":"x","state":"archived","authorType":"person","writtenAt":"2026-11-25T09:00:00Z"}"#))
        XCTAssertEqual(unknownState.plan?.state, "archived", "unknown plan state stays")
        XCTAssertFalse(unknownState.isWaitingForDecision)
    }

    // MARK: Requests

    func testFetchPipelineRequest() async throws {
        reply(pipelineJSON(plan: planJSON))
        let p = try await client.taskPipeline(taskID: tid)
        XCTAssertEqual(last.httpMethod, "GET")
        XCTAssertEqual(last.url?.path, "/v1/tasks/\(tid.uuidString.lowercased())/pipeline")
        XCTAssertEqual(p.plan?.version, 2)
    }

    func testOlderServerWithoutPipelineGivesNil() async throws {
        reply(404, #"{"error":true,"reason":"not_found"}"#)
        let p = try await client.taskPipelineIfAvailable(taskID: tid)
        XCTAssertNil(p, "404 = server without pipeline (or card gone): the section stays away, no error")
        reply(401, #"{"error":true}"#)
        do { _ = try await client.taskPipelineIfAvailable(taskID: tid); XCTFail("401 must surface") } catch {
            XCTAssertEqual(error as? APIError, .unauthorized(reason: nil))
        }
    }

    func testApproveSendsVersionAndOmitsEmptyComment() async throws {
        reply(pipelineJSON(plan: planJSON.replacingOccurrences(of: "proposed", with: "approved")))
        let p = try await client.decidePlan(taskID: tid, decision: .approve, version: 2, comment: "   ")
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.url?.path, "/v1/tasks/\(tid.uuidString.lowercased())/plan/decision")
        XCTAssertEqual(body(last)["decision"] as? String, "approve")
        XCTAssertEqual(body(last)["version"] as? Int, 2)
        XCTAssertNil(body(last)["comment"])
        XCTAssertEqual(p.plan?.state, "approved")
    }

    func testRequestChangesNeedsCommentBeforeAnyRequest() async {
        do { _ = try await client.decidePlan(taskID: tid, decision: .requestChanges, version: 2, comment: "  \n"); XCTFail("comment required") } catch {
            XCTAssertEqual(error as? PlanDecisionError, .commentRequired)
        }
        XCTAssertTrue(MockURLProtocol.seen.isEmpty, "no request without the required comment")
    }

    func testRequestChangesSendsTrimmedComment() async throws {
        reply(pipelineJSON(plan: planJSON.replacingOccurrences(of: "proposed", with: "changes_requested")))
        _ = try await client.decidePlan(taskID: tid, decision: .requestChanges, version: 2, comment: "  Bitte Tests zuerst \n")
        XCTAssertEqual(body(last)["decision"] as? String, "request_changes")
        XCTAssertEqual(body(last)["comment"] as? String, "Bitte Tests zuerst")
    }

    func testDecisionErrorsAreMapped() async {
        let cases: [(Int, String, PlanDecisionError)] = [
            (409, "plan_changed", .planChanged), (409, "plan_not_pending", .planNotPending), (409, "no_plan", .noPlan),
            (403, "cannot_decide_own_plan", .ownPlan), (403, "brain_mandate_required", .notAllowed), (403, "outside_brain_mandate", .notAllowed),
            (400, "comment_required", .commentRequired), (400, "invalid_comment", .invalidComment), (400, "invalid_version", .planChanged),
        ]
        for (status, code, expected) in cases {
            reply(status, #"{"error":true,"reason":"\#(code)"}"#)
            do { _ = try await client.decidePlan(taskID: tid, decision: .approve, version: 1); XCTFail("\(status) expected") } catch {
                XCTAssertEqual(PlanDecisionError(error), expected, code)
            }
        }
        XCTAssertNil(PlanDecisionError(APIError.transport("x")))
        XCTAssertNil(PlanDecisionError(APIError.conflict(reason: "version_conflict")))
        XCTAssertNil(PlanDecisionError(APIError.forbidden(reason: nil)), "a plain 403 stays the general permission error")
    }

    // MARK: Activity kinds

    func testNewActivityKindsHaveNames() {
        XCTAssertEqual(PipelineActivity.kind(of: "plan.written"), .planWritten)
        XCTAssertEqual(PipelineActivity.kind(of: "plan.approved"), .planApproved)
        XCTAssertEqual(PipelineActivity.kind(of: "plan.changes_requested"), .planChangesRequested)
        XCTAssertEqual(PipelineActivity.kind(of: "pipeline.step"), .stepChanged)
        XCTAssertEqual(PipelineActivity.localizationKey(for: "plan.written"), "activity.plan_written")
        XCTAssertEqual(PipelineActivity.localizationKey(for: "plan.approved"), "activity.plan_approved")
        XCTAssertEqual(PipelineActivity.localizationKey(for: "plan.changes_requested"), "activity.plan_changes_requested")
        XCTAssertEqual(PipelineActivity.localizationKey(for: "pipeline.step"), "activity.pipeline_step")
    }

    func testOtherKindsAreNotClaimed() {
        for kind in ["task.created", "progress.posted", "plan", "plan.deleted", "pipeline", "", "PLAN.WRITTEN"] {
            XCTAssertNil(PipelineActivity.kind(of: kind), kind)
            XCTAssertNil(PipelineActivity.localizationKey(for: kind), kind)
        }
        XCTAssertTrue(PipelineActivity.isPipelineKind("plan.approved"))
        XCTAssertFalse(PipelineActivity.isPipelineKind("task.created"))
    }

    func testEventActionMapsToTheSameKinds() {
        XCTAssertEqual(PipelineEvent.Kind(action: "plan_written"), .planWritten)
        XCTAssertEqual(PipelineEvent.Kind(action: "plan_approved"), .planApproved)
        XCTAssertEqual(PipelineEvent.Kind(action: "plan_changes_requested"), .planChangesRequested)
        XCTAssertEqual(PipelineEvent.Kind(action: "step_changed"), .stepChanged)
        XCTAssertEqual(PipelineEvent.Kind(action: "x"), .unknown)
    }

    func testStepNamesAreOrderedAndTheLiveHintsExist() {
        XCTAssertEqual(PipelineStepName.allCases.map(\.rawValue), ["planner", "approval", "developer", "validation", "tester", "review"])
    }
}
