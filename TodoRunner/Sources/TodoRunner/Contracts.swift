import Foundation

public struct RunnerJob: Codable, Sendable, Equatable {
    public var id: UUID
    public var runID: UUID
    public var projectID: String
    public var generation: Int
    public var leaseExpiresAt: Date
    public var prompt: String
    public var allowedTools: [String]
    public var maxTurns: Int

    public init(id: UUID = UUID(), runID: UUID = UUID(), projectID: String,
                generation: Int, leaseExpiresAt: Date, prompt: String,
                allowedTools: [String] = ["Read"], maxTurns: Int = 5) {
        self.id = id; self.runID = runID; self.projectID = projectID
        self.generation = generation; self.leaseExpiresAt = leaseExpiresAt
        self.prompt = prompt; self.allowedTools = allowedTools; self.maxTurns = maxTurns
    }
}

public enum RunPhase: String, Codable, Sendable {
    case launching, running, stopping, waitingForAnswer, awaitingReview, failed, stopped, leaseLost, needsReconciliation
    public var reservesFolder: Bool {
        switch self {
        case .awaitingReview, .failed, .stopped: false
        default: true
        }
    }
}

public struct AgentResult: Codable, Sendable, Equatable {
    public var text: String
    public var question: String?
    public var exitStatus: Int32
    public var isError: Bool
    public init(text: String, question: String? = nil, exitStatus: Int32 = 0, isError: Bool = false) {
        self.text = text; self.question = question; self.exitStatus = exitStatus; self.isError = isError
    }
}

public struct RunnerEvent: Codable, Sendable {
    public var phase: RunPhase
    public var checkpoint: String
    public var result: AgentResult?
    public init(phase: RunPhase, checkpoint: String, result: AgentResult? = nil) {
        self.phase = phase; self.checkpoint = checkpoint; self.result = result
    }
}

/// The eventual authenticated transport must atomically fence EVERY mutation by
/// job/run ID, generation, device ownership and an unexpired server-side lease.
/// No method accepts a local filesystem path.
public protocol RunnerServer: Sendable {
    func claim(eligibleProjects: [String]) async throws -> RunnerJob?
    func renew(_ job: RunnerJob) async throws -> Date?
    func publish(_ event: RunnerEvent, for job: RunnerJob) async throws
    func answer(for job: RunnerJob) async throws -> String?
}

public struct AgentRequest: Sendable {
    public var sessionID: UUID
    public var folder: URL
    public var prompt: String
    public var resume: Bool
    public var allowedTools: [String]
    public var maxTurns: Int
    public var timeout: TimeInterval
    public init(sessionID: UUID, folder: URL, prompt: String, resume: Bool = false,
                allowedTools: [String] = ["Read"], maxTurns: Int = 5, timeout: TimeInterval = 300) {
        self.sessionID = sessionID; self.folder = folder; self.prompt = prompt; self.resume = resume
        self.allowedTools = allowedTools; self.maxTurns = maxTurns; self.timeout = timeout
    }
}

public struct ProcessReference: Codable, Sendable, Equatable {
    public var pid: Int32
    public init(pid: Int32) { self.pid = pid }
}
public enum ProcessObservation: Sendable { case running, exited, uncertain }

public protocol AgentProvider: Sendable {
    func start(_ request: AgentRequest) async throws -> ProcessReference
    func wait(for process: ProcessReference) async throws -> AgentResult
    func stop(_ process: ProcessReference) async
    func reconcile(_ process: ProcessReference) async -> ProcessObservation
}

public enum RunnerError: Error {
    case alreadyOpen, unapprovedFolder, invalidConfiguration, spawn(Int32)
    case unknownProcess, invalidResult, timedOut, stopped, sessionMismatch
}
