import Foundation
import Darwin
import Testing
@testable import TodoRunner

@Test func parsesClaudeJSONAndFencesSessionIdentity() throws {
    let session = UUID()
    let data = Data("{\"session_id\":\"\(session)\",\"is_error\":false,\"result\":\"Done\",\"structured_output\":{\"question\":\"Choose?\"}}".utf8)
    let result = try ClaudeProcessAdapter.parse(data, sessionID: session, exitStatus: 7)
    #expect(result.exitStatus == 7 && result.isError && result.question == "Choose?")
    #expect(throws: RunnerError.self) { try ClaudeProcessAdapter.parse(data, sessionID: UUID(), exitStatus: 0) }
    #expect(throws: (any Error).self) { try ClaudeProcessAdapter.parse(Data("bad".utf8), sessionID: session, exitStatus: 0) }
}

@Test func processArgumentsFolderAndExitStatus() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let session = UUID()
    let executable = f.directory.appendingPathComponent("agent.sh")
    let script = """
    #!/bin/sh
    pwd > working-directory
    printf '%s\\n' "$@" > arguments
    printf '%s' '{"session_id":"\(session)","is_error":false,"result":"Done"}'
    exit 4
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let provider = ClaudeProcessAdapter(executable: executable, scratch: f.directory)
    let process = try await provider.start(AgentRequest(sessionID: session, folder: f.directory, prompt: "Read file", resume: true))
    let result = try await provider.wait(for: process)
    #expect(result.exitStatus == 4 && result.isError)
    let arguments = try String(contentsOf: f.directory.appendingPathComponent("arguments"), encoding: .utf8)
    #expect(arguments.contains("--resume\n\(session.uuidString.lowercased())"))
    #expect(arguments.contains("--permission-mode\ndontAsk") && arguments.contains("--allowedTools\nRead"))
    #expect(arguments.contains("--max-turns\n5") && arguments.contains("--output-format\njson"))
    let folder = try String(contentsOf: f.directory.appendingPathComponent("working-directory"), encoding: .utf8)
    #expect(URL(fileURLWithPath: folder.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath() == f.directory)
}

@Test func timeoutAndStopKillProcessGroupAndReap() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let executable = f.directory.appendingPathComponent("sleep.sh")
    try Data("#!/bin/sh\n/bin/sleep 60 &\nwait\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let provider = ClaudeProcessAdapter(executable: executable, scratch: f.directory)
    let timed = try await provider.start(AgentRequest(sessionID: UUID(), folder: f.directory, prompt: "x", timeout: 0.1))
    #expect(getpgid(timed.pid) == timed.pid)
    await #expect(throws: RunnerError.self) { try await provider.wait(for: timed) }
    #expect(kill(timed.pid, 0) == -1 && errno == ESRCH)
    let stopped = try await provider.start(AgentRequest(sessionID: UUID(), folder: f.directory, prompt: "x"))
    await provider.stop(stopped)
    await #expect(throws: RunnerError.self) { try await provider.wait(for: stopped) }
    #expect(kill(stopped.pid, 0) == -1 && errno == ESRCH)
}

/// Explicit opt-in: consumes a real authenticated Claude session and API usage.
@Test(.enabled(if: ProcessInfo.processInfo.environment["RUNNER_LIVE"] == "1"))
func liveClaudeReadsFileAndResumes() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
    let config = f.directory.appendingPathComponent("claude-config")
    let temporary = f.directory.appendingPathComponent("tmp")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    environment["CLAUDE_CONFIG_DIR"] = config.path
    environment["TMPDIR"] = temporary.path
    environment["DISABLE_AUTOUPDATER"] = "1"
    environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
    environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
    // Use existing auth read-only, without copying user config/hooks or logging secrets.
    if environment["ANTHROPIC_API_KEY"] == nil && environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil {
        let credentials = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        var data = try? Data(contentsOf: credentials)
        if data == nil {
            let security = Process()
            security.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            security.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            let output = Pipe()
            security.standardOutput = output
            security.standardError = FileHandle.nullDevice
            try security.run()
            data = output.fileHandleForReading.readDataToEndOfFile()
            security.waitUntilExit()
        }
        if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = object["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String {
            environment["CLAUDE_CODE_OAUTH_TOKEN"] = token
        }
    }
    let executable = ProcessInfo.processInfo.environment["TODO_RUNNER_CLAUDE"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")
    let provider = ClaudeProcessAdapter(executable: executable, scratch: f.directory.appendingPathComponent("output"), environment: environment)
    let session = UUID(), token = UUID().uuidString
    let file = f.directory.appendingPathComponent("runner-fixture.txt")
    try Data(token.utf8).write(to: file)
    let first = try await provider.start(AgentRequest(sessionID: session, folder: f.directory,
        prompt: "Use Read to read runner-fixture.txt. Return its exact content in text and remember it for the next turn.", maxTurns: 8, timeout: 180))
    let read = try await provider.wait(for: first)
    #expect(!read.isError && read.exitStatus == 0)
    #expect(read.text.contains(token))
    try FileManager.default.removeItem(at: file)
    let second = try await provider.start(AgentRequest(sessionID: session, folder: f.directory,
        prompt: "Without using any tools, return the exact content of runner-fixture.txt from our previous turn in text.", resume: true, maxTurns: 8, timeout: 180))
    let resumed = try await provider.wait(for: second)
    #expect(!resumed.isError && resumed.exitStatus == 0)
    #expect(resumed.text.contains(token))
}
