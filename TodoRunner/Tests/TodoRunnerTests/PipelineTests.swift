import Foundation
import Darwin
import Testing
@testable import TodoRunner

/// One approved folder and binding, fake server and fake agent, REAL command executor and local command store.
struct PipelineWorld {
    let f: Fixture
    let server = FakeServer()
    let provider = FakeProvider()
    let binding: Binding
    let key: UUID
    var commands: LocalCommands { LocalCommands(directory: f.state) }

    init() throws {
        f = try Fixture()
        try FileManager.default.createDirectory(at: f.state, withIntermediateDirectories: true)
        key = try f.allowlist.approve(folder: f.repo)
        binding = Binding(repositoryKey: key, label: "Repo")
    }

    func runner(budgetTimeout: TimeInterval = 5, executor: any CommandExecutor = ProcessCommandExecutor()) throws -> Runner {
        var settings = RunnerSettings(); settings.budgetTimeout = budgetTimeout
        return try Runner(server: server, provider: provider, store: LocalStateStore(directory: f.state), allowlist: f.allowlist,
                          settings: settings, executor: executor)
    }

    @discardableResult
    func queue(_ step: PipelineStep?, _ context: PipelineContext? = nil, on other: Binding? = nil) async -> Job {
        let target = other ?? binding
        let mode: JobMode = step == nil || step == .developer || step == .tester ? .implement : .clarify
        let job = Job(bindingID: target.id, mode: mode, scope: "Do it", pipelineStep: step,
                      pipelineExecutionID: step == nil ? nil : UUID())
        await server.add(job: job, binding: target)
        if let step { await server.set(pipeline: context ?? PipelineContext(step: step), for: job.id) }
        return job
    }

    func script(_ body: String, name: String = "cmd-\(UUID().uuidString).sh") throws -> String {
        let url = f.directory.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }

    func validation(_ body: String, timeout: TimeInterval = 30) throws {
        try commands.setValidation(LocalCommand(argv: [try script(body)], timeout: timeout), for: key)
    }

    func read(_ name: String) -> String {
        (try? String(contentsOf: f.repo.appendingPathComponent(name), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Runs the current agent process to its end and waits for the published step result.
    func finish(_ runner: Runner, _ result: AgentResult, submissions: Int = 1) async -> Bool {
        await provider.finish(await provider.lastPID(), result)
        return await eventually(runner) { await server.stepSubmissions.count == submissions }
    }
}

private func isGone(_ pid: Int32) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

/// Records what was durable at the moment of the spawn.
actor RecordingExecutor: CommandExecutor {
    private let inner = ProcessCommandExecutor()
    private let state: URL
    private(set) var phasesAtStart: [RunPhase] = []
    private(set) var starts = 0
    init(state: URL) { self.state = state }
    func start(_ request: CommandRequest) async throws -> ProcessReference {
        starts += 1
        phasesAtStart += (try LocalStateStore.readRuns(in: state)).map(\.phase)
        return try await inner.start(request)
    }
    func wait(for process: ProcessReference) async throws -> CommandResult { try await inner.wait(for: process) }
    func stop(_ process: ProcessReference) async { await inner.stop(process) }
    func reconcile(_ process: ProcessReference) async -> ProcessObservation { await inner.reconcile(process) }
}

@Suite(.serialized) struct PipelineAgentStepTests {
    @Test func plannerIsReadOnlyGetsPlanAndFeedbackAndSubmitsThePlan() async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        await w.queue(.planner, PipelineContext(step: .planner, planBody: "Old plan body", planVersion: 1, feedback: "Please add tests"))
        let r = try w.runner()
        try await r.tick()
        let request = try #require(await w.provider.requests.first)
        #expect(request.step == .planner && !request.resume)
        #expect(request.allowedTools == ["Read", "Glob", "Grep"])
        #expect(request.prompt.contains("Old plan body") && request.prompt.contains("Please add tests") && request.prompt.contains("`plan`"))
        #expect(await w.finish(r, AgentResult(text: "Plan ready.", plan: "# Plan\n- step")))
        let sent = try #require(await w.server.stepSubmissions.first)
        #expect(sent.outcome == .passed && sent.plan == "# Plan\n- step" && sent.result.summary == "Plan ready.")
        #expect(await w.server.count("submit g") == 0)
        #expect(await r.snapshot().first?.phase == .closed)
    }

    @Test(arguments: [nil, "   ", String(repeating: "p", count: 20001)])
    func plannerWithoutUsablePlanFails(plan: String?) async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        await w.queue(.planner)
        let r = try w.runner()
        try await r.tick()
        #expect(await w.finish(r, AgentResult(text: "Hm.", plan: plan)))
        let sent = try #require(await w.server.stepSubmissions.first)
        #expect(sent.outcome == .failed && sent.plan == nil && sent.result.summary.contains("Plan"))
    }

    @Test(arguments: [(PipelineStep.tester, "passed", PipelineOutcome.passed), (.tester, nil, .failed), (.tester, "failed", .failed),
                      (.review, "passed", .passed), (.review, "looks fine", .failed)] as [(PipelineStep, String?, PipelineOutcome)])
    func testerAndReviewNeedAPassingVerdictAndStartFresh(step: PipelineStep, verdict: String?, expected: PipelineOutcome) async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        await w.queue(step, PipelineContext(step: step, planBody: "The plan", resumeSessionReference: UUID().uuidString.lowercased()))
        let r = try w.runner()
        try await r.tick()
        let request = try #require(await w.provider.requests.first)
        #expect(!request.resume && request.step == step && request.prompt.contains("The plan") && request.prompt.contains("`verdict`"))
        #expect(request.allowedTools.contains("Edit") == (step == .tester))
        #expect(await w.finish(r, AgentResult(text: "Checked.", verdict: verdict)))
        #expect(await w.server.stepSubmissions.first?.outcome == expected)
        #expect(await w.server.stepSubmissions.first?.plan == nil)
    }

    @Test func developerResumesThePlannerSessionOnlyWhenKnownInThisFolder() async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        let r = try w.runner()
        await w.queue(.planner)
        try await r.tick()
        let planner = try #require(await w.provider.requests.last?.sessionID)
        #expect(await w.finish(r, AgentResult(text: "Plan.", plan: "Plan A")))
        let reference = planner.uuidString.lowercased()

        await w.queue(.developer, PipelineContext(step: .developer, planBody: "Plan A", resumeSessionReference: reference))
        try await r.tick()
        let resumed = try #require(await w.provider.requests.last)
        #expect(resumed.resume && resumed.sessionID == planner && resumed.allowedTools.contains("Edit") && resumed.prompt.contains("Plan A"))
        #expect(await w.finish(r, AgentResult(text: "Built."), submissions: 2))
        #expect(await w.server.stepSubmissions.last?.outcome == .passed)
        #expect(await w.server.checkpoints.last?.sessionReference == reference)

        await w.queue(.developer, PipelineContext(step: .developer, resumeSessionReference: UUID().uuidString.lowercased()))
        try await r.tick()
        let unknown = try #require(await w.provider.requests.last)
        #expect(!unknown.resume && unknown.sessionID != planner)
        #expect(await w.finish(r, AgentResult(text: "Built."), submissions: 3))

        let otherFolder = w.f.directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let other = Binding(repositoryKey: try w.f.allowlist.approve(folder: otherFolder), label: "Other")
        await w.queue(.developer, PipelineContext(step: .developer, resumeSessionReference: reference), on: other)
        try await r.tick()
        let elsewhere = try #require(await w.provider.requests.last)
        #expect(elsewhere.folder.path == otherFolder.path && !elsewhere.resume && elsewhere.sessionID != planner)
    }

    @Test(arguments: [("claude-opus-5-5", "high", true), ("--dangerously-skip-permissions", "-x", false), ("a b", "hi;gh", false), ("", "ü", false)])
    func modelAndEffortArePassedOnlyWhenWellFormed(model: String, effort: String, valid: Bool) async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        await w.queue(.developer, PipelineContext(step: .developer, model: model, effort: effort))
        let r = try w.runner()
        try await r.tick()
        let request = try #require(await w.provider.requests.first)
        #expect(request.model == (valid ? model : nil) && request.effort == (valid ? effort : nil))
    }

    @Test func questionDuringAPipelineStepResumesWithStepSettings() async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        await w.queue(.tester, PipelineContext(step: .tester, model: "m1"))
        let r = try w.runner()
        try await r.tick()
        await w.provider.finish(await w.provider.lastPID(), AgentResult(text: "?", question: "Which?", verdict: "passed"))
        #expect(await eventually(r) { await r.snapshot().first?.phase == .waitingForAnswer })
        #expect(await w.server.stepSubmissions.isEmpty)
        await w.server.answerAll("this one")
        try await r.tick()
        let second = try #require(await w.provider.requests.last)
        #expect(second.resume && second.step == .tester && second.model == "m1" && second.prompt.contains("`verdict`"))
    }

    @Test func agentErrorOfAStepFailsTheRun() async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        await w.queue(.developer)
        let r = try w.runner()
        try await r.tick()
        await w.provider.finish(await w.provider.lastPID(), AgentResult(text: "x", isError: true))
        #expect(await eventually(r) { await w.server.count("fail") == 1 })
        #expect(await w.server.stepSubmissions.isEmpty)
    }

    @Test func manualJobsAreUnchanged() async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        await w.queue(nil)
        let r = try w.runner()
        try await r.tick()
        let request = try #require(await w.provider.requests.first)
        #expect(request.step == nil && request.model == nil && request.effort == nil && !request.resume)
        #expect(request.allowedTools == ["Read", "Glob", "Grep", "Edit", "Write"])
        #expect(request.prompt == """
        Task: Fix the thing (task revision 1, released at revision 1)
        Details here
        Scope: Do it
        Mode: implement. Make the changes within the scope. Do not commit, push or deploy.
        If Todo MCP tools are available in this session, call get_manual first and follow it for progress notes and questions; otherwise continue without it.
        """)
        await w.provider.finish(await w.provider.lastPID(), AgentResult(text: "Done.", plan: "ignored", verdict: "failed"))
        #expect(await eventually(r) { await w.server.count("submit g") == 1 })
        #expect(await w.server.stepSubmissions.isEmpty)
        #expect(await w.server.count("hold") == 0)
    }
}

@Suite(.serialized) struct PipelineValidationTests {
    @Test func runsTheConfiguredCommandWithoutAgentAndKeepsOutputLocal() async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        // Relative program in the approved folder; arguments must arrive literally (no shell).
        let check = w.f.repo.appendingPathComponent("check.sh")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > args.txt\necho $$ $(ps -o pgid= -p $$) > group.txt\necho TOP-SECRET-OUTPUT\necho ERR-OUTPUT >&2\n".utf8).write(to: check)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: check.path)
        try w.commands.setValidation(LocalCommand(argv: ["./check.sh", "a b", "$HOME; touch pwned"], timeout: 30), for: w.key)
        await w.queue(.validation)
        let executor = RecordingExecutor(state: w.f.state)
        let r = try w.runner(executor: executor)
        #expect(await eventually(r) { await w.server.stepSubmissions.count == 1 })
        #expect(await w.provider.requests.isEmpty)
        #expect(await executor.phasesAtStart == [.launching])                 // persisted before the spawn
        #expect(w.read("args.txt") == "a b\n$HOME; touch pwned")
        #expect(!FileManager.default.fileExists(atPath: w.f.repo.appendingPathComponent("pwned").path))
        let group = w.read("group.txt").split(separator: " ")
        #expect(group.count == 2 && group.first == group.last)                // own process group
        let sent = try #require(await w.server.stepSubmissions.first)
        #expect(sent.outcome == .passed && sent.plan == nil && sent.result.summary.contains("Exit-Code 0"))
        let published = ([sent.result.summary] + sent.result.checks + sent.result.limitations + sent.result.references).joined()
            + (await w.server.progressTexts).joined()
        #expect(!published.contains("TOP-SECRET") && !published.contains("check.sh") && !published.contains(w.f.repo.path))
        let log = w.f.state.appendingPathComponent("validation-output/\(w.key.uuidString.lowercased()).log")
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains("TOP-SECRET-OUTPUT") && text.contains("ERR-OUTPUT"))
        #expect(try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int == 0o600)
        #expect(await r.snapshot().first?.phase == .closed)
    }

    @Test(arguments: [("exit 3", "Exit-Code 3"), (nil, "todo-runner validation")] as [(String?, String)])
    func failingOrMissingCommandIsReportedAsFailed(body: String?, expected: String) async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        if let body { try w.validation(body) }
        await w.queue(.validation)
        let r = try w.runner()
        #expect(await eventually(r) { await w.server.stepSubmissions.count == 1 })
        let sent = try #require(await w.server.stepSubmissions.first)
        #expect(sent.outcome == .failed && sent.result.summary.contains(expected))
        #expect(await w.provider.requests.isEmpty)
    }

    @Test func unstartableProgramIsReportedAsFailedWithoutPaths() async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        try w.commands.setValidation(LocalCommand(argv: [w.f.directory.appendingPathComponent("missing").path], timeout: 5), for: w.key)
        await w.queue(.validation)
        let r = try w.runner()
        #expect(await eventually(r) { await w.server.stepSubmissions.count == 1 })
        let sent = try #require(await w.server.stepSubmissions.first)
        #expect(sent.outcome == .failed && sent.result.summary.contains("nicht gestartet") && !sent.result.summary.contains(w.f.directory.path))
    }

    @Test func timeoutKillsTheWholeProcessGroup() async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        try w.validation("/bin/sleep 60 &\necho $! > child.pid\nwait", timeout: 0.7)
        await w.queue(.validation)
        let r = try w.runner()
        #expect(await eventually(r) { await w.server.stepSubmissions.count == 1 })
        #expect(await w.server.stepSubmissions.first?.outcome == .failed)
        #expect(await w.server.stepSubmissions.first?.result.summary.contains("Zeitlimit") == true)
        let child = try #require(Int32(w.read("child.pid")))
        #expect(await eventually { isGone(child) })
    }

    @Test(arguments: [true, false])
    func serverStopOrLeaseLossKillsTheCommand(humanStop: Bool) async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        try w.validation("/bin/sleep 60 &\necho $! > child.pid\nwait")
        let job = await w.queue(.validation)
        let r = try w.runner()
        #expect(await eventually(r) { !w.read("child.pid").isEmpty })
        let heartbeats = await w.server.count("heartbeat")
        try await r.tick()
        #expect(await w.server.count("heartbeat") > heartbeats)
        if humanStop { await w.server.cancel(jobID: job.id) } else { await w.server.set(writeError: .conflict("stale_generation"), for: "heartbeat") }
        let child = try #require(Int32(w.read("child.pid")))
        #expect(await eventually(r) { await r.snapshot().first?.phase == .closed })
        #expect(await eventually { isGone(child) })
        #expect(await w.server.stepSubmissions.isEmpty)
        #expect(await w.server.count("stop") == (humanStop ? 1 : 0))
    }

    private func seed(_ w: PipelineWorld, phase: RunPhase, process: ProcessReference?) async throws {
        let job = Job(bindingID: w.binding.id, mode: .clarify, scope: "s", state: .running, pipelineStep: .validation)
        let run = Run(job: job, leaseUntil: Date().addingTimeInterval(90))
        await w.server.insert(run: run)
        try LocalStateStore(directory: w.f.state).save([LocalRun(runID: run.id, job: job, repositoryKey: w.key, folder: w.f.repo.path,
            sessionID: UUID(), generation: 1, leaseUntil: run.leaseUntil, phase: phase, process: process, contextRevision: 1, note: "")])
    }

    @Test func crashBetweenIntentAndSpawnIsNeverRestartedBlindly() async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        try w.validation("echo x > ran.txt")
        try await seed(w, phase: .launching, process: nil)
        let executor = RecordingExecutor(state: w.f.state)
        let r = try w.runner(executor: executor)
        try await r.tick(); try await r.tick()
        #expect(await r.snapshot().first?.phase == .needsReconciliation)
        #expect(await executor.starts == 0 && w.read("ran.txt").isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func adoptedCommandAfterRestartIsNotRepeatedAndNeverCountsAsPassed() async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        try w.validation("echo x > ran.txt")
        // Re-parented process, as after a runner crash.
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "/bin/sleep 0.8 >/dev/null 2>&1 & echo $!"]
        let pipe = Pipe(); sh.standardOutput = pipe
        try sh.run(); sh.waitUntilExit()
        let pid = try #require(Int32(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await seed(w, phase: .running, process: ProcessReference(pid: pid, startTime: ClaudeProcessAdapter.startTime(of: pid) ?? 0,
                                                                     deadline: Date().addingTimeInterval(60)))
        let executor = RecordingExecutor(state: w.f.state)
        let r = try w.runner(executor: executor)
        try await r.tick()
        #expect(await r.snapshot().first?.phase == .running)
        #expect(await eventually(r) { await w.server.stepSubmissions.count == 1 })
        let sent = try #require(await w.server.stepSubmissions.first)
        #expect(sent.outcome == .failed && sent.result.summary.contains("unbekannt"))
        #expect(await executor.starts == 0 && w.read("ran.txt").isEmpty)
    }
}

@Suite(.serialized) struct BudgetBrakeTests {
    private func budget(_ w: PipelineWorld, _ body: String) throws {
        try w.commands.setBudget([try w.script(body)])
    }

    @Test func redBudgetHoldsAgentJobsButValidationStillRuns() async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        try budget(w, #"echo '{"ampel":"rot"}'"#)
        try w.validation("exit 0")
        let manual = await w.queue(nil), planner = await w.queue(.planner)
        await w.queue(.validation)
        let r = try w.runner()
        #expect(await eventually(r) { await w.server.stepSubmissions.count == 1 })
        #expect(await w.server.count("claim") == 1)
        #expect(await w.provider.requests.isEmpty)
        let holds = await w.server.holds
        #expect(Set(holds.map(\.job)) == [manual.id, planner.id])
        #expect(holds.allSatisfy { $0.reason.hasPrefix("Kontingent-Bremse: ") && $0.reason.count <= 200 })
        try await r.tick(); try await r.tick()
        #expect(await w.server.holds.count == 2)                      // unchanged text is not sent again
    }

    @Test(arguments: [#"echo '{"ampel":"gruen"}'; exit 1"#, "echo nonsense", #"echo '{"allowed":false}'"#, "echo '{}'",
                      #"echo '{"allowed":true,"ampel":"rot"}'"#, #"echo '{"allowed":"yes"}'"#, "/bin/sleep 5", "exit 0"])
    func forbidsClaimingWhenInDoubt(body: String) async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        try budget(w, body)
        await w.queue(.developer)
        let r = try w.runner(budgetTimeout: 0.5)
        try await r.tick()
        #expect(await w.server.count("claim") == 0)
        #expect(await w.server.holds.count == 1)
    }

    @Test(arguments: [#"echo '{"ampel":"gelb","konten":[]}'; echo warn >&2"#, #"echo '{"allowed":true}'"#])
    func allowsClaimingOnAClearAnswer(body: String) async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        try budget(w, body)
        await w.queue(nil)
        let r = try w.runner()
        try await r.tick()
        #expect(await w.server.count("claim") == 1)
        #expect(await w.provider.requests.count == 1)
        #expect(await w.server.count("hold") == 0)
    }

    @Test func missingProgramAndOldServerWithoutHoldStayFailClosed() async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        try w.commands.setBudget(["/nonexistent/budget"])
        await w.queue(nil)
        await w.server.set(writeError: .notFound, for: "hold")
        let r = try w.runner()
        try await r.tick(); try await r.tick()
        #expect(await w.server.count("claim") == 0)
        #expect(await w.server.count("hold") >= 1)
    }

    @Test func redBudgetDefersTheResumeAfterAnAnswer() async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        try budget(w, #"echo '{"ampel":"gruen"}'"#)
        await w.queue(nil)
        let r = try w.runner()
        try await r.tick()
        await w.provider.finish(await w.provider.lastPID(), AgentResult(text: "?", question: "Which?"))
        #expect(await eventually(r) { await r.snapshot().first?.phase == .waitingForAnswer })
        try budget(w, #"echo '{"ampel":"rot"}'"#)
        await w.server.answerAll("A")
        try await r.tick(); try await r.tick()
        #expect(await w.server.count("resume") == 0)
        #expect(await r.snapshot().first?.phase == .waitingForAnswer)
        #expect(await r.snapshot().first?.note.contains("Kontingent-Bremse") == true)
        try budget(w, #"echo '{"ampel":"gruen"}'"#)
        try await r.tick()
        #expect(await w.server.count("resume") == 1)
        #expect(await w.provider.requests.count == 2)
    }
}

@Suite(.serialized) struct PipelineCLITests {
    private func cli(_ w: PipelineWorld, _ output: CLITests.Output) -> RunnerCLI {
        RunnerCLI(context: CLITests().context(w.f, output, server: w.server))
    }

    @Test func validationCommandIsStoredLocallyAndCleared() async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        let output = CLITests.Output(), cli = cli(w, output)
        #expect(try await cli.execute(["validation", w.f.repo.path, "--timeout", "60", "--", "/bin/echo", "a b", "--clear"]) == 0)
        #expect(try w.commands.validation(for: w.key) == LocalCommand(argv: ["/bin/echo", "a b", "--clear"], timeout: 60))
        #expect(try FileManager.default.attributesOfItem(atPath: w.commands.file.path)[.posixPermissions] as? Int == 0o600)
        _ = try await cli.execute(["validation", w.key.uuidString, "--", "./scripts/check.sh"])
        #expect(try w.commands.validation(for: w.key) == LocalCommand(argv: ["./scripts/check.sh"], timeout: 1800))
        for bad in [["validation", w.key.uuidString, "/bin/echo"], ["validation", w.key.uuidString, "--"],
                    ["validation", w.key.uuidString, "--timeout", "0", "--", "/bin/echo"], ["validation"]] {
            await #expect(throws: RunnerError.invalidConfiguration) { try await cli.execute(bad) }
        }
        for unapproved in [UUID().uuidString, w.f.directory.path] {
            await #expect(throws: RunnerError.unapprovedFolder) { try await cli.execute(["validation", unapproved, "--", "/bin/echo"]) }
        }
        _ = try await cli.execute(["validation", w.f.repo.path, "--clear"])
        #expect(try w.commands.validation(for: w.key) == nil)
    }

    @Test func budgetCommandIsStoredShownAndCleared() async throws {
        let w = try PipelineWorld(); defer { w.f.cleanup() }
        let output = CLITests.Output(), cli = cli(w, output)
        _ = try await cli.execute(["pair", "https://todo.example", "GOOD-CODE"])
        _ = try await cli.execute(["budget", "--", "echo", "--json"])
        #expect(try w.commands.budget() == ["/bin/echo", "--json"])          // bare names are resolved when configured
        _ = try await cli.execute(["validation", w.f.repo.path, "--", "/usr/bin/true", "--marker"])
        _ = try await cli.execute(["status"])
        #expect(output.out.contains("Kontingent-Bremse: /bin/echo --json") && output.out.contains("/usr/bin/true --marker"))
        let doctor = CLITests.Output()
        #expect(try await self.cli(w, doctor).execute(["doctor"]) == 0)
        #expect(doctor.out.contains("[OK] Kontingent-Bremse") && doctor.out.contains("[OK] Validierung"))
        await #expect(throws: RunnerError.invalidConfiguration) { try await cli.execute(["budget"]) }
        _ = try await cli.execute(["budget", "--clear"])
        #expect(try w.commands.budget() == nil)
    }
}

extension ClaudeProcessAdapterTests {
    @Test func pipelineStepsChangeSchemaModelAndEffortOnly() throws {
        func arguments(_ step: PipelineStep?, model: String? = nil, effort: String? = nil) -> [String] {
            ClaudeProcessAdapter.arguments(for: AgentRequest(sessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                folder: URL(fileURLWithPath: "/"), prompt: "P", step: step, model: model, effort: effort))
        }
        func value(_ flag: String, _ a: [String]) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
        func required(_ a: [String]) throws -> [String] {
            let schema = try #require(value("--json-schema", a))
            return try #require((try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])?["required"] as? [String])
        }
        let manual = arguments(nil)
        #expect(!manual.contains("--model") && !manual.contains("--effort"))
        #expect(try required(manual) == ["text"])
        #expect(try required(arguments(.developer)) == ["text"])
        #expect(try required(arguments(.planner)) == ["text", "plan"])
        #expect(try required(arguments(.tester)) == ["text", "verdict"])
        #expect(try required(arguments(.review)) == ["text", "verdict"])
        let tuned = arguments(.developer, model: "claude-opus-5-5", effort: "high")
        #expect(value("--model", tuned) == "claude-opus-5-5" && value("--effort", tuned) == "high")
        let hostile = arguments(.developer, model: "--add-dir=/", effort: "a b")
        #expect(hostile == arguments(.developer))
    }

    @Test func parsesPlanAndVerdict() throws {
        let session = UUID()
        let data = Data(#"{"session_id":"\#(session.uuidString.lowercased())","is_error":false,"structured_output":{"text":"T","plan":"P","verdict":"passed"}}"#.utf8)
        let result = try ClaudeProcessAdapter.parse(data, sessionID: session, exitStatus: 0)
        #expect(result.plan == "P" && result.verdict == "passed")
    }
}

extension RunnerServerTests {
    @Test func pipelinePollingClaimStepSubmitAndHoldHaveContractShapes() async throws {
        let id = "22222222-2222-2222-2222-222222222222"
        let job = #"{"id":"\#(id)","taskID":"\#(id)","projectID":"\#(id)","bindingID":"\#(id)","requestedBy":"\#(id)","taskRevision":1,"mode":"implement","scope":"s","state":"queued","progress":"","pipelineStep":"developer","pipelineExecutionID":"\#(id)"}"#
        let old = job.replacingOccurrences(of: #","pipelineStep":"developer","pipelineExecutionID":"\#(id)""#, with: "")
        let task = #"{"id":"\#(id)","projectID":"\#(id)","title":"t","description":"","status":"open","version":1}"#
        let run = runJSON
        let s = server { request, _ in
            let path = request.url!.path
            if path.hasSuffix("/jobs") { return (200, Data("[\(job),\(old)]".utf8)) }
            if path.hasSuffix("/hold") { return (200, Data(job.utf8)) }
            if path.hasSuffix("/jobs/\(id)") {
                return (200, Data(#"{"job":\#(job),"task":\#(task),"questions":[],"events":[],"pipeline":{"step":"developer","planBody":"B","planVersion":2,"feedback":null,"model":"m","effort":null,"resumeSessionReference":"abc"}}"#.utf8))
            }
            return (200, Data(run.utf8))
        }
        let uuid = UUID(uuidString: id)!
        let jobs = try await s.jobs()
        #expect(jobs.map(\.pipelineStep) == [.developer, nil] && jobs[0].pipelineExecutionID == uuid)
        let detail = try await s.detail(jobID: uuid)
        #expect(detail.pipeline == PipelineContext(step: .developer, planBody: "B", planVersion: 2, model: "m", resumeSessionReference: "abc"))
        _ = try await s.claim(jobID: uuid)
        _ = try await s.submitStep(runID: uuid, generation: 3, result: RunResult(summary: "S"), outcome: .passed, plan: "Plan")
        _ = try await s.submitStep(runID: uuid, generation: 3, result: RunResult(summary: "S"), outcome: .failed, plan: nil)
        _ = try await s.hold(jobID: uuid, reason: "Kontingent-Bremse: Ampel rot")
        let seen = MockURLProtocol.seen
        #expect(seen[0].0.url?.query == "pipeline=1" && seen[0].0.url?.path == "/v1/runner/jobs")
        #expect(seen[2].0.url?.query == "pipeline=1" && seen[2].0.url?.path == "/v1/runner/jobs/\(id)/claim")
        func body(_ i: Int) -> NSDictionary? { seen[i].1.flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSDictionary } }
        let result: [String: Any] = ["summary": "S", "references": [String](), "checks": [String](), "limitations": [String]()]
        #expect(seen[3].0.url?.path == "/v1/runner/runs/\(id)/submit")
        #expect(body(3) == ["generation": 3, "result": result, "outcome": "passed", "plan": "Plan"] as NSDictionary)
        #expect(body(4) == ["generation": 3, "result": result, "outcome": "failed"] as NSDictionary)
        #expect(seen[5].0.url?.path == "/v1/runner/jobs/\(id)/hold" && body(5) == ["reason": "Kontingent-Bremse: Ampel rot"] as NSDictionary)
    }
}
