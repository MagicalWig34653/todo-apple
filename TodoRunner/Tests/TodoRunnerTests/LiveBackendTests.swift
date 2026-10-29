import Foundation
import Testing
@testable import TodoRunner

/// Real backend AND real `claude` CLI. Runs only with RUNNER_LIVE=1 and RUNNER_LIVE_BASE_URL (fresh isolated
/// stack from the main repository, bootstrap token still open, RUNNER_LIVE_BOOTSTRAP_TOKEN default dev-bootstrap-only).
/// Uses the local Claude login and costs tokens. Nothing is mocked except the person at the keyboard (REST calls).
actor LiveAdmin {
    static let shared = LiveAdmin()
    private var client: LiveBackend?
    func get() async throws -> LiveBackend {
        if let client { return client }
        let env = ProcessInfo.processInfo.environment
        let c = try await LiveBackend.register(baseURL: LiveBackend.fromEnvironment(),
                                               token: env["RUNNER_LIVE_BOOTSTRAP_TOKEN"] ?? "dev-bootstrap-only",
                                               displayName: "Runner E2E")
        client = c
        return c
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RUNNER_LIVE"] == "1" && LiveBackend.configured))
struct LiveBackendTests {
    var claude: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["TODO_RUNNER_CLAUDE"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path)
    }

    private func runner(_ w: LiveWorld) throws -> Runner {
        let provider = ClaudeProcessAdapter(executable: claude, scratch: w.fixture.directory.appendingPathComponent("out"))
        var settings = RunnerSettings(); settings.maxTurns = 8; settings.timeout = 240
        return try Runner(server: w.server, provider: provider, store: LocalStateStore(directory: w.fixture.state),
                          allowlist: w.fixture.allowlist, settings: settings)
    }

    private func events(_ detail: [String: Any]) -> [String] { (detail["events"] as! [[String: Any]]).map { $0["kind"] as! String } }

    @Test func implementJobSubmitsThenAcceptAndRequestChanges() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let w = try await LiveWorld.make(fixture: f, admin: try await LiveAdmin.shared.get())
        let sentence = "Live runner proof 4711."
        let (_, jobID) = try await w.release(
            title: "Create proof file", mode: .implement,
            scope: "Create a file named proof.txt in the working directory containing exactly this sentence and nothing else: \(sentence) Do not ask questions.")
        let r = try runner(w)
        #expect(await eventually(r, timeout: 240) { (try? await w.jobState(jobID)) == "awaiting_review" })
        let detail = try await w.jobDetail(jobID)
        let kinds = events(detail)
        #expect(kinds.contains("checkpoint") && kinds.contains("submit"), "events: \(kinds)")
        let job = detail["job"] as! [String: Any]
        let result = job["result"] as? [String: Any]
        #expect((result?["summary"] as? String)?.isEmpty == false)
        let written = try String(contentsOf: f.repo.appendingPathComponent("proof.txt"), encoding: .utf8)
        #expect(written.contains("Live runner proof 4711"))
        #expect(await r.snapshot().first?.phase == .closed)
        #expect(try await w.server.runs().isEmpty)  // seat is free again
        #expect(job["progress"] is String)

        let accepted = try await w.human.call("POST", "/v1/agents/jobs/\(jobID)/review", ["decision": "accept"])
        #expect(accepted["state"] as? String == "succeeded")

        // Second job on the same folder: request_changes path.
        let (_, second) = try await w.release(title: "Second proof", mode: .implement,
                                              scope: "Create a file named second.txt containing exactly: two. Do not ask questions.")
        #expect(await eventually(r, timeout: 240) { (try? await w.jobState(second)) == "awaiting_review" })
        let changes = try await w.human.call("POST", "/v1/agents/jobs/\(second)/review", ["decision": "request_changes"])
        #expect(changes["state"] as? String == "failed")
        #expect(events(try await w.jobDetail(second)).contains("request_changes"))
    }

    @Test func questionIsPostedAnsweredByHumanAndResumedWithSameSession() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let w = try await LiveWorld.make(fixture: f, admin: try await LiveAdmin.shared.get())
        let (_, jobID) = try await w.release(
            title: "Write the favourite colour", mode: .implement,
            scope: "Create color.txt containing the favourite colour of the person who requested this task. You do NOT know it and must not guess. Before creating any file, put exactly one question in the question field offering the options red, green and blue, and stop. After the answer arrives, create color.txt containing only that colour.")
        let r = try runner(w)
        #expect(await eventually(r, timeout: 240) { (try? await w.jobState(jobID)) == "waiting_for_answer" })
        let asked = try await w.jobDetail(jobID)
        let questions = asked["questions"] as! [[String: Any]]
        #expect(questions.count == 1)
        #expect(!FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("color.txt").path))
        let session = await r.snapshot().first?.sessionID
        #expect(await r.snapshot().first?.phase == .waitingForAnswer)
        // Heartbeats keep the seat during the pause; answering alone does not start anything.
        try await w.human.call("POST", "/v1/agents/questions/\(questions[0]["id"] as! String)/answer", ["value": "green"])
        #expect(await eventually(r, timeout: 240) { (try? await w.jobState(jobID)) == "awaiting_review" })
        let done = try await w.jobDetail(jobID)
        #expect(events(done).contains("question") || events(done).contains("answer"), "events: \(events(done))")
        #expect(await r.snapshot().first?.sessionID == session)
        let written = try String(contentsOf: f.repo.appendingPathComponent("color.txt"), encoding: .utf8)
        #expect(written.lowercased().contains("green"))
        let accepted = try await w.human.call("POST", "/v1/agents/jobs/\(jobID)/review", ["decision": "accept"])
        #expect(accepted["state"] as? String == "succeeded")
    }
}
