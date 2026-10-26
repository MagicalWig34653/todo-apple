import Foundation
import Darwin

/// posix_spawn creates a separate process group before executing Claude. Output
/// goes to files, avoiding pipe-buffer deadlocks for large CLI responses.
public actor ClaudeProcessAdapter: AgentProvider {
    private struct Child {
        var output: URL
        var error: URL
        var session: UUID
        var deadline: Date
        var interruption: RunnerError?
    }
    private let executable: URL
    private let scratch: URL
    private let environment: [String: String]
    private var children: [Int32: Child] = [:]

    public init(executable: URL, scratch: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable; self.scratch = scratch; self.environment = environment
    }

    public func start(_ request: AgentRequest) throws -> ProcessReference {
        guard request.maxTurns > 0, request.timeout > 0,
              !request.allowedTools.isEmpty, request.allowedTools.allSatisfy({ !$0.isEmpty }) else {
            throw RunnerError.invalidConfiguration
        }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let token = UUID().uuidString
        let output = scratch.appendingPathComponent(token + ".stdout")
        let error = scratch.appendingPathComponent(token + ".stderr")
        let arguments = [executable.path, "-p", request.prompt,
                         request.resume ? "--resume" : "--session-id", request.sessionID.uuidString.lowercased(),
                         "--output-format", "json", "--allowedTools", request.allowedTools.joined(separator: ","),
                         "--permission-mode", "dontAsk", "--max-turns", String(request.maxTurns),
                         "--tools", request.allowedTools.map { String($0.prefix(while: { $0 != "(" })) }.joined(separator: ","),
                         "--json-schema", "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"},\"question\":{\"type\":\"string\"}},\"required\":[\"text\"]}",
                         "--append-system-prompt", "Return a concise text summary. If human input is required, put the question in the structured question field and stop working.",
                         "--safe-mode", "--setting-sources", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"]
        let pid = try Self.spawn(executable: executable, arguments: arguments, environment: environment,
                                 folder: request.folder, output: output, error: error)
        children[pid] = Child(output: output, error: error, session: request.sessionID,
                              deadline: Date().addingTimeInterval(request.timeout))
        return ProcessReference(pid: pid)
    }

    private nonisolated static func spawn(executable: URL, arguments: [String], environment: [String: String],
                                          folder: URL, output: URL, error: URL) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        for status in [
            posix_spawn_file_actions_addchdir_np(&actions, folder.path),
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600),
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, error.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)),
            posix_spawnattr_setpgroup(&attributes, 0),
        ] { guard status == 0 else { throw RunnerError.spawn(status) } }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let status = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard status == 0 else { throw RunnerError.spawn(status) }
        return pid
    }

    public func wait(for process: ProcessReference) async throws -> AgentResult {
        guard let child = children[process.pid] else { throw RunnerError.unknownProcess }
        defer {
            children.removeValue(forKey: process.pid)
            try? FileManager.default.removeItem(at: child.output)
            try? FileManager.default.removeItem(at: child.error)
        }
        var status: Int32 = 0
        while true {
            let waited = waitpid(process.pid, &status, WNOHANG)
            if waited == process.pid { break }
            if waited < 0 && errno != EINTR { throw RunnerError.unknownProcess }
            if Task.isCancelled { stop(process) }
            if Date() >= child.deadline, children[process.pid]?.interruption == nil {
                children[process.pid]?.interruption = .timedOut
                terminateGroup(process.pid)
            }
            // Cancellation must not skip reaping the process.
            try? await Task.sleep(for: .milliseconds(30))
        }
        if let interruption = children[process.pid]?.interruption { throw interruption }
        let exitStatus: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        let data = try Data(contentsOf: child.output)
        return try Self.parse(data, sessionID: child.session, exitStatus: exitStatus)
    }

    public func stop(_ process: ProcessReference) {
        // Never signal an unverified/reused PID recovered from disk.
        guard children[process.pid] != nil else { return }
        children[process.pid]?.interruption = .stopped
        terminateGroup(process.pid)
    }

    private func terminateGroup(_ pid: Int32) {
        // SIGKILL prevents ignored SIGTERM from leaving tool subprocesses alive.
        kill(-pid, SIGKILL)
    }

    public func reconcile(_ process: ProcessReference) -> ProcessObservation {
        if children[process.pid] != nil { return .running }
        if kill(process.pid, 0) == -1 && errno == ESRCH { return .exited }
        // PID existence is not proof of process identity after a runner restart.
        return .uncertain
    }

    public static func parse(_ data: Data, sessionID: UUID, exitStatus: Int32) throws -> AgentResult {
        struct Envelope: Decodable {
            var session_id: String
            var result: String?
            var is_error: Bool
            var structured_output: Structured?
            struct Structured: Decodable { var text: String?; var question: String? }
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard UUID(uuidString: envelope.session_id) == sessionID else { throw RunnerError.sessionMismatch }
        return AgentResult(text: envelope.structured_output?.text ?? envelope.result ?? "", question: envelope.structured_output?.question,
                           exitStatus: exitStatus, isError: envelope.is_error || exitStatus != 0)
    }
}
