import XCTest
@testable import TodoCore

/// Pipeline stage 3 in the app (card BEE2417E; contract pipeline 1.2.0 in the main repository, PWA `web/src/lib/pipelineExecution.ts`
/// as the model): decoding of `execution` and `fixRounds`, the rules of the section "Ausführung" (start offered, step that runs,
/// budget hold, retry offer and hint), the requests for start, continue, stop and retry, and the mapped refusals.
final class PipelineExecutionTests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let tid = UUID()
    let binding = UUID()

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
    private var path: String { "/v1/tasks/\(tid.uuidString.lowercased())/pipeline" }

    private func steps(_ states: [String: String] = [:], off: Set<String> = []) -> String {
        let items = PipelineStepName.allCases.map { s -> String in
            let enabled = off.contains(s.rawValue) ? #","enabled":false"# : #","enabled":true"#
            return #"{"step":"\#(s.rawValue)","state":"\#(states[s.rawValue] ?? "pending")"\#(enabled)}"#
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    private func execution(_ state: String, step: String? = "developer", reason: String? = nil, jobState: String? = nil, progress: String? = nil,
                           supports: Bool = true) -> String {
        var parts = [#""id":"\#(UUID().uuidString.lowercased())""#, #""state":"\#(state)""#, #""bindingID":"\#(binding.uuidString.lowercased())""#,
                     #""bindingLabel":"todo-apple""#, #""deviceLabel":"Linos Mac""#, #""runnerSupportsPipeline":\#(supports)"#,
                     #""createdAt":"2026-11-27T09:00:00Z""#, #""updatedAt":"2026-11-27T09:05:00Z""#]
        if let step { parts.append(#""step":"\#(step)""#) }
        if let reason { parts.append(#""reason":"\#(reason)""#) }
        if let jobState { parts.append(#""jobID":"\#(UUID().uuidString.lowercased())","jobState":"\#(jobState)""#) }
        if let progress { parts.append(#""jobProgress":"\#(progress)""#) }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private func pipeline(steps: String? = nil, execution: String? = nil, fixRounds: String? = #"{"used":0,"max":3,"remaining":3}"#,
                          plan: Bool = true) -> String {
        var parts = [#""taskID":"\#(tid.uuidString.lowercased())""#, #""steps":\#(steps ?? self.steps())"#, #""events":[]"#]
        if plan { parts.append(##""plan":{"version":2,"body":"# Plan","state":"approved","authorType":"run","writtenAt":"2026-11-27T08:00:00Z"}"##) }
        if let execution { parts.append(#""execution":\#(execution)"#) }
        if let fixRounds { parts.append(#""fixRounds":\#(fixRounds)"#) }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private var bindings: [PipelineStartBinding] { [PipelineStartBinding(id: binding, label: "todo-apple", deviceLabel: "Linos Mac")] }

    // MARK: Decoding

    func testExecutionDecodesWithAllFields() throws {
        let p = try decode(pipeline(execution: execution("running", jobState: "running", progress: "Schreibe Tests")))
        let e = try XCTUnwrap(p.execution)
        XCTAssertEqual(e.state, "running")
        XCTAssertEqual(e.stateKind, .running)
        XCTAssertEqual(e.step, "developer")
        XCTAssertEqual(e.bindingID, binding)
        XCTAssertEqual(e.deviceLine, "Linos Mac · todo-apple")
        XCTAssertEqual(e.runnerSupportsPipeline, true)
        XCTAssertEqual(e.jobState, "running")
        XCTAssertEqual(e.jobProgress, "Schreibe Tests")
        XCTAssertNotNil(e.jobID)
        XCTAssertNotNil(e.updatedAt)
        XCTAssertTrue(e.isActive)
        XCTAssertEqual(p.fixRounds, PipelineFixRounds(used: 0, max: 3, remaining: 3))
        XCTAssertEqual(p.steps.map(\.isOn), [true, true, true, true, true, true])
    }

    func testOlderServerAndBrokenExecutionStayReadable() throws {
        let old = try decode(#"{"taskID":"\#(tid.uuidString.lowercased())","steps":[{"step":"planner","state":"done"}],"events":[]}"#)
        XCTAssertNil(old.execution)
        XCTAssertNil(old.fixRounds)
        XCTAssertTrue(old.steps[0].isOn, "a step without `enabled` (stage 1) is on")
        let broken = try decode(pipeline(execution: #"{"state":"running"}"#))
        XCTAssertNil(broken.execution, "an execution without id is dropped, the rest stays")
        XCTAssertEqual(broken.steps.count, 6)
        let future = try decode(pipeline(execution: execution("archived", reason: "new_reason")))
        XCTAssertEqual(future.execution?.stateKind, .unknown)
        XCTAssertEqual(future.execution?.state, "archived", "unknown state stays as sent")
    }

    func testStateKindsAndActivity() throws {
        let kinds: [(String, PipelineExecution.State, Bool)] = [
            ("running", .running, true), ("waiting_approval", .waitingApproval, true), ("blocked", .blocked, true),
            ("paused", .paused, true), ("completed", .completed, false), ("stopped", .stopped, false),
        ]
        for (raw, kind, active) in kinds {
            let e = try XCTUnwrap(try decode(pipeline(execution: execution(raw))).execution)
            XCTAssertEqual(e.stateKind, kind, raw)
            XCTAssertEqual(e.isActive, active, raw)
        }
    }

    func testDeviceLineSkipsEmptyParts() throws {
        let removed = #"{"id":"\#(UUID().uuidString.lowercased())","state":"stopped","bindingID":"\#(binding.uuidString.lowercased())","bindingLabel":"","deviceLabel":"Linos Mac","runnerSupportsPipeline":true,"createdAt":"2026-11-27T09:00:00Z","updatedAt":"2026-11-27T09:00:00Z"}"#
        XCTAssertEqual(try decode(pipeline(execution: removed)).execution?.deviceLine, "Linos Mac", "binding removed: only the device")
    }

    func testNewEventActionsAndActivityKind() {
        XCTAssertEqual(PipelineEvent.Kind(action: "step_retried"), .stepRetried)
        XCTAssertEqual(PipelineEvent.Kind(action: "execution_started"), .executionStarted)
        XCTAssertEqual(PipelineEvent.Kind(action: "execution_continued"), .executionContinued)
        XCTAssertEqual(PipelineEvent.Kind(action: "execution_stopped"), .executionStopped)
        XCTAssertEqual(PipelineEvent.Kind(action: "execution_completed"), .executionCompleted)
        XCTAssertEqual(PipelineActivity.localizationKey(for: "pipeline.execution"), "activity.pipeline_execution")
        XCTAssertTrue(PipelineActivity.isPipelineKind("pipeline.execution"))
    }

    // MARK: Live step and budget hold

    func testLiveStepFollowsTheJob() throws {
        let cases: [(String?, String?, PipelineLiveStep.Kind, PipelineLiveStep.Tone, String?)] = [
            ("queued", nil, .queued, .waiting, nil),
            ("claimed", nil, .claimed, .running, nil),
            ("running", "Baut", .running, .running, "Baut"),
            ("waiting_for_answer", nil, .answer, .warning, nil),
            ("queued", "Kontingent-Bremse: Ampel rot", .held, .warning, nil),
        ]
        for (job, progress, kind, tone, shown) in cases {
            let p = try decode(pipeline(execution: execution("running", step: "tester", jobState: job, progress: progress)))
            let live = try XCTUnwrap(p.liveStep, "\(job ?? "-")")
            XCTAssertEqual(live.step, "tester")
            XCTAssertEqual(live.kind, kind, "\(job ?? "-")")
            XCTAssertEqual(live.tone, tone, "\(job ?? "-")")
            XCTAssertEqual(live.progress, shown, "the hold text is not repeated at the step")
        }
        let held = try XCTUnwrap(try decode(pipeline(execution: execution("running", jobState: "queued", progress: "Kontingent-Bremse: rot"))).execution)
        XCTAssertTrue(held.isBudgetHold)
        let runningWithText = try XCTUnwrap(try decode(pipeline(execution: execution("running", jobState: "running", progress: "Kontingent-Bremse: rot"))).execution)
        XCTAssertFalse(runningWithText.isBudgetHold, "only a queued job is held")
    }

    func testNoLiveStepOutsideRunning() throws {
        for state in ["waiting_approval", "blocked", "paused", "completed", "stopped"] {
            XCTAssertNil(try decode(pipeline(execution: execution(state, jobState: "queued"))).liveStep, state)
        }
        XCTAssertNil(try decode(pipeline()).liveStep)
        XCTAssertNil(try decode(pipeline(execution: execution("running", step: nil))).liveStep, "running without a step")
    }

    // MARK: Section, start, nothing to run

    func testSectionWithoutExecution() throws {
        let p = try decode(pipeline())
        XCTAssertEqual(p.executionSection(bindings: bindings, mayStart: true), .init(show: true, start: true))
        XCTAssertEqual(p.executionSection(bindings: [], mayStart: true), .init(show: false, start: false), "no binding: the card looks like before")
        XCTAssertEqual(p.executionSection(bindings: bindings, mayStart: false), .init(show: false, start: false), "no start right")
    }

    func testSectionWithExecution() throws {
        let running = try decode(pipeline(execution: execution("running")))
        XCTAssertEqual(running.executionSection(bindings: bindings, mayStart: true), .init(show: true, start: false), "no second start while active")
        XCTAssertEqual(running.executionSection(bindings: [], mayStart: false), .init(show: true, start: false), "everyone sees the state")
        let stopped = try decode(pipeline(execution: execution("stopped")))
        XCTAssertEqual(stopped.executionSection(bindings: bindings, mayStart: true), .init(show: true, start: true), "a finished execution can be started again")
    }

    func testNothingToRunWhenEveryWorkStepIsFinished() throws {
        let done = try decode(pipeline(steps: steps(["planner": "done", "approval": "done", "developer": "done", "validation": "done", "tester": "skipped", "review": "done"])))
        XCTAssertTrue(done.nothingToRun)
        XCTAssertEqual(done.executionSection(bindings: bindings, mayStart: true), .init(show: true, start: false))
        let off = try decode(pipeline(steps: steps(["developer": "done", "validation": "done", "review": "done"], off: ["tester"])))
        XCTAssertTrue(off.nothingToRun, "a step that is off does not count")
        let open = try decode(pipeline(steps: steps(["developer": "done"])))
        XCTAssertFalse(open.nothingToRun)
    }

    func testStartBindingsOfTheProject() {
        let project = UUID(), other = UUID()
        func b(_ p: UUID, _ label: String) -> RunnerBinding { RunnerBinding(id: UUID(), projectID: p, deviceID: UUID(), repositoryKey: UUID().uuidString, label: label) }
        let devices = [
            RunnerDevice(id: UUID(), label: "Mac A", paired: true, revokedAt: nil, activeRunCount: 0, bindings: [b(project, "repo-a"), b(other, "x")]),
            RunnerDevice(id: UUID(), label: "Mac alt", paired: true, revokedAt: Date(), activeRunCount: 0, bindings: [b(project, "revoked")]),
            RunnerDevice(id: UUID(), label: "Mac neu", paired: false, revokedAt: nil, activeRunCount: 0, bindings: [b(project, "unpaired")]),
        ]
        let found = PipelineStartBinding.forProject(project, devices: devices)
        XCTAssertEqual(found.map(\.label), ["repo-a"])
        XCTAssertEqual(found.first?.deviceLabel, "Mac A")
        XCTAssertEqual(found.first?.id, devices[0].bindings[0].id)
    }

    // MARK: Retry

    func testRetryOfferAtAFailedStep() throws {
        let failed = try decode(pipeline(steps: steps(["developer": "done", "validation": "failed"]), fixRounds: #"{"used":1,"max":3,"remaining":2}"#))
        XCTAssertEqual(failed.retryOffer(.validation, canEdit: true), .ready(round: 2, max: 3))
        XCTAssertEqual(failed.retryOffer(.validation, canEdit: false), .hidden, "only with the edit right")
        XCTAssertEqual(failed.retryOffer(.developer, canEdit: true), .hidden, "only failed steps")
        let used = try decode(pipeline(steps: steps(["tester": "failed"]), fixRounds: #"{"used":3,"max":3,"remaining":0}"#))
        XCTAssertEqual(used.retryOffer(.tester, canEdit: true), .exhausted(max: 3))
        let old = try decode(pipeline(steps: steps(["tester": "failed"]), fixRounds: nil))
        XCTAssertEqual(old.retryOffer(.tester, canEdit: true), .hidden, "a server without fix rounds has no retry")
        let off = try decode(pipeline(steps: steps(["tester": "failed"], off: ["tester"])))
        XCTAssertEqual(off.retryOffer(.tester, canEdit: true), .hidden, "a step that is off")
        let approval = try decode(pipeline(steps: steps(["approval": "failed"])))
        XCTAssertEqual(approval.retryOffer(.approval, canEdit: true), .hidden, "approval is managed by the server")
    }

    func testRetryHintWhileAnExecutionIsActive() throws {
        let blocked = try decode(pipeline(steps: steps(["tester": "failed"]), execution: execution("blocked", step: "tester", reason: "step_failed")))
        XCTAssertEqual(blocked.retryHint(mayStart: true), .runs)
        XCTAssertEqual(blocked.retryHint(mayStart: false), .needsOwner)
        let stopped = try decode(pipeline(steps: steps(["tester": "failed"]), execution: execution("stopped")))
        XCTAssertNil(stopped.retryHint(mayStart: true))
    }

    // MARK: Requests

    func testStartSendsIdAndBinding() async throws {
        reply(pipeline(execution: execution("running", step: "planner", jobState: "queued", supports: false)))
        let id = UUID()
        let p = try await client.startPipelineExecution(taskID: tid, executionID: id, bindingID: binding)
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.url?.path, path + "/execution")
        XCTAssertEqual(body(last)["id"] as? String, id.uuidString.lowercased())
        XCTAssertEqual(body(last)["bindingID"] as? String, binding.uuidString.lowercased())
        XCTAssertEqual(p.execution?.runnerSupportsPipeline, false)
    }

    func testContinueSendsTheShownPlanVersion() async throws {
        reply(pipeline(execution: execution("running")))
        _ = try await client.continuePipelineExecution(taskID: tid, planVersion: 2)
        XCTAssertEqual(last.url?.path, path + "/execution/continue")
        XCTAssertEqual(body(last)["planVersion"] as? Int, 2)
        _ = try await client.continuePipelineExecution(taskID: tid, planVersion: nil)
        XCTAssertNil(body(last)["planVersion"], "without a plan only the card content is accepted")
    }

    func testStopAndRetryRequests() async throws {
        reply(pipeline(execution: execution("stopped")))
        let stopped = try await client.stopPipelineExecution(taskID: tid)
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.url?.path, path + "/execution/stop")
        XCTAssertEqual(stopped.execution?.stateKind, .stopped)
        reply(pipeline(steps: steps(["tester": "pending"])))
        _ = try await client.retryPipelineStep(taskID: tid, step: .tester, planVersion: 2)
        XCTAssertEqual(last.url?.path, path + "/steps/tester/retry")
        XCTAssertEqual(body(last)["planVersion"] as? Int, 2)
    }

    func testRefusalsAreMapped() async {
        let cases: [(Int, String, PipelineExecutionError)] = [
            (409, "execution_id_conflict", .idConflict), (409, "execution_active", .active), (409, "nothing_to_run", .nothingToRun),
            (409, "no_execution", .noExecution), (409, "plan_changed", .planChanged), (409, "step_not_failed", .stepNotFailed),
            (409, "fix_rounds_exhausted", .fixRoundsExhausted), (409, "step_disabled", .stepDisabled), (409, "plan_not_approved", .planNotApproved),
            (403, "", .forbidden), (404, "not_found", .notFound),
        ]
        for (status, code, expected) in cases {
            reply(status, #"{"error":true,"reason":"\#(code)"}"#)
            do { _ = try await client.stopPipelineExecution(taskID: tid); XCTFail("\(status) expected") } catch {
                XCTAssertEqual(PipelineExecutionError(error), expected, code)
            }
        }
        XCTAssertEqual(PipelineExecutionError(APIError.transport("offline")), .network)
        XCTAssertNil(PipelineExecutionError(APIError.unauthorized(reason: nil)), "401 stays the general sign-in error")
        XCTAssertTrue(PipelineExecutionError.active.showsOutdatedState)
        XCTAssertTrue(PipelineExecutionError.planChanged.showsOutdatedState)
        XCTAssertFalse(PipelineExecutionError.network.showsOutdatedState)
    }

    /// A start whose answer got lost is sent again with the same id (the server then returns the same execution, never a second).
    func testLostStartKeepsItsId() {
        var start = PipelineStartAttempt()
        let first = start.id(taskID: tid, bindingID: binding)
        start.finished(with: APIError.transport("timeout"))
        XCTAssertEqual(start.id(taskID: tid, bindingID: binding), first, "no answer: same id again")
        start.finished(with: APIError.server(status: 502, reason: nil))
        XCTAssertEqual(start.id(taskID: tid, bindingID: binding), first, "5xx: the start may have happened")
        XCTAssertNotEqual(start.id(taskID: tid, bindingID: UUID()), first, "another binding is another start")
        let again = start.id(taskID: tid, bindingID: binding)
        start.finished(with: APIError.conflict(reason: "execution_active"))
        XCTAssertNotEqual(start.id(taskID: tid, bindingID: binding), again, "a refusal ends the attempt")
        let ok = start.id(taskID: tid, bindingID: binding)
        start.finished(with: nil)
        XCTAssertNotEqual(start.id(taskID: tid, bindingID: binding), ok, "an answer ends the attempt")
    }

    /// Starting and continuing accept the plan: a version that replaced the shown one while the card was open needs a second tap.
    func testNewPlanVersionNeedsASecondTap() {
        var guardian = PlanReadGuard()
        guardian.shown(planVersion: 1)
        XCTAssertFalse(guardian.needsConfirmation(for: .start), "the version that was there when the card opened")
        guardian.shown(planVersion: 2)
        XCTAssertTrue(guardian.needsConfirmation(for: .start), "first tap after a new version: read first")
        XCTAssertEqual(guardian.confirming, .start)
        XCTAssertFalse(guardian.needsConfirmation(for: .start), "second tap confirms")
        guardian.sent()
        guardian.shown(planVersion: 3)
        XCTAssertTrue(guardian.needsConfirmation(for: .continue))
        XCTAssertTrue(guardian.needsConfirmation(for: .start), "the confirmation belongs to one action")
        guardian.shown(planVersion: 4)
        XCTAssertNil(guardian.confirming, "a newer version drops the confirmation")
        var fresh = PlanReadGuard()
        fresh.shown(planVersion: nil)
        fresh.shown(planVersion: 1)
        XCTAssertTrue(fresh.needsConfirmation(for: .start), "a plan that appeared while the card was open")
    }

    /// Start right = owner, retry = edit right, both from `GET /v1/projects` (like the PWA: older servers count as own, full access).
    func testProjectRights() async throws {
        let own = UUID(), editor = UUID(), reader = UUID(), commenter = UUID(), old = UUID()
        func item(_ id: UUID, _ extra: String) -> String { #"{"id":"\#(id.uuidString.lowercased())","name":"P","version":1\#(extra)}"# }
        reply("[" + [item(own, #","isOwner":true,"role":"manage""#), item(editor, #","isOwner":false,"role":"edit""#),
                     item(reader, #","isOwner":false,"role":"read""#), item(commenter, #","isOwner":false,"role":"comment""#), item(old, "")].joined(separator: ",") + "]")
        var rights: [UUID: PipelineRights] = [:]
        for id in [own, editor, reader, commenter, old, UUID()] { rights[id] = try await client.pipelineRights(projectID: id) }
        XCTAssertEqual(last.url?.path, "/v1/projects")
        XCTAssertEqual(rights[own], PipelineRights(mayStart: true, canEdit: true))
        XCTAssertEqual(rights[editor], PipelineRights(mayStart: false, canEdit: true))
        XCTAssertEqual(rights[reader], PipelineRights(mayStart: false, canEdit: false))
        XCTAssertEqual(rights[commenter], PipelineRights(mayStart: false, canEdit: false))
        XCTAssertEqual(rights[old], PipelineRights(mayStart: true, canEdit: true))
        XCTAssertEqual(rights.count, 5, "an unknown project grants nothing (nil)")
    }

    // MARK: What the card detail shows

    func testPlainCardsStayShort() throws {
        let plain = try decode(pipeline(plan: false))
        XCTAssertEqual(plain.detail(bindings: [], mayStart: true, management: true, hasMessage: false), .none, "no binding: as before")
        XCTAssertEqual(plain.detail(bindings: bindings, mayStart: true, management: true, hasMessage: false), .startOnly,
                       "a plain card offers the start without an empty list of steps")
        XCTAssertEqual(plain.detail(bindings: bindings, mayStart: true, management: false, hasMessage: false), .none,
                       "classic projects keep the short to-do detail")
        XCTAssertEqual(plain.detail(bindings: [], mayStart: true, management: false, hasMessage: true), .startOnly, "a refusal stays readable")
        let off = try decode(pipeline(steps: steps(["tester": "skipped"], off: ["tester"]), plan: false))
        XCTAssertEqual(off.detail(bindings: [], mayStart: false, management: true, hasMessage: false), .none, "a step that is off is no activity")
    }

    func testCardsWithPipelineContentShowEverything() throws {
        for p in [try decode(pipeline()),
                  try decode(pipeline(steps: steps(["developer": "running"]), plan: false)),
                  try decode(pipeline(execution: execution("stopped"), plan: false))] {
            XCTAssertEqual(p.detail(bindings: [], mayStart: false, management: false, hasMessage: false), .full)
        }
    }
}
