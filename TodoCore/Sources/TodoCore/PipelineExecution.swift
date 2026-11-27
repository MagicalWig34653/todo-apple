import Foundation

// MARK: Pipeline stage 3: execution on a runner (card BEE2417E; contract pipeline 1.2.0 in the main repository)
// Interfaces only (red tests first); the behaviour follows in the next commit.

public struct PipelineExecution: Decodable, Sendable, Equatable {
    public enum State: Sendable, Equatable { case running, waitingApproval, blocked, paused, completed, stopped, unknown }

    public let id: UUID
    public let state: String
    public let reason: String?
    public let step: String?
    public let bindingID: UUID?
    public let bindingLabel: String?
    public let deviceLabel: String?
    public let runnerSupportsPipeline: Bool?
    public let jobID: UUID?
    public let jobState: String?
    public let jobProgress: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    public var stateKind: State { .unknown }
    public var isActive: Bool { false }
    public var isBudgetHold: Bool { false }
    public var deviceLine: String? { nil }
}

public struct PipelineFixRounds: Decodable, Sendable, Equatable {
    public let used: Int
    public let max: Int
    public let remaining: Int
    public init(used: Int, max: Int, remaining: Int) { self.used = used; self.max = max; self.remaining = remaining }
}

public struct PipelineLiveStep: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case queued, claimed, running, answer, held }
    public enum Tone: Sendable, Equatable { case running, waiting, warning }
    public let step: String
    public let kind: Kind
    public let tone: Tone
    public let progress: String?
}

public struct PipelineStartBinding: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let label: String
    public let deviceLabel: String
    public init(id: UUID, label: String, deviceLabel: String) { self.id = id; self.label = label; self.deviceLabel = deviceLabel }
    public static func forProject(_ projectID: UUID, devices: [RunnerDevice]) -> [PipelineStartBinding] { [] }
}

public struct PipelineExecutionSection: Sendable, Equatable {
    public let show: Bool
    public let start: Bool
    public init(show: Bool, start: Bool) { self.show = show; self.start = start }
}

public enum PipelineRetryOffer: Sendable, Equatable { case hidden, ready(round: Int, max: Int), exhausted(max: Int) }
public enum PipelineRetryHint: Sendable, Equatable { case runs, needsOwner }
public enum PipelineExecutionAction: Sendable, Equatable { case start, `continue`, stop }

public extension TaskPipeline {
    var liveStep: PipelineLiveStep? { nil }
    var nothingToRun: Bool { false }
    func executionSection(bindings: [PipelineStartBinding], mayStart: Bool) -> PipelineExecutionSection { .init(show: false, start: false) }
    func retryOffer(_ step: PipelineStepName, canEdit: Bool) -> PipelineRetryOffer { .hidden }
    func retryHint(mayStart: Bool) -> PipelineRetryHint? { nil }
}

public enum PipelineExecutionError: Error, Sendable, Equatable {
    case idConflict, active, nothingToRun, noExecution, planChanged, stepNotFailed, fixRoundsExhausted, stepDisabled, planNotApproved
    case forbidden, notFound, network
    public init?(_ error: any Error) { return nil }
    public var showsOutdatedState: Bool { false }
}

public struct PipelineStartAttempt: Sendable {
    public init() {}
    public mutating func id(taskID: UUID, bindingID: UUID) -> UUID { UUID() }
    public mutating func finished(with error: (any Error)?) {}
}

public struct PlanReadGuard: Sendable {
    public private(set) var confirming: PipelineExecutionAction?
    public init() {}
    public mutating func shown(planVersion: Int?) {}
    public mutating func needsConfirmation(for action: PipelineExecutionAction) -> Bool { false }
    public mutating func sent() {}
}

public extension APIClient {
    func startPipelineExecution(taskID: UUID, executionID: UUID, bindingID: UUID) async throws -> TaskPipeline { throw APIError.invalidResponse }
    func continuePipelineExecution(taskID: UUID, planVersion: Int?) async throws -> TaskPipeline { throw APIError.invalidResponse }
    func stopPipelineExecution(taskID: UUID) async throws -> TaskPipeline { throw APIError.invalidResponse }
    func retryPipelineStep(taskID: UUID, step: PipelineStepName, planVersion: Int?) async throws -> TaskPipeline { throw APIError.invalidResponse }
    func ownedProjectIDs() async throws -> [UUID] { throw APIError.invalidResponse }
}
