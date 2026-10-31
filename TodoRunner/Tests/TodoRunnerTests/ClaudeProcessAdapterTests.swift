import Foundation
import Darwin
import Testing
@testable import TodoRunner

@Suite(.serialized) struct ClaudeProcessAdapterTests {
    func script(_ f: Fixture, _ body: String) throws -> URL {
        let url = f.directory.appendingPathComponent("agent-\(UUID().uuidString).sh")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    @Test func parsesStructuredOutputQuestionAndFencesSession() throws {
        let session = UUID()
        let data = Data(#"{"session_id":"\#(session.uuidString.lowercased())","is_error":false,"result":"x","structured_output":{"text":"T","question":"Choose?","options":["a","b"]}}"#.utf8)
        let result = try ClaudeProcessAdapter.parse(data, sessionID: session, exitStatus: 0)
        #expect(result.text == "T" && result.question == "Choose?" && result.options == ["a", "b"] && !result.isError)
        #expect(try ClaudeProcessAdapter.parse(data, sessionID: session, exitStatus: 3).isError)
        #expect(throws: RunnerError.sessionMismatch) { try ClaudeProcessAdapter.parse(data, sessionID: UUID(), exitStatus: 0) }
        #expect(throws: RunnerError.invalidResult) { try ClaudeProcessAdapter.parse(Data("bad".utf8), sessionID: session, exitStatus: 0) }
    }

    @Test func argumentsMatchAdr0004() {
        let id = UUID()
        let fresh = ClaudeProcessAdapter.arguments(for: AgentRequest(sessionID: id, folder: URL(fileURLWithPath: "/"), prompt: "P", allowedTools: ["Read", "Bash(git status)"], maxTurns: 7))
        #expect(fresh.starts(with: ["-p", "P", "--session-id", id.uuidString.lowercased(), "--output-format", "stream-json", "--verbose"]))
        #expect(fresh.contains("--resume") == false)
        func value(_ flag: String, _ a: [String]) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
        #expect(value("--allowedTools", fresh) == "Read,Bash(git status)" && value("--tools", fresh) == "Read,Bash")
        #expect(value("--permission-mode", fresh) == "dontAsk" && value("--max-turns", fresh) == "7")
        let resumed = ClaudeProcessAdapter.arguments(for: AgentRequest(sessionID: id, folder: URL(fileURLWithPath: "/"), prompt: "P", resume: true))
        #expect(value("--resume", resumed) == id.uuidString.lowercased() && !resumed.contains("--session-id"))
    }

    @Test func runsInFolderAndReportsExitStatus() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let session = UUID()
        let exe = try script(f, """
        pwd > working-directory
        printf '%s' '{"session_id":"\(session.uuidString.lowercased())","is_error":false,"structured_output":{"text":"Done"}}'
        exit 4
        """)
        let provider = ClaudeProcessAdapter(executable: exe, scratch: f.directory.appendingPathComponent("out"))
        let process = try await provider.start(AgentRequest(sessionID: session, folder: f.repo, prompt: "x"))
        #expect(getpgid(process.pid) == process.pid)                                   // own process group
        let result = try await provider.wait(for: process)
        #expect(result.exitStatus == 4 && result.isError && result.text == "Done")
        let cwd = try String(contentsOf: f.repo.appendingPathComponent("working-directory"), encoding: .utf8)
        #expect(URL(fileURLWithPath: cwd.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path == f.repo.resolvingSymlinksInPath().path)
        #expect(await provider.reconcile(process) == .exited)
    }

    @Test func timeoutKillsWholeProcessGroup() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let exe = try script(f, "/bin/sleep 60 &\necho $! > child.pid\nwait\n")
        let provider = ClaudeProcessAdapter(executable: exe, scratch: f.directory.appendingPathComponent("out"))
        let process = try await provider.start(AgentRequest(sessionID: UUID(), folder: f.repo, prompt: "x", timeout: 0.6))
        await #expect(throws: RunnerError.timedOut) { try await provider.wait(for: process) }
        let child = try #require(Int32(String(contentsOf: f.repo.appendingPathComponent("child.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(kill(child, 0) == -1 && errno == ESRCH)                                // tool subprocess is gone too
    }

    @Test func stopKillsGroupAndWaitThrowsStopped() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let exe = try script(f, "/bin/sleep 60 &\nwait\n")
        let provider = ClaudeProcessAdapter(executable: exe, scratch: f.directory.appendingPathComponent("out"))
        let process = try await provider.start(AgentRequest(sessionID: UUID(), folder: f.repo, prompt: "x"))
        #expect(await provider.reconcile(process) == .running)
        let waiter = Task { try await provider.wait(for: process) }
        try await Task.sleep(for: .milliseconds(100))
        await provider.stop(process)
        await #expect(throws: RunnerError.stopped) { try await waiter.value }
        #expect(kill(process.pid, 0) == -1 && errno == ESRCH)
    }

    @Test func staleOrReusedPidIsNeverSignalled() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let provider = ClaudeProcessAdapter(executable: URL(fileURLWithPath: "/bin/echo"), scratch: f.directory)
        // Our own PID with a wrong start time simulates PID reuse.
        let fake = ProcessReference(pid: getpid(), startTime: 12345, outputPath: "")
        #expect(await provider.reconcile(fake) == .exited)
        await provider.stop(fake)                                                      // must not kill the test process
    }

    @Test func waitAdoptsOrphanedProcessAfterRunnerRestart() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let session = UUID()
        let out = f.directory.appendingPathComponent("orphan.stdout")
        // Double fork via the shell: the agent is re-parented like after a runner crash.
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "(sleep 0.5; printf '%s' '{\"session_id\":\"\(session.uuidString.lowercased())\",\"is_error\":false,\"result\":\"late\"}' > '\(out.path)') >/dev/null 2>&1 & echo $!"]
        let pipe = Pipe(); sh.standardOutput = pipe
        try sh.run(); sh.waitUntilExit()
        let pid = try #require(Int32(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let ref = ProcessReference(pid: pid, startTime: ClaudeProcessAdapter.startTime(of: pid) ?? 0, outputPath: out.path, sessionID: session)
        let provider = ClaudeProcessAdapter(executable: URL(fileURLWithPath: "/bin/echo"), scratch: f.directory)
        #expect(await provider.reconcile(ref) == .running)
        let result = try await provider.wait(for: ref)
        #expect(result.text == "late" && !result.isError)
    }
}
