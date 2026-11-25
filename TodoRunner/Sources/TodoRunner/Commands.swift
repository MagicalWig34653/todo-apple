import Foundation
import Darwin

/// A command configured on this Mac: argument vector (no shell) and time limit.
public struct LocalCommand: Codable, Sendable, Equatable {
    public var argv: [String]
    public var timeout: TimeInterval
    public init(argv: [String], timeout: TimeInterval) { self.argv = argv; self.timeout = timeout }
}

/// The commands of this Mac (`commands.json`, owner-only). They are only ever set by the local CLI: nothing the
/// server sends can add or change them, and neither they nor their output leave the device.
public struct LocalCommands: Sendable {
    public static let defaultValidationTimeout: TimeInterval = 1800
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("commands.json") }
    public init(directory: URL) { self.directory = directory }

    private struct Stored: Codable {
        var validation: [String: LocalCommand] = [:]
        var budget: [String]?
    }

    private func load() throws -> Stored {
        guard FileManager.default.fileExists(atPath: file.path) else { return Stored() }
        return try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file))
    }

    private func change(_ apply: (inout Stored) -> Void) throws {
        var stored = try load()
        apply(&stored)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try LocalStateStore.write(try JSONEncoder().encode(stored), to: file)
    }

    public func validation(for repositoryKey: UUID) throws -> LocalCommand? {
        try load().validation[repositoryKey.uuidString.lowercased()]
    }

    public func setValidation(_ command: LocalCommand?, for repositoryKey: UUID) throws {
        try change { $0.validation[repositoryKey.uuidString.lowercased()] = command }
    }

    public func validations() throws -> [UUID: LocalCommand] {
        Dictionary(uniqueKeysWithValues: try load().validation.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    public func budget() throws -> [String]? { try load().budget }

    public func setBudget(_ argv: [String]?) throws { try change { $0.budget = argv } }
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
    private let environment: [String: String]
    private let supervisor = ProcessSupervisor()

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) { self.environment = environment }

    /// First executable file of that name in `path` (a bare program name, as a shell would find it).
    public static func search(_ program: String, path: String?) -> String? {
        (path ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin").split(separator: ":")
            .map { "\($0)/\(program)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func start(_ request: CommandRequest) async throws -> ProcessReference {
        guard let program = request.argv.first, !program.isEmpty, request.timeout > 0 else { throw RunnerError.invalidConfiguration }
        let executable: URL
        if program.hasPrefix("/") { executable = URL(fileURLWithPath: program) }
        else if program.contains("/") { executable = request.folder.appendingPathComponent(program) }
        else {
            guard let found = Self.search(program, path: environment["PATH"]) else { throw RunnerError.unknownProgram }
            executable = URL(fileURLWithPath: found)
        }
        for file in [request.output, request.errorOutput].compactMap({ $0 }) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try? FileManager.default.removeItem(at: file)     // a fresh file gets owner-only permissions
        }
        let pid = try await supervisor.spawn(executable: executable, arguments: request.argv, environment: environment,
                                             folder: request.folder, output: request.output, errorOutput: request.errorOutput)
        return ProcessReference(pid: pid, startTime: ProcessSupervisor.startTime(of: pid) ?? 0, outputPath: request.output.path,
                                deadline: Date().addingTimeInterval(request.timeout))
    }

    public func wait(for process: ProcessReference) async throws -> CommandResult {
        let code = try await supervisor.exitStatus(of: process)
        // Background processes the command left behind end with it (only while the group is provably ours).
        if code != nil { kill(-process.pid, SIGKILL) }
        let duration = process.startTime > 0 ? max(0, Date().timeIntervalSince1970 - process.startTime) : 0
        return CommandResult(exitCode: code, duration: duration)
    }

    public func stop(_ process: ProcessReference) async { await supervisor.stop(process) }

    public func reconcile(_ process: ProcessReference) async -> ProcessObservation { await supervisor.reconcile(process) }
}
