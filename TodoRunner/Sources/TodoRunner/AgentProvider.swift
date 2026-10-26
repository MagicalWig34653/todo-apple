import Foundation

public struct AgentRequest: Sendable {
    public var sessionID: UUID
    public var folder: URL
    public var prompt: String
    public var resume: Bool
    public var allowedTools: [String]
    public var maxTurns: Int
    public var timeout: TimeInterval
    public init(sessionID: UUID, folder: URL, prompt: String, resume: Bool = false,
                allowedTools: [String] = ["Read"], maxTurns: Int = 5, timeout: TimeInterval = 600) {
        self.sessionID = sessionID; self.folder = folder; self.prompt = prompt; self.resume = resume
        self.allowedTools = allowedTools; self.maxTurns = maxTurns; self.timeout = timeout
    }
}

/// Identifies a spawned agent process across runner restarts. The start time
/// guards against PID reuse; the output file allows collecting the result of a
/// process that finished while the runner was down.
public struct ProcessReference: Codable, Sendable, Equatable {
    public var pid: Int32
    public var startTime: Double
    public var outputPath: String
    public var sessionID: UUID
    public var deadline: Date
    public init(pid: Int32, startTime: Double = 0, outputPath: String = "", sessionID: UUID = UUID(),
                deadline: Date = .distantFuture) {
        self.pid = pid; self.startTime = startTime; self.outputPath = outputPath
        self.sessionID = sessionID; self.deadline = deadline
    }
}

public struct AgentResult: Codable, Sendable, Equatable {
    public var text: String
    public var question: String?
    public var options: [String]
    public var exitStatus: Int32
    public var isError: Bool
    public init(text: String, question: String? = nil, options: [String] = [], exitStatus: Int32 = 0, isError: Bool = false) {
        self.text = text; self.question = question; self.options = options
        self.exitStatus = exitStatus; self.isError = isError
    }
}

public enum ProcessObservation: Sendable, Equatable {
    /// Identity verified (PID and start time match): the agent process is alive.
    case running
    /// Verified gone.
    case exited
    /// Cannot be verified; keep the folder reserved.
    case uncertain
}

/// Coding-agent boundary. Claude Code is the first provider (ADR 0004).
public protocol AgentProvider: Sendable {
    func start(_ request: AgentRequest) async throws -> ProcessReference
    /// Returns when the process ended (also for adopted processes after a runner restart).
    func wait(for process: ProcessReference) async throws -> AgentResult
    /// Kills the whole process group; never signals an unverified PID.
    func stop(_ process: ProcessReference) async
    func reconcile(_ process: ProcessReference) async -> ProcessObservation
}

public enum RunnerError: Error, Equatable {
    case alreadyOpen, unapprovedFolder, invalidConfiguration, spawn(Int32)
    case unknownProcess, invalidResult, timedOut, stopped, sessionMismatch
}
