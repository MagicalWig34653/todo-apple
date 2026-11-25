import Foundation
import Darwin

/// Starts `claude -p` in its own process group. stdout/stderr go to files, so
/// large answers cannot deadlock a pipe and the result survives a runner restart.
public actor ClaudeProcessAdapter: AgentProvider {
    private let executable: URL
    private let scratch: URL
    private let environment: [String: String]
    private let supervisor = ProcessSupervisor()
    private var tails: [Int32: StreamTail] = [:]

    public init(executable: URL, scratch: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable; self.scratch = scratch; self.environment = environment
    }

    static let outputSchema = #"{"type":"object","properties":{"text":{"type":"string"},"question":{"type":"string"},"options":{"type":"array","items":{"type":"string"}}},"required":["text"]}"#
    /// Pipeline steps require additional structured fields (planner: `plan`; tester and review: `verdict`).
    static func outputSchema(for step: PipelineStep?) -> String {
        let field: (name: String, schema: String)? = switch step {
        case .planner: ("plan", #"{"type":"string"}"#)
        case .tester, .review: ("verdict", #"{"type":"string","enum":["passed","failed"]}"#)
        default: nil
        }
        guard let field else { return outputSchema }
        return outputSchema
            .replacingOccurrences(of: #""properties":{"#, with: #""properties":{"\#(field.name)":\#(field.schema),"#)
            .replacingOccurrences(of: #""required":["text"]"#, with: #""required":["text","\#(field.name)"]"#)
    }

    /// Model and effort come from the server: only plain identifiers, never something that reads as another flag.
    static func isAgentValue(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-")
            && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._:/-".unicodeScalars.contains($0)) }
    }

    static let systemPrompt = "Answer with a concise summary in the structured text field. If you need a human decision, put exactly one question in the question field (optionally with answer options in options) and stop working. Never commit, push or deploy. If Todo MCP tools are available in this session, call get_manual once at the start and follow it; if they are not available, continue without it. Never put secrets, tokens or passwords into answers, questions or files."

    /// Exposed for tests: the exact CLI arguments.
    public static func arguments(for request: AgentRequest) -> [String] {
        ["-p", request.prompt,
         request.resume ? "--resume" : "--session-id", request.sessionID.uuidString.lowercased(),
         "--output-format", "stream-json", "--verbose",
         "--allowedTools", request.allowedTools.joined(separator: ","),
         "--permission-mode", "dontAsk",
         "--max-turns", String(request.maxTurns),
         "--tools", request.allowedTools.map { String($0.prefix(while: { $0 != "(" })) }.joined(separator: ","),
         "--json-schema", outputSchema(for: request.step),
         "--append-system-prompt", systemPrompt,
         "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
            + [("--model", request.model), ("--effort", request.effort)].flatMap { flag, value in
                value.flatMap { isAgentValue($0) ? [flag, $0] : nil } ?? []
            }
    }

    public func start(_ request: AgentRequest) async throws -> ProcessReference {
        guard request.maxTurns > 0, request.timeout > 0,
              !request.allowedTools.isEmpty, request.allowedTools.allSatisfy({ !$0.isEmpty }) else {
            throw RunnerError.invalidConfiguration
        }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let token = UUID().uuidString
        let output = scratch.appendingPathComponent(token + ".stdout")
        let error = scratch.appendingPathComponent(token + ".stderr")
        let pid = try await supervisor.spawn(executable: executable, arguments: [executable.path] + Self.arguments(for: request),
                                             environment: environment, folder: request.folder, output: output, errorOutput: error)
        return ProcessReference(pid: pid, startTime: Self.startTime(of: pid) ?? 0, outputPath: output.path,
                                sessionID: request.sessionID, deadline: Date().addingTimeInterval(request.timeout))
    }

    /// Process start time (seconds since epoch) from the kernel, nil if the PID does not exist.
    static func startTime(of pid: Int32) -> Double? { ProcessSupervisor.startTime(of: pid) }

    /// New tool steps since the last call, read from the stream-json output file. Never throws; best effort.
    public func drainProgress(_ process: ProcessReference) async -> [ProgressEvent] {
        guard !process.outputPath.isEmpty else { return [] }
        var tail = tails[process.pid] ?? StreamTail()
        let events = tail.read(from: URL(fileURLWithPath: process.outputPath))
        tails[process.pid] = tail
        return events
    }

    public func wait(for process: ProcessReference) async throws -> AgentResult {
        let status: Int32?
        let output = URL(fileURLWithPath: process.outputPath)
        defer {
            tails[process.pid] = nil
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(atPath: process.outputPath.replacingOccurrences(of: ".stdout", with: ".stderr"))
        }
        status = try await supervisor.exitStatus(of: process)
        let data = (try? Data(contentsOf: output)) ?? Data()
        // An adopted process (runner restart) has no exit status; the result file decides.
        return try Self.parse(data, sessionID: process.sessionID, exitStatus: status ?? 0)
    }

    public func stop(_ process: ProcessReference) async { await supervisor.stop(process) }

    public func reconcile(_ process: ProcessReference) async -> ProcessObservation { await supervisor.reconcile(process) }

    public static func parse(_ data: Data, sessionID: UUID, exitStatus: Int32) throws -> AgentResult {
        struct Envelope: Decodable {
            var session_id: String
            var result: String?
            var is_error: Bool
            var structured_output: Structured?
            struct Structured: Decodable { var text: String?; var question: String?; var options: [String]?; var plan: String?; var verdict: String? }
        }
        // Plain `json` output is one object; `stream-json` is JSON lines whose last `result` line is the same object.
        let decoder = JSONDecoder()
        var decoded = try? decoder.decode(Envelope.self, from: data)
        if decoded == nil {
            for line in data.split(separator: 0x0A).reversed() {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["type"] as? String == "result" else { continue }
                decoded = try? decoder.decode(Envelope.self, from: line)
                break
            }
        }
        guard let envelope = decoded else { throw RunnerError.invalidResult }
        guard UUID(uuidString: envelope.session_id) == sessionID else { throw RunnerError.sessionMismatch }
        let question = envelope.structured_output?.question.flatMap { $0.isEmpty ? nil : $0 }
        return AgentResult(text: envelope.structured_output?.text ?? envelope.result ?? "", question: question,
                           options: question == nil ? [] : (envelope.structured_output?.options ?? []),
                           exitStatus: exitStatus, isError: envelope.is_error || exitStatus != 0,
                           plan: envelope.structured_output?.plan, verdict: envelope.structured_output?.verdict)
    }
}
