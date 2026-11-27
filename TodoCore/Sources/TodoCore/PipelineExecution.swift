import Foundation

// MARK: Pipeline stage 3: execution on a runner (card BEE2417E; contract pipeline 1.2.0 in the main repository)
// The rules of the section "Ausführung" follow the PWA (`web/src/lib/pipelineExecution.ts`, `retryOffer` in `pipeline.ts`).
// Start, continue and stop need the start right (project owner); the app only hides controls, the server checks the right.
// Device, folder and progress texts come from the runner and are shown as plain text.

private struct ExecKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private extension KeyedDecodingContainer where K == ExecKey {
    func opt<T: Decodable>(_ name: String, as type: T.Type = T.self) -> T? { (try? decodeIfPresent(T.self, forKey: ExecKey(name))) ?? nil }
}

/// The execution of a card's pipeline on a runner. `state`, `reason`, `step` and `jobState` stay as sent (a newer server may add values).
public struct PipelineExecution: Decodable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case running, waitingApproval, blocked, paused, completed, stopped, unknown

        public init(raw: String) {
            switch raw {
            case "running": self = .running
            case "waiting_approval": self = .waitingApproval
            case "blocked": self = .blocked
            case "paused": self = .paused
            case "completed": self = .completed
            case "stopped": self = .stopped
            default: self = .unknown
            }
        }
    }

    /// Start of the progress text the runner sends with a hold (`todo-runner budget`).
    static let budgetHoldPrefix = "Kontingent-Bremse"

    public let id: UUID
    public let state: String
    /// With `paused` (`plan_needs_owner`, `task_changed`, `continue_required`) and `blocked` (`step_failed`, `fix_rounds_exhausted`).
    public let reason: String?
    public let step: String?
    public let bindingID: UUID?
    /// Empty when the binding was removed.
    public let bindingLabel: String?
    public let deviceLabel: String?
    /// False: the device never asked for pipeline jobs (an old runner, or one that has not polled yet).
    public let runnerSupportsPipeline: Bool?
    public let jobID: UUID?
    public let jobState: String?
    /// Progress or budget hold; only for viewers with the start right.
    public let jobProgress: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(id: UUID, state: String, reason: String? = nil, step: String? = nil, bindingID: UUID? = nil, bindingLabel: String? = nil,
                deviceLabel: String? = nil, runnerSupportsPipeline: Bool? = nil, jobID: UUID? = nil, jobState: String? = nil,
                jobProgress: String? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id; self.state = state; self.reason = reason; self.step = step; self.bindingID = bindingID; self.bindingLabel = bindingLabel
        self.deviceLabel = deviceLabel; self.runnerSupportsPipeline = runnerSupportsPipeline; self.jobID = jobID; self.jobState = jobState
        self.jobProgress = jobProgress; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// Throws without `id` or `state`: the pipeline then shows no execution.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ExecKey.self)
        self.init(id: try c.decode(UUID.self, forKey: ExecKey("id")), state: try c.decode(String.self, forKey: ExecKey("state")),
                  reason: c.opt("reason"), step: c.opt("step"), bindingID: c.opt("bindingID"), bindingLabel: c.opt("bindingLabel"),
                  deviceLabel: c.opt("deviceLabel"), runnerSupportsPipeline: c.opt("runnerSupportsPipeline"), jobID: c.opt("jobID"),
                  jobState: c.opt("jobState"), jobProgress: c.opt("jobProgress"), createdAt: c.opt("createdAt"), updatedAt: c.opt("updatedAt"))
    }

    public var stateKind: State { State(raw: state) }
    /// Not finished: completed and stopped end an execution, every other state (also an unknown one) is still going on.
    public var isActive: Bool { stateKind != .completed && stateKind != .stopped }
    /// The runner holds the queued job back (budget brake); the progress text says why.
    public var isBudgetHold: Bool { jobState == "queued" && (jobProgress?.hasPrefix(Self.budgetHoldPrefix) ?? false) }
    /// "Gerät · Ordner", leaving out empty parts; nil when both are empty.
    public var deviceLine: String? {
        let parts = [deviceLabel, bindingLabel].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    /// The progress to show as its own line (not while held: the hold has its own notice).
    public var shownProgress: String? {
        guard isActive, !isBudgetHold, let text = jobProgress, !text.isEmpty else { return nil }
        return text
    }
}

/// Fix rounds of the current plan version (stage 2).
public struct PipelineFixRounds: Decodable, Sendable, Equatable {
    public let used: Int
    public let max: Int
    public let remaining: Int
    public init(used: Int, max: Int, remaining: Int) { self.used = used; self.max = max; self.remaining = remaining }
}

/// The step a running execution is at, with what its job does right now.
public struct PipelineLiveStep: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case queued, claimed, running, answer, held }
    public enum Tone: Sendable, Equatable { case running, waiting, warning }
    public let step: String
    public let kind: Kind
    public let tone: Tone
    /// The progress the runner sent; nil for a hold (its text is shown in the section "Ausführung").
    public let progress: String?
}

/// An own binding (device and folder) of the card's project that a start can use.
public struct PipelineStartBinding: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let label: String
    public let deviceLabel: String
    public init(id: UUID, label: String, deviceLabel: String) { self.id = id; self.label = label; self.deviceLabel = deviceLabel }

    /// Bindings of paired, not revoked devices for the project, in the server's order.
    public static func forProject(_ projectID: UUID, devices: [RunnerDevice]) -> [PipelineStartBinding] {
        devices.filter { $0.paired && $0.revokedAt == nil }.flatMap { d in
            d.bindings.filter { $0.projectID == projectID }.map { PipelineStartBinding(id: $0.id, label: $0.label, deviceLabel: d.label) }
        }
    }
}

/// Whether the section "Ausführung" is there and offers a start.
public struct PipelineExecutionSection: Sendable, Equatable {
    public let show: Bool
    public let start: Bool
    public init(show: Bool, start: Bool) { self.show = show; self.start = start }
}

public enum PipelineRetryOffer: Sendable, Equatable { case hidden, ready(round: Int, max: Int), exhausted(max: Int) }
/// Shown at a retry while an execution is active: the retry is then more than a note on the board.
public enum PipelineRetryHint: Sendable, Equatable { case runs, needsOwner }
public enum PipelineExecutionAction: Sendable, Equatable { case start, `continue`, stop }

public extension TaskPipeline {
    /// The steps a runner works on; planner and approval come before them.
    private static let workSteps: Set<String> = ["developer", "validation", "tester", "review"]

    var liveStep: PipelineLiveStep? {
        guard let e = execution, e.stateKind == .running, let step = e.step else { return nil }
        let progress = (e.jobProgress?.isEmpty ?? true) ? nil : e.jobProgress
        if e.isBudgetHold { return .init(step: step, kind: .held, tone: .warning, progress: nil) }
        switch e.jobState {
        case "waiting_for_answer": return .init(step: step, kind: .answer, tone: .warning, progress: progress)
        case "claimed": return .init(step: step, kind: .claimed, tone: .running, progress: progress)
        case "running": return .init(step: step, kind: .running, tone: .running, progress: progress)
        default: return .init(step: step, kind: .queued, tone: .waiting, progress: progress)
        }
    }

    /// Every work step that is on is finished: the server would refuse a start (`nothing_to_run`).
    var nothingToRun: Bool {
        let on = steps.filter { Self.workSteps.contains($0.step) && $0.isOn }
        return !on.isEmpty && on.allSatisfy { $0.state == "done" || $0.state == "skipped" }
    }

    /// Without an execution and without an own binding the card looks like before.
    func executionSection(bindings: [PipelineStartBinding], mayStart: Bool) -> PipelineExecutionSection {
        let own = mayStart && !bindings.isEmpty
        return .init(show: execution != nil || own, start: own && !(execution?.isActive ?? false) && !nothingToRun)
    }

    /// The retry at a failed step: only with the edit right and only while fix rounds are left; the server decides in the end.
    func retryOffer(_ step: PipelineStepName, canEdit: Bool) -> PipelineRetryOffer {
        guard canEdit, step != .approval, let rounds = fixRounds, let s = stepStatus(step), s.stateKind == .failed, s.isOn else { return .hidden }
        return rounds.used >= rounds.max ? .exhausted(max: rounds.max) : .ready(round: rounds.used + 1, max: rounds.max)
    }

    func retryHint(mayStart: Bool) -> PipelineRetryHint? {
        guard execution?.isActive ?? false else { return nil }
        return mayStart ? .runs : .needsOwner
    }
}

/// Why a start, continue, stop or retry was refused. A plain 401 is not mapped and stays the general sign-in error.
public enum PipelineExecutionError: Error, Sendable, Equatable {
    case idConflict, active, nothingToRun, noExecution, planChanged, stepNotFailed, fixRoundsExhausted, stepDisabled, planNotApproved
    case forbidden, notFound, network

    public init?(_ error: any Error) {
        if let own = error as? PipelineExecutionError { self = own; return }
        switch error as? APIError {
        case .conflict(let reason)?:
            switch reason {
            case "execution_id_conflict": self = .idConflict
            case "execution_active": self = .active
            case "nothing_to_run": self = .nothingToRun
            case "no_execution": self = .noExecution
            case "plan_changed": self = .planChanged
            case "step_not_failed": self = .stepNotFailed
            case "fix_rounds_exhausted": self = .fixRoundsExhausted
            case "step_disabled": self = .stepDisabled
            case "plan_not_approved": self = .planNotApproved
            default: return nil
            }
        case .forbidden?: self = .forbidden
        case .notFound?: self = .notFound
        case .transport?: self = .network
        default: return nil
        }
    }

    /// The shown pipeline is outdated: the card is read again (never sent again on its own).
    public var showsOutdatedState: Bool {
        switch self {
        case .active, .nothingToRun, .noExecution, .planChanged, .stepNotFailed, .fixRoundsExhausted, .stepDisabled, .planNotApproved, .notFound: true
        case .idConflict, .forbidden, .network: false
        }
    }
}

/// The id of a start. A start whose answer got lost (no answer or 5xx) is sent again with the same id, so it never starts twice.
public struct PipelineStartAttempt: Sendable {
    private var pending: (taskID: UUID, bindingID: UUID, id: UUID)?
    public init() {}

    public mutating func id(taskID: UUID, bindingID: UUID) -> UUID {
        if let p = pending, p.taskID == taskID, p.bindingID == bindingID { return p.id }
        let id = UUID()
        pending = (taskID, bindingID, id)
        return id
    }

    /// nil = answered. Only without an answer the start may have happened; a refusal ends the attempt.
    public mutating func finished(with error: (any Error)?) {
        guard let error else { pending = nil; return }
        switch error as? APIError {
        case .transport?: return
        case .server(let status, _)? where status >= 500: return
        default: pending = nil
        }
    }
}

/// Starting and continuing accept the plan. A version that replaced the shown one while the card was open is not accepted with
/// one tap: the first tap only says "read first", the second one (for the same action and version) sends.
public struct PlanReadGuard: Sendable {
    private var seen = false
    private var version: Int?
    private var unread = false
    public private(set) var confirming: PipelineExecutionAction?
    public init() {}

    /// Every pipeline the card shows (the first one is the version the person opened).
    public mutating func shown(planVersion: Int?) {
        defer { seen = true; version = planVersion }
        guard seen, planVersion != version else { return }
        if planVersion != nil { unread = true }
        confirming = nil
    }

    /// True: show "read first" instead of sending.
    public mutating func needsConfirmation(for action: PipelineExecutionAction) -> Bool {
        guard action != .stop, unread, version != nil, confirming != action else { return false }
        confirming = action
        return true
    }

    /// A start or continue went through: the shown version is accepted.
    public mutating func sent() { unread = false; confirming = nil }
}

private struct StartBody: Encodable { let id: String; let bindingID: String }
private struct ContinueBody: Encodable { let planVersion: Int? }
private struct RetryBody: Encodable { let planVersion: Int? }
private struct EmptyBody: Encodable {}
private struct OwnerFlag: Decodable {
    let id: UUID
    let isOwner: Bool?
}

public extension APIClient {
    private func pipelinePath(_ taskID: UUID) -> String { "v1/tasks/\(taskID.uuidString.lowercased())/pipeline" }

    /// Starts the pipeline on an own binding (start right). `executionID` is chosen by the app (see `PipelineStartAttempt`).
    func startPipelineExecution(taskID: UUID, executionID: UUID, bindingID: UUID) async throws -> TaskPipeline {
        try await send("POST", pipelinePath(taskID) + "/execution",
                       body: StartBody(id: executionID.uuidString.lowercased(), bindingID: bindingID.uuidString.lowercased()))
    }

    /// Continues a paused execution; `planVersion` names the plan the person saw (409 `plan_changed` when it is not current).
    func continuePipelineExecution(taskID: UUID, planVersion: Int?) async throws -> TaskPipeline {
        try await send("POST", pipelinePath(taskID) + "/execution/continue", body: ContinueBody(planVersion: planVersion))
    }

    func stopPipelineExecution(taskID: UUID) async throws -> TaskPipeline {
        try await send("POST", pipelinePath(taskID) + "/execution/stop", body: EmptyBody())
    }

    /// A failed step back to pending (one fix round of the current plan version).
    func retryPipelineStep(taskID: UUID, step: PipelineStepName, planVersion: Int?) async throws -> TaskPipeline {
        try await send("POST", pipelinePath(taskID) + "/steps/\(step.rawValue)/retry", body: RetryBody(planVersion: planVersion))
    }

    /// Projects the viewer owns (start right); a server without the field counts as owner, like the PWA.
    func ownedProjectIDs() async throws -> [UUID] {
        let flags: [OwnerFlag] = try await send("GET", "v1/projects")
        return flags.filter { $0.isOwner ?? true }.map(\.id)
    }
}
