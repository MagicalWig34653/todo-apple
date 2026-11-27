import Foundation

// MARK: Plan approval and pipeline status per card (card B6FC965A, contracts/pipeline.yaml 1.0.0 in the main repository)
// Per task one current plan (Markdown, version, approval), six fixed steps and a log. Reading is tolerant like `OverviewNow`:
// an unknown step, state, plan state or action stays displayable as raw text, an entry without its identity is dropped, a broken
// plan counts as "no plan", and an unknown future field is ignored.

private struct PipelineKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private struct PipelineLossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

private extension KeyedDecodingContainer where K == PipelineKey {
    func opt<T: Decodable>(_ name: String, as type: T.Type = T.self) -> T? { (try? decodeIfPresent(T.self, forKey: PipelineKey(name))) ?? nil }
    func need<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T { try decode(T.self, forKey: PipelineKey(name)) }
    func items<T: Decodable>(_ name: String, as type: T.Type = T.self) -> [T] {
        ((try? decodeIfPresent([PipelineLossy<T>].self, forKey: PipelineKey(name))) ?? nil)?.compactMap(\.value) ?? []
    }
}

/// The six steps in their fixed order. `approval` is managed by the server (the plan decision), the others are reported by agents.
public enum PipelineStepName: String, CaseIterable, Sendable {
    case planner, approval, developer, validation, tester, review
}

/// The current plan of a card. `state` is `proposed`, `approved` or `changes_requested` (anything else stays as sent).
public struct PipelinePlan: Decodable, Sendable, Equatable {
    public let version: Int
    public let body: String
    public let state: String
    public let authorType: String?
    public let authorLabel: String?
    public let writtenAt: Date?
    public let decidedAt: Date?
    public let decidedByLabel: String?
    public let decisionComment: String?

    public var isProposed: Bool { state == "proposed" }
    public var isApproved: Bool { state == "approved" }
    public var isChangesRequested: Bool { state == "changes_requested" }

    public init(version: Int, body: String, state: String, authorType: String? = nil, authorLabel: String? = nil, writtenAt: Date? = nil,
                decidedAt: Date? = nil, decidedByLabel: String? = nil, decisionComment: String? = nil) {
        self.version = version; self.body = body; self.state = state; self.authorType = authorType; self.authorLabel = authorLabel
        self.writtenAt = writtenAt; self.decidedAt = decidedAt; self.decidedByLabel = decidedByLabel; self.decisionComment = decisionComment
    }

    /// Throws without a usable version (>= 1) or body: the pipeline then shows no plan.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: PipelineKey.self)
        let version: Int = try c.need("version")
        let body: String = try c.need("body")
        guard version >= 1, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "plan without version or body"))
        }
        self.init(version: version, body: body, state: c.opt("state") ?? "proposed", authorType: c.opt("authorType"), authorLabel: c.opt("authorLabel"),
                  writtenAt: c.opt("writtenAt"), decidedAt: c.opt("decidedAt"), decidedByLabel: c.opt("decidedByLabel"),
                  decisionComment: c.opt("decisionComment"))
    }
}

/// The status of one step. `step` and `state` are kept as sent (a newer server may add both); `stateKind` is the known part.
public struct PipelineStepStatus: Decodable, Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case pending, running, waiting, changesRequested, done, failed, skipped, unknown

        public init(raw: String) {
            switch raw {
            case "pending": self = .pending
            case "running": self = .running
            case "waiting": self = .waiting
            case "changes_requested": self = .changesRequested
            case "done": self = .done
            case "failed": self = .failed
            case "skipped": self = .skipped
            default: self = .unknown
            }
        }
    }

    public let step: String
    public let state: String
    public let note: String?
    public let actorLabel: String?
    public let updatedAt: Date?
    /// Stage 2: false when the project switched the step off; missing on older servers (= on).
    public let enabled: Bool?
    public var id: String { step }
    public var stateKind: State { State(raw: state) }
    public var isOn: Bool { enabled ?? true }
    public var name: PipelineStepName? { PipelineStepName(rawValue: step) }

    public init(step: String, state: String, note: String? = nil, actorLabel: String? = nil, updatedAt: Date? = nil, enabled: Bool? = nil) {
        self.step = step; self.state = state; self.note = note; self.actorLabel = actorLabel; self.updatedAt = updatedAt; self.enabled = enabled
    }

    /// Throws without `step` or `state`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: PipelineKey.self)
        self.init(step: try c.need("step"), state: try c.need("state"), note: c.opt("note"), actorLabel: c.opt("actorLabel"), updatedAt: c.opt("updatedAt"),
                  enabled: c.opt("enabled"))
    }
}

/// One log entry of the pipeline (newest first in `TaskPipeline.events`).
public struct PipelineEvent: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case planWritten, planApproved, planChangesRequested, stepChanged, unknown
        // Stage 2 and 3 (card BEE2417E).
        case stepRetried, executionStarted, executionContinued, executionStopped, executionCompleted
        /// Only an activity kind (`pipeline.execution`): start, continue or stop.
        case executionChanged

        /// From the contract's `action` (`plan_written`, ...).
        public init(action: String) {
            switch action {
            case "plan_written": self = .planWritten
            case "plan_approved": self = .planApproved
            case "plan_changes_requested": self = .planChangesRequested
            case "step_changed": self = .stepChanged
            case "step_retried": self = .stepRetried
            case "execution_started": self = .executionStarted
            case "execution_continued": self = .executionContinued
            case "execution_stopped": self = .executionStopped
            case "execution_completed": self = .executionCompleted
            default: self = .unknown
            }
        }
    }

    public let id: UUID
    public let action: String
    public let planVersion: Int?
    public let step: String?
    public let state: String?
    public let note: String?
    public let actorType: String?
    public let actorLabel: String?
    public let createdAt: Date?
    public var kind: Kind { Kind(action: action) }

    public init(id: UUID, action: String, planVersion: Int? = nil, step: String? = nil, state: String? = nil, note: String? = nil,
                actorType: String? = nil, actorLabel: String? = nil, createdAt: Date? = nil) {
        self.id = id; self.action = action; self.planVersion = planVersion; self.step = step; self.state = state; self.note = note
        self.actorType = actorType; self.actorLabel = actorLabel; self.createdAt = createdAt
    }

    /// Throws without `id` or `action`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: PipelineKey.self)
        self.init(id: try c.need("id"), action: try c.need("action"), planVersion: c.opt("planVersion"), step: c.opt("step"), state: c.opt("state"),
                  note: c.opt("note"), actorType: c.opt("actorType"), actorLabel: c.opt("actorLabel"), createdAt: c.opt("createdAt"))
    }
}

/// `GET /v1/tasks/{id}/pipeline`: plan, steps and the last 50 log entries.
public struct TaskPipeline: Decodable, Sendable, Equatable {
    public let taskID: UUID
    public let plan: PipelinePlan?
    public let steps: [PipelineStepStatus]
    public let events: [PipelineEvent]
    /// Stage 2: fix rounds of the current plan version; missing on older servers (then there is no retry).
    public let fixRounds: PipelineFixRounds?
    /// Stage 3: the execution on a runner; missing while the card was never started.
    public let execution: PipelineExecution?

    public init(taskID: UUID, plan: PipelinePlan? = nil, steps: [PipelineStepStatus] = [], events: [PipelineEvent] = [],
                fixRounds: PipelineFixRounds? = nil, execution: PipelineExecution? = nil) {
        self.taskID = taskID; self.plan = plan; self.steps = steps; self.events = events; self.fixRounds = fixRounds; self.execution = execution
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: PipelineKey.self)
        self.init(taskID: try c.need("taskID"), plan: c.opt("plan"), steps: c.items("steps"), events: c.items("events"),
                  fixRounds: c.opt("fixRounds"), execution: c.opt("execution"))
    }

    /// A proposed plan waits for the person's decision: the actions "Plan freigeben" and "Änderungen" are offered.
    public var isWaitingForDecision: Bool { plan?.isProposed ?? false }

    public func stepStatus(_ name: PipelineStepName) -> PipelineStepStatus? { steps.first { $0.step == name.rawValue } }
}

/// The names of the new activity kinds of a card (`plan.written`, `plan.approved`, `plan.changes_requested`, `pipeline.step`) in
/// the activity list of the detail, the command center updates and the "Jetzt" overview. The key is the string catalog key
/// of the detail ("activity.plan_written", ...); every other kind is not claimed here and keeps its own naming.
public enum PipelineActivity {
    public static func kind(of activityKind: String) -> PipelineEvent.Kind? {
        switch activityKind {
        case "plan.written": .planWritten
        case "plan.approved": .planApproved
        case "plan.changes_requested": .planChangesRequested
        case "pipeline.step": .stepChanged
        case "pipeline.execution": .executionChanged
        default: nil
        }
    }

    public static func isPipelineKind(_ activityKind: String) -> Bool { kind(of: activityKind) != nil }

    public static func localizationKey(for activityKind: String) -> String? {
        switch kind(of: activityKind) {
        case .planWritten: "activity.plan_written"
        case .planApproved: "activity.plan_approved"
        case .planChangesRequested: "activity.plan_changes_requested"
        case .stepChanged: "activity.pipeline_step"
        case .executionChanged: "activity.pipeline_execution"
        case .unknown, .stepRetried, .executionStarted, .executionContinued, .executionStopped, .executionCompleted, nil: nil
        }
    }
}

public enum PlanDecision: String, Sendable { case approve, requestChanges = "request_changes" }

/// Why a plan decision was refused (the server's codes of `POST /v1/tasks/{id}/plan/decision`); `commentRequired` is also checked
/// before the request. A plain 403 (no edit right) is not mapped and stays the general permission error.
public enum PlanDecisionError: Error, Sendable, Equatable {
    /// "Änderungen" without a comment.
    case commentRequired
    case invalidComment
    /// A newer plan version exists (or the version was not valid): reload and look again.
    case planChanged
    /// The plan is already decided.
    case planNotPending
    case noPlan
    /// An agent may not decide its own plan.
    case ownPlan
    /// Agents decide only under the Brain mandate.
    case notAllowed

    public init?(_ error: any Error) {
        if let own = error as? PlanDecisionError { self = own; return }
        switch error as? APIError {
        case .conflict(let reason)?:
            switch reason {
            case "plan_changed": self = .planChanged
            case "plan_not_pending": self = .planNotPending
            case "no_plan": self = .noPlan
            default: return nil
            }
        case .forbidden(let reason)?:
            switch reason {
            case "cannot_decide_own_plan": self = .ownPlan
            case "brain_mandate_required", "outside_brain_mandate": self = .notAllowed
            default: return nil
            }
        case .invalidInput(let reason)?:
            switch reason {
            case "comment_required": self = .commentRequired
            case "invalid_comment": self = .invalidComment
            case "invalid_version": self = .planChanged
            default: return nil
            }
        default: return nil
        }
    }
}

struct PlanDecisionBody: Encodable { let decision: String; let version: Int; let comment: String? }

public extension APIClient {
    /// Plan, steps and log of a card. Needs a server with contract pipeline 1.0.0 (404 on an older one).
    func taskPipeline(taskID: UUID) async throws -> TaskPipeline {
        try await send("GET", "v1/tasks/\(taskID.uuidString.lowercased())/pipeline")
    }

    /// Like `taskPipeline`, but nil on 404 (server without pipeline, or the card is gone): the detail then shows no pipeline.
    func taskPipelineIfAvailable(taskID: UUID) async throws -> TaskPipeline? {
        do { return try await taskPipeline(taskID: taskID) } catch APIError.notFound { return nil }
    }

    /// Approves the plan `version` or asks for changes (comment required, `PlanDecisionError.commentRequired` before any request).
    func decidePlan(taskID: UUID, decision: PlanDecision, version: Int, comment: String? = nil) async throws -> TaskPipeline {
        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if decision == .requestChanges, text == nil { throw PlanDecisionError.commentRequired }
        return try await send("POST", "v1/tasks/\(taskID.uuidString.lowercased())/plan/decision",
                              body: PlanDecisionBody(decision: decision.rawValue, version: version, comment: text))
    }
}
