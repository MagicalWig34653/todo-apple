import Foundation
import Testing
@testable import TodoRunner

/// Real `claude` CLI. Only runs with RUNNER_LIVE=1 (uses the user's Claude login and costs tokens).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RUNNER_LIVE"] == "1")) struct LiveClaudeTests {
    var claude: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["TODO_RUNNER_CLAUDE"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path)
    }

    @Test func runnerReadsFileThroughRealClaudeAndSubmits() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try "The secret word is PELICAN.\n".write(to: f.repo.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let key = try f.allowlist.approve(folder: f.repo)
        let binding = Binding(repositoryKey: key, label: "Live")
        let server = FakeServer()
        var job = makeJob(binding: binding, mode: .clarify)
        job.scope = "Read note.txt and report the secret word. Do not ask questions."
        await server.add(job: job, binding: binding)
        let provider = ClaudeProcessAdapter(executable: claude, scratch: f.directory.appendingPathComponent("out"))
        var settings = RunnerSettings(); settings.maxTurns = 6; settings.timeout = 180
        let runner = try Runner(server: server, provider: provider, store: LocalStateStore(directory: f.state), allowlist: f.allowlist, settings: settings)
        try await runner.tick()
        #expect(await eventually(runner, timeout: 200) { await server.count("submit") == 1 })
        #expect(await server.submitted.first?.summary.uppercased().contains("PELICAN") == true)
        #expect(await runner.snapshot().first?.phase == .closed)
    }

    @Test func sessionIsResumedByUUIDAndKeepsContext() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let session = UUID()
        let provider = ClaudeProcessAdapter(executable: claude, scratch: f.directory.appendingPathComponent("out"))
        let first = try await provider.start(AgentRequest(sessionID: session, folder: f.repo, prompt: "Remember the number 4711. Reply only with OK.", allowedTools: ["Read"], maxTurns: 8, timeout: 120))
        let a = try await provider.wait(for: first)
        #expect(!a.isError)
        let second = try await provider.start(AgentRequest(sessionID: session, folder: f.repo, prompt: "Which number did I ask you to remember? Reply with the number only.", resume: true, allowedTools: ["Read"], maxTurns: 8, timeout: 120))
        let b = try await provider.wait(for: second)
        #expect(!b.isError && b.text.contains("4711"))
    }
}
