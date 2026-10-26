import Foundation
import Darwin

/// Starts `claude -p` in its own process group. stdout/stderr go to files, so
/// large answers cannot deadlock a pipe and the result survives a runner restart.
public actor ClaudeProcessAdapter: AgentProvider {
    private let executable: URL
    private let scratch: URL
    private let environment: [String: String]
    private var children: Set<Int32> = []
    private var interruptions: [Int32: RunnerError] = [:]

    public init(executable: URL, scratch: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable; self.scratch = scratch; self.environment = environment
    }

    static let outputSchema = #"{"type":"object","properties":{"text":{"type":"string"},"question":{"type":"string"},"options":{"type":"array","items":{"type":"string"}}},"required":["text"]}"#
    static let systemPrompt = "Answer with a concise summary in the structured text field. If you need a human decision, put exactly one question in the question field (optionally with answer options in options) and stop working. Never commit, push or deploy."

    /// Exposed for tests: the exact CLI arguments.
    public static func arguments(for request: AgentRequest) -> [String] {
        ["-p", request.prompt,
         request.resume ? "--resume" : "--session-id", request.sessionID.uuidString.lowercased(),
         "--output-format", "json",
         "--allowedTools", request.allowedTools.joined(separator: ","),
         "--permission-mode", "dontAsk",
         "--max-turns", String(request.maxTurns),
         "--tools", request.allowedTools.map { String($0.prefix(while: { $0 != "(" })) }.joined(separator: ","),
         "--json-schema", outputSchema,
         "--append-system-prompt", systemPrompt,
         "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
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
        let pid = try Self.spawn(executable: executable, arguments: [executable.path] + Self.arguments(for: request),
                                 environment: environment, folder: request.folder, output: output, error: error)
        children.insert(pid)
        return ProcessReference(pid: pid, startTime: Self.startTime(of: pid) ?? 0, outputPath: output.path,
                                sessionID: request.sessionID, deadline: Date().addingTimeInterval(request.timeout))
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

    /// Process start time (seconds since epoch) from the kernel, nil if the PID does not exist.
    static func startTime(of pid: Int32) -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
    }

    private func isAlive(_ process: ProcessReference) -> Bool {
        guard let start = Self.startTime(of: process.pid) else { return false }
        return process.startTime == 0 || abs(start - process.startTime) < 0.01
    }

    public func wait(for process: ProcessReference) async throws -> AgentResult {
        let ours = children.contains(process.pid)
        var status: Int32 = 0
        var reaped = false
        while true {
            if ours {
                let waited = waitpid(process.pid, &status, WNOHANG)
                if waited == process.pid { reaped = true; break }
                if waited < 0 && errno != EINTR { break }
            } else if !isAlive(process) { break }
            if Task.isCancelled { kill(-process.pid, SIGKILL); interruptions[process.pid] = interruptions[process.pid] ?? .stopped }
            if Date() >= process.deadline, interruptions[process.pid] == nil {
                interruptions[process.pid] = .timedOut
                kill(-process.pid, SIGKILL)
            }
            // Never leave the loop on cancellation before the process is reaped.
            try? await Task.sleep(for: .milliseconds(30))
        }
        children.remove(process.pid)
        let interruption = interruptions.removeValue(forKey: process.pid)
        let output = URL(fileURLWithPath: process.outputPath)
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(atPath: process.outputPath.replacingOccurrences(of: ".stdout", with: ".stderr"))
        }
        if let interruption { throw interruption }
        let exitStatus: Int32 = reaped ? ((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)) : 0
        let data = (try? Data(contentsOf: output)) ?? Data()
        return try Self.parse(data, sessionID: process.sessionID, exitStatus: exitStatus)
    }

    public func stop(_ process: ProcessReference) {
        // Only signal a process whose identity is verified (guards PID reuse).
        guard isAlive(process), getpgid(process.pid) == process.pid else { return }
        interruptions[process.pid] = .stopped
        // SIGKILL on the group: an ignored SIGTERM must not leave tool subprocesses alive.
        kill(-process.pid, SIGKILL)
    }

    public func reconcile(_ process: ProcessReference) -> ProcessObservation {
        if children.contains(process.pid) { return .running }
        guard let start = Self.startTime(of: process.pid) else { return .exited }
        if process.startTime == 0 { return .uncertain }
        return abs(start - process.startTime) < 0.01 ? .running : .exited
    }

    public static func parse(_ data: Data, sessionID: UUID, exitStatus: Int32) throws -> AgentResult {
        struct Envelope: Decodable {
            var session_id: String
            var result: String?
            var is_error: Bool
            var structured_output: Structured?
            struct Structured: Decodable { var text: String?; var question: String?; var options: [String]? }
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { throw RunnerError.invalidResult }
        guard UUID(uuidString: envelope.session_id) == sessionID else { throw RunnerError.sessionMismatch }
        let question = envelope.structured_output?.question.flatMap { $0.isEmpty ? nil : $0 }
        return AgentResult(text: envelope.structured_output?.text ?? envelope.result ?? "", question: question,
                           options: question == nil ? [] : (envelope.structured_output?.options ?? []),
                           exitStatus: exitStatus, isError: envelope.is_error || exitStatus != 0)
    }
}
