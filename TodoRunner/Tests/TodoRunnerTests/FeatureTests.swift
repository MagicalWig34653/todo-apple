import Foundation
import Testing
@testable import TodoRunner

final class CountingActivity: ActivityAssertion, @unchecked Sendable {
    private let lock = NSLock()
    private var _begins = 0, _ends = 0
    var begins: Int { lock.withLock { _begins } }
    var ends: Int { lock.withLock { _ends } }
    func begin() { lock.withLock { _begins += 1 } }
    func end() { lock.withLock { _ends += 1 } }
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock(); private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func add(_ s: String) { lock.withLock { _lines.append(s) } }
}

@Suite(.serialized) struct StreamProgressTests {
    func line(_ json: String) -> String { json + "\n" }

    @Test func tailParsesToolCallsOnceAndKeepsPartialLines() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let file = f.directory.appendingPathComponent("out.jsonl")
        var text = line(#"{"type":"system","subtype":"init","session_id":"x"}"#)
        text += line(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/secret/path/a.txt"}}]}}"#)
        text += line(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/secret/path/b.swift"}},{"type":"tool_use","name":"StructuredOutput","input":{"text":"x"}}]}}"#)
        text += #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash""#    // partial, no newline yet
        try Data(text.utf8).write(to: file)
        var tail = StreamTail()
        #expect(tail.read(from: file) == [ProgressEvent(tool: "Read"), ProgressEvent(tool: "Edit", file: "b.swift")])
        #expect(tail.read(from: file).isEmpty)                                          // nothing is read twice
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data(#","input":{"command":"ls"}}]}}"#.utf8 + [10])); try handle.close()
        #expect(tail.read(from: file) == [ProgressEvent(tool: "Bash")])
    }

    @Test func aggregateRendersShortGermanSummaryWithoutPaths() {
        var aggregate = ProgressAggregator()
        #expect(aggregate.isEmpty)
        aggregate.add([ProgressEvent(tool: "Read"), ProgressEvent(tool: "Read"), ProgressEvent(tool: "Grep"),
                       ProgressEvent(tool: "Edit", file: "a.swift"), ProgressEvent(tool: "Bash"), ProgressEvent(tool: "WebFetch")])
        let text = aggregate.render()
        #expect(text == "Agent arbeitet: 2 Dateien gelesen, 1 Suche, 1 Änderung (a.swift), 1 Befehl, 1 weiterer Schritt")
        #expect(!text.contains("/"))
    }

    @Test func parsesStreamJsonResultLine() throws {
        let session = UUID()
        let data = Data((#"{"type":"system","session_id":"\#(session.uuidString.lowercased())"}"# + "\n"
            + #"{"type":"result","subtype":"success","session_id":"\#(session.uuidString.lowercased())","is_error":false,"result":"r","structured_output":{"text":"T"}}"# + "\n").utf8)
        let result = try ClaudeProcessAdapter.parse(data, sessionID: session, exitStatus: 0)
        #expect(result.text == "T" && !result.isError)
        #expect(throws: RunnerError.invalidResult) { try ClaudeProcessAdapter.parse(Data(#"{"type":"system"}"#.utf8), sessionID: session, exitStatus: 0) }
    }

    @Test func adapterStreamsProgressFromRealOutputFile() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let session = UUID()
        let script = f.directory.appendingPathComponent("agent.sh")
        try Data("""
        #!/bin/sh
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","input":{}}]}}'
        sleep 0.5
        printf '%s\\n' '{"type":"result","session_id":"\(session.uuidString.lowercased())","is_error":false,"structured_output":{"text":"ok"}}'
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let provider = ClaudeProcessAdapter(executable: script, scratch: f.directory.appendingPathComponent("out"))
        let process = try await provider.start(AgentRequest(sessionID: session, folder: f.repo, prompt: "x"))
        var seen: [ProgressEvent] = []
        for _ in 0..<40 where seen.isEmpty { try await Task.sleep(for: .milliseconds(50)); seen += await provider.drainProgress(process) }
        #expect(seen == [ProgressEvent(tool: "Grep")])
        #expect(try await provider.wait(for: process).text == "ok")
    }
}

@Suite(.serialized) struct RunnerFeatureTests {
    func setup() async throws -> (Fixture, FakeServer, FakeProvider) {
        let f = try Fixture()
        let key = try f.allowlist.approve(folder: f.repo)
        let binding = Binding(repositoryKey: key, label: "Repo")
        let server = FakeServer(); let provider = FakeProvider()
        await server.add(job: makeJob(binding: binding), binding: binding)
        return (f, server, provider)
    }

    @Test func progressIsSummarisedAndThrottled() async throws {
        let (f, server, provider) = try await setup(); defer { f.cleanup() }
        var settings = RunnerSettings(); settings.progressInterval = 0
        let runner = try makeRunner(f, server: server, provider: provider, settings: settings)
        try await runner.tick()
        await provider.queue([ProgressEvent(tool: "Read"), ProgressEvent(tool: "Read")])
        try await runner.tick()
        await provider.queue([ProgressEvent(tool: "Edit", file: "x.swift")])
        try await runner.tick()
        let texts = await server.progressTexts
        #expect(texts == ["Agent started.", "Agent arbeitet: 2 Dateien gelesen", "Agent arbeitet: 1 Änderung (x.swift)"])

        // With a long interval nothing is sent in between, and the events are kept for later.
        let (f2, server2, provider2) = try await setup(); defer { f2.cleanup() }
        var slow = RunnerSettings(); slow.progressInterval = 3600
        let second = try makeRunner(f2, server: server2, provider: provider2, settings: slow)
        try await second.tick()
        await provider2.queue([ProgressEvent(tool: "Read")])
        try await second.tick()
        #expect(await server2.progressTexts == ["Agent started."])
    }

    @Test func progressLossOfOwnershipFencesTheRun() async throws {
        let (f, server, provider) = try await setup(); defer { f.cleanup() }
        var settings = RunnerSettings(); settings.progressInterval = 0
        let runner = try makeRunner(f, server: server, provider: provider, settings: settings)
        try await runner.tick()
        await server.set(writeError: .conflict("stale generation"), for: "progress")
        await provider.queue([ProgressEvent(tool: "Read")])
        try await runner.tick()
        let phase = await runner.snapshot().first?.phase
        #expect(phase == .leaseLost || phase == .closed)
        #expect(await provider.stopped.count == 1)
    }

    @Test func activityAssertionHeldOnlyWhileAgentRuns() async throws {
        let (f, server, provider) = try await setup(); defer { f.cleanup() }
        let activity = CountingActivity()
        var settings = RunnerSettings(); settings.activity = activity
        let runner = try makeRunner(f, server: server, provider: provider, settings: settings)
        try await runner.tick()
        #expect(activity.begins == 1 && activity.ends == 0)
        await provider.finish(await provider.lastPID(), AgentResult(text: "Done"))
        #expect(await eventually(runner) { activity.ends == 1 })
        #expect(activity.begins == 1)
    }

    @Test func wakeRecoveryReadoptsExpiredLeaseOfLiveProcess() async throws {
        let (f, server, provider) = try await setup(); defer { f.cleanup() }
        let clock = Clock(); let log = LogBox()
        var settings = RunnerSettings(); settings.now = { clock.now }; settings.log = { log.add($0) }
        let runner = try makeRunner(f, server: server, provider: provider, settings: settings)
        try await runner.tick()
        await server.set(lease: 1000)
        clock.advance(200)                                          // the Mac slept past the 90 s lease
        await runner.noteWake()
        try await runner.tick()
        #expect(await runner.snapshot().first?.phase == .running)
        #expect(await server.count("reconcile alive") == 1)
        #expect(await provider.stopped.isEmpty)
        #expect(await runner.snapshot().first?.note.contains("aufgewacht") == true)
        #expect(log.lines.contains { $0.contains("Aufwachen") })
    }

    @Test func wakeRecoveryRetriesWhileNetworkIsDownThenMarksRunInterrupted() async throws {
        let (f, server, provider) = try await setup(); defer { f.cleanup() }
        let clock = Clock()
        var settings = RunnerSettings(); settings.now = { clock.now }; settings.wakeGrace = 60
        let runner = try makeRunner(f, server: server, provider: provider, settings: settings)
        try await runner.tick()
        clock.advance(200)
        await runner.noteWake()
        await server.set(writeError: .transport("network down"), for: "reconcile")
        try await runner.tick()
        #expect(await runner.snapshot().first?.phase == .running)   // still waiting for the network
        clock.advance(120)                                          // grace over
        try await runner.tick()
        let run = try #require(await runner.snapshot().first)
        #expect(run.phase == .leaseLost && run.note.contains("Interrupted by sleep"))
        #expect(await provider.stopped.count == 1)
    }

    @Test func wakeRefusedByServerFencesRunInsteadOfHanging() async throws {
        let (f, server, provider) = try await setup(); defer { f.cleanup() }
        let clock = Clock()
        var settings = RunnerSettings(); settings.now = { clock.now }
        let runner = try makeRunner(f, server: server, provider: provider, settings: settings)
        try await runner.tick()
        clock.advance(200)
        await runner.noteWake()
        await server.set(writeError: .gone("run_ended"), for: "reconcile")
        try await runner.tick()
        let run = try #require(await runner.snapshot().first)
        #expect(run.phase == .leaseLost || run.phase == .closed)           // closed: server already settled the run
        #expect(run.note.contains("Interrupted by sleep"))
        #expect(await provider.stopped.count == 1)
        #expect(await server.count("submit") == 0)
    }

    @Test func sleepIsDetectedFromClockGap() {
        #expect(Runner.sleptDuring(wall: .seconds(3600), awake: .seconds(15)))
        #expect(!Runner.sleptDuring(wall: .seconds(15), awake: .seconds(15)))
        #expect(!Runner.sleptDuring(wall: .seconds(18), awake: .seconds(15)))
    }

    @Test func runOnceWorksExactlyOneJobAndStops() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let key = try f.allowlist.approve(folder: f.repo)
        let binding = Binding(repositoryKey: key, label: "Repo")
        let server = FakeServer(); let provider = FakeProvider()
        await server.add(job: makeJob(binding: binding), binding: binding)
        await server.add(job: makeJob(binding: binding), binding: binding)
        let runner = try makeRunner(f, server: server, provider: provider)
        let finisher = Task {
            while await provider.requests.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
            await provider.finish(await provider.lastPID(), AgentResult(text: "Done"))
        }
        let runs = try await runner.runOnce(interval: .milliseconds(20), maxDuration: 10)
        await finisher.value
        #expect(runs.count == 1 && runs.first?.phase == .closed)
        #expect(await server.count("claim") == 1)
        #expect(await server.count("submit") == 1)
    }

    @Test func runOnceWithEmptyQueueReturnsImmediately() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let runner = try makeRunner(f, server: FakeServer(), provider: FakeProvider())
        #expect(try await runner.runOnce(interval: .milliseconds(10), maxDuration: 5).isEmpty)
    }

    @Test func promptPointsToManualWhenMcpIsAvailable() {
        let job = makeJob(binding: Binding(repositoryKey: UUID(), label: "x"))
        let detail = JobDetail(job: job, task: TaskInfo(title: "T"))
        #expect(Runner.prompt(for: detail, answers: []).contains("get_manual"))
        #expect(ClaudeProcessAdapter.systemPrompt.contains("get_manual"))
    }
}

@Suite(.serialized) struct SecretsAndLogTests {
    @Test func tokenLivesInSecretStoreNotInConfigFile() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.state, withIntermediateDirectories: true)
        let secrets = MemorySecretStore()
        let config = RunnerConfig(baseURL: URL(string: "https://todo.example")!, deviceID: UUID(), token: "tok-very-secret-123")
        try config.save(to: f.state, secrets: secrets)
        let file = try String(contentsOf: f.state.appendingPathComponent("config.json"), encoding: .utf8)
        #expect(!file.contains("tok-very-secret-123") && !file.contains("token"))
        #expect(try RunnerConfig.load(from: f.state, secrets: secrets) == config)
        #expect(throws: RunnerError.missingToken) { try RunnerConfig.load(from: f.state, secrets: MemorySecretStore()) }
    }

    @Test func legacyPlaintextTokenIsMigratedAndRemovedFromFile() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.state, withIntermediateDirectories: true)
        let id = UUID()
        try Data(#"{"baseURL":"https://todo.example","deviceID":"\#(id.uuidString)","token":"legacy-token-1"}"#.utf8)
            .write(to: f.state.appendingPathComponent("config.json"))
        let secrets = MemorySecretStore()
        let config = try RunnerConfig.load(from: f.state, secrets: secrets)
        #expect(config.token == "legacy-token-1")
        #expect(!(try String(contentsOf: f.state.appendingPathComponent("config.json"), encoding: .utf8)).contains("legacy-token-1"))
        #expect(try secrets.read(account: RunnerConfig.account(id)) == "legacy-token-1")
    }

    @Test func fileSecretStoreUsesOwnerOnlyPermissions() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.state, withIntermediateDirectories: true)
        let store = FileSecretStore(directory: f.state)
        try store.write("abc123456", account: "a")
        #expect(try store.read(account: "a") == "abc123456")
        let mode = try FileManager.default.attributesOfItem(atPath: f.state.appendingPathComponent("secret-a").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try store.delete(account: "a")
        #expect(try store.read(account: "a") == nil)
    }

    @Test func realKeychainRoundTrip() throws {
        let store = KeychainSecretStore(service: "de.todo.runner.test.\(UUID().uuidString)")
        do {
            try store.write("kc-secret-1", account: "t")
            #expect(try store.read(account: "t") == "kc-secret-1")
            try store.write("kc-secret-2", account: "t")
            #expect(try store.read(account: "t") == "kc-secret-2")
            try store.delete(account: "t")
            #expect(try store.read(account: "t") == nil)
        } catch SecretStoreError.keychain(let status) {
            Issue.record("Keychain not usable in this environment (status \(status))")
        }
    }

    @Test func logRedactsTokenAndBearerAndRotates() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let log = RunnerLogFile(directory: f.state, redactor: Redactor(secrets: ["tok-very-secret-123"]), maxBytes: 200)
        log.append("Fehler mit tok-very-secret-123 und Authorization: Bearer abc.DEF-ghi")
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(!text.contains("tok-very-secret-123") && !text.contains("abc.DEF-ghi") && text.contains("[geheim]"))
        for i in 0..<10 { log.append("Zeile \(i) mit etwas Fuelltext, damit rotiert wird") }
        #expect(FileManager.default.fileExists(atPath: log.url.deletingLastPathComponent().appendingPathComponent("runner.log.1").path))
        #expect(log.tail(2).count == 2 && log.tail(1).first?.contains("Zeile 9") == true)
        let mode = try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}

@Suite(.serialized) struct CLITests {
    final class Output: @unchecked Sendable {
        private let lock = NSLock(); private var _out: [String] = [], _err: [String] = []
        var out: String { lock.withLock { _out.joined(separator: "\n") } }
        var err: String { lock.withLock { _err.joined(separator: "\n") } }
        func addOut(_ s: String) { lock.withLock { _out.append(s) } }
        func addErr(_ s: String) { lock.withLock { _err.append(s) } }
    }

    func context(_ f: Fixture, _ output: Output, server: FakeServer = FakeServer(), provider: FakeProvider = FakeProvider(),
                 secrets: MemorySecretStore = MemorySecretStore(), claude: URL? = nil, version: String? = "2.1.314 (Claude Code)") -> CLIContext {
        CLIContext(directory: f.state, secrets: secrets, claudeExecutable: claude ?? URL(fileURLWithPath: "/bin/sh"),
                   executablePath: "/usr/local/bin/todo-runner", environment: ["TODO_RUNNER_HOME": f.state.path],
                   interval: .milliseconds(20),
                   makeServer: { _, _ in server }, makeProvider: { _ in provider },
                   pair: { _, code in
                       guard code == "GOOD-CODE" else { throw RunnerServerError.notFound }
                       return DeviceToken(deviceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, token: "device-token-secret")
                   },
                   probe: { _, _ in version },
                   out: { output.addOut($0) }, err: { output.addErr($0) })
    }

    @Test func pairStoresTokenInSecretStoreAndRejectsBadCode() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let output = Output(), secrets = MemorySecretStore()
        let cli = RunnerCLI(context: context(f, output, secrets: secrets))
        #expect(try await cli.execute(["pair", "https://todo.example", "GOOD-CODE"]) == 0)
        #expect(!output.out.contains("device-token-secret") && output.out.contains("Gekoppelt"))
        #expect(try secrets.read(account: RunnerConfig.account(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)) == "device-token-secret")
        await #expect(throws: RunnerServerError.notFound) { try await cli.execute(["pair", "https://todo.example", "BAD"]) }
        await #expect(throws: RunnerError.invalidConfiguration) { try await cli.execute(["pair", "not-a-url", "x"]) }
        #expect(RunnerCLI.describe(RunnerServerError.notFound).contains("Code"))
    }

    @Test func statusShowsPairingAndRunsInGerman() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let output = Output()
        let cli = RunnerCLI(context: context(f, output))
        _ = try await cli.execute(["status"])
        #expect(output.out.contains("Nicht gekoppelt"))
        _ = try await cli.execute(["pair", "https://todo.example", "GOOD-CODE"])
        _ = try await cli.execute(["approve", f.repo.path])
        _ = try await cli.execute(["status"])
        #expect(output.out.contains("Gekoppelt mit https://todo.example") && output.out.contains("Freigegebene Ordner: 1"))
        _ = try await cli.execute(["status", "--json"])
        #expect(output.out.contains("[") )
    }

    @Test func doctorReportsErrorsAndSucceedsWhenEverythingIsSetUp() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let output = Output(), server = FakeServer()
        let missing = RunnerCLI(context: context(f, output, claude: URL(fileURLWithPath: "/nonexistent/claude")))
        #expect(try await missing.execute(["doctor"]) == 1)
        #expect(output.out.contains("[FEHLER] claude-CLI") && output.out.contains("[FEHLER] Kopplung"))

        let output2 = Output()
        let key = UUID()
        await server.add(job: Job(bindingID: UUID(), scope: "s", state: .succeeded), binding: Binding(repositoryKey: key, label: "Ohne Ordner"))
        let cli = RunnerCLI(context: context(f, output2, server: server))
        _ = try await cli.execute(["pair", "https://todo.example", "GOOD-CODE"])
        _ = try await cli.execute(["approve", f.repo.path])
        #expect(try await cli.execute(["doctor"]) == 0)
        #expect(output2.out.contains("[OK] claude-CLI: 2.1.314") && output2.out.contains("[OK] Server") && output2.out.contains("[OK] Ordner"))
        #expect(output2.out.contains("[WARNUNG] Binding: \"Ohne Ordner\""))
        #expect(!output2.out.contains("device-token-secret"))

        let output3 = Output()
        let broken = RunnerCLI(context: context(f, output3, server: server, version: nil))
        #expect(try await broken.execute(["doctor"]) == 1)
        #expect(output3.out.contains("liefert keine Antwort"))
    }

    @Test func launchdPlistIsGeneratedButNotInstalled() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let output = Output()
        let cli = RunnerCLI(context: context(f, output))
        #expect(try await cli.execute(["launchd-plist", "--label", "de.example.runner"]) == 0)
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(output.out.utf8), format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "de.example.runner")
        #expect(plist["ProgramArguments"] as? [String] == ["/usr/local/bin/todo-runner", "run"])
        #expect(plist["KeepAlive"] as? Bool == true && plist["RunAtLoad"] as? Bool == true)
        #expect((plist["EnvironmentVariables"] as? [String: String])?["TODO_RUNNER_HOME"] == f.state.path)
        #expect(output.err.contains("nichts installiert"))
        #expect(!FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/de.example.runner.plist"))
    }

    @Test func runOnceAndLogsEndToEndWithFakes() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let output = Output(), server = FakeServer(), provider = FakeProvider()
        let cli = RunnerCLI(context: context(f, output, server: server, provider: provider))
        _ = try await cli.execute(["pair", "https://todo.example", "GOOD-CODE"])
        let key = try f.allowlist.approve(folder: f.repo)
        let binding = Binding(repositoryKey: key, label: "Repo")
        await server.add(job: makeJob(binding: binding), binding: binding)
        let finisher = Task {
            while await provider.requests.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
            await provider.finish(await provider.lastPID(), AgentResult(text: "Done"))
        }
        #expect(try await cli.execute(["run-once"]) == 0)
        await finisher.value
        #expect(output.out.contains("beendet") && output.out.contains("repo"))
        _ = try await cli.execute(["logs", "-n", "5"])
        #expect(output.out.contains("[closed]") || output.out.contains("Lauf "))
        #expect(!output.out.contains("device-token-secret"))
    }
}
