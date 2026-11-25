import Foundation

/// A command configured on this Mac: argument vector (no shell) and time limit.
public struct LocalCommand: Codable, Sendable, Equatable {
    public var argv: [String]
    public var timeout: TimeInterval
    public init(argv: [String], timeout: TimeInterval) { self.argv = argv; self.timeout = timeout }
}

public struct LocalCommands: Sendable {
    public static let defaultValidationTimeout: TimeInterval = 1800
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("commands.json") }
    public init(directory: URL) { self.directory = directory }
    public func validation(for repositoryKey: UUID) throws -> LocalCommand? { nil }
    public func setValidation(_ command: LocalCommand?, for repositoryKey: UUID) throws {}
    public func validations() throws -> [UUID: LocalCommand] { [:] }
    public func budget() throws -> [String]? { nil }
    public func setBudget(_ argv: [String]?) throws {}
}

public struct CommandRequest: Sendable {
    public var argv: [String]
    public var folder: URL
    /// Receives stdout, and stderr too unless `errorOutput` is set. Created owner-only.
    public var output: URL
    public var errorOutput: URL?
    public var timeout: TimeInterval
    public init(argv: [String], folder: URL, output: URL, errorOutput: URL? = nil, timeout: TimeInterval) {
        self.argv = argv; self.folder = folder; self.output = output; self.errorOutput = errorOutput; self.timeout = timeout
    }
}

public struct CommandResult: Sendable, Equatable {
    /// nil when the process was adopted after a runner restart: its exit status cannot be learned.
    public var exitCode: Int32?
    public var duration: TimeInterval
    public init(exitCode: Int32?, duration: TimeInterval) { self.exitCode = exitCode; self.duration = duration }
}

/// Local commands (validation, budget). Same process rules as agents, but no agent involved.
public protocol CommandExecutor: Sendable {
    func start(_ request: CommandRequest) async throws -> ProcessReference
    func wait(for process: ProcessReference) async throws -> CommandResult
    func stop(_ process: ProcessReference) async
    func reconcile(_ process: ProcessReference) async -> ProcessObservation
}

public actor ProcessCommandExecutor: CommandExecutor {
    public init() {}
    public func start(_ request: CommandRequest) throws -> ProcessReference { throw RunnerError.invalidConfiguration }
    public func wait(for process: ProcessReference) async throws -> CommandResult { throw RunnerError.invalidConfiguration }
    public func stop(_ process: ProcessReference) {}
    public func reconcile(_ process: ProcessReference) -> ProcessObservation { .exited }
}
