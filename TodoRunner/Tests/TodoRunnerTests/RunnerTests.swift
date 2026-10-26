import Foundation
import Testing
@testable import TodoRunner

@Suite(.serialized) struct RunnerTests {
    func setup(jobs: Int = 1) async throws -> (Fixture, FakeServer, FakeProvider, Binding, UUID) {
        let f = try Fixture()
        let key = try f.allowlist.approve(folder: f.repo)
        let binding = Binding(repositoryKey: key, label: "Repo")
        let server = FakeServer(); let provider = FakeProvider()
        for _ in 0..<jobs { await server.add(job: makeJob(binding: binding), binding: binding) }
        return (f, server, provider, binding, key)
    }

    @Test func happyPathClaimLaunchCheckpointSubmit() async throws {
        let (f, server, provider, _, _) = try await setup(); defer { f.cleanup() }
        try? FileManager.default.createDirectory(at: f.state, withIntermediateDirectories: true)
        let runner = try makeRunner(f, server: server, provider: provider)
        try await runner.tick()
        let request = try #require(await provider.requests.first)
        #expect(!request.resume && request.folder.path == f.repo.path)
        #expect(request.allowedTools.contains("Edit") && request.prompt.contains("Fix the bug in main.swift"))
        #expect(await server.index(of: "runs")! < (await server.index(of: "jobs")!))   // reconcile before claim
        await provider.finish(await provider.lastPID(), AgentResult(text: "Done."))
        #expect(await eventually(runner) { await server.count("submit") == 1 })
        let order = await server.calls.filter { ["claim", "checkpoint", "submit"].contains(where: $0.hasPrefix) }.map { String($0.prefix(6)) }
        #expect(order == ["claim", "checkpo", "submit"].map { String($0.prefix(6)) })
        #expect(await server.submitted.first?.summary == "Done.")
        #expect(await server.checkpoints.first?.sessionReference == request.sessionID.uuidString.lowercased())
        #expect(await runner.snapshot().first?.phase == .closed)
    }

    @Test func clarifyModeUsesReadOnlyTools() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let key = try f.allowlist.approve(folder: f.repo)
        let binding = Binding(repositoryKey: key, label: "R")
        let server = FakeServer(); let provider = FakeProvider()
        await server.add(job: makeJob(binding: binding, mode: .clarify), binding: binding)
        let runner = try makeRunner(f, server: server, provider: provider)
        try await runner.tick()
        let request = try #require(await provider.requests.first)
        #expect(!request.allowedTools.contains("Edit") && !request.allowedTools.contains("Write"))
    }

    @Test func questionPausesHeartbeatsContinueAndAnswerResumesSameSession() async throws {
        let (f, server, provider, _, _) = try await setup(); defer { f.cleanup() }
        let runner = try makeRunner(f, server: server, provider: provider)
        try await runner.tick()
        let session = try #require(await provider.requests.first?.sessionID)
        await provider.finish(await provider.lastPID(), AgentResult(text: "?", question: "Which API?", options: ["A", "B"]))
        #expect(await eventually(runner) { await server.count("question") == 1 })
        #expect(await server.asked.first?.1 == ["A", "B"])
        #expect(await eventually(runner) { await runner.snapshot().first?.phase == .waitingForAnswer })
        let heartbeats = await server.count("heartbeat")
        try await runner.tick(); try await runner.tick()
        #expect(await server.count("heartbeat") > heartbeats)           // heartbeat during pause
        #expect(await server.count("resume") == 0)
        #expect((await provider.requests.count) == 1)
        await server.answerAll("B")
        try await runner.tick()
        #expect(await server.count("resume") == 1)
        let second = try #require(await provider.requests.dropFirst().first)
        #expect(second.resume && second.sessionID == session && second.prompt.contains("A: B"))
        try await runner.tick()
        #expect(await provider.requests.count == 2)                       // answers are delivered once
        await provider.finish(await provider.lastPID(), AgentResult(text: "Finished."))
        #expect(await eventually(runner) { await server.count("submit") == 1 })
    }

    @Test func errorResultFailsRunAndFreesFolder() async throws {
        let (f, server, provider, _, _) = try await setup(jobs: 2); defer { f.cleanup() }
        let runner = try makeRunner(f, server: server, provider: provider)
        try await runner.tick()
        await provider.finish(await provider.lastPID(), AgentResult(text: "boom", exitStatus: 1, isError: true))
        #expect(await eventually(runner) { await server.count("fail") == 1 })
        #expect(await eventually(runner) { await provider.requests.count == 2 })   // next queued job starts afterwards, not automatically retried
    }

    @Test func atMostOneRunPerFolderAndSingleWriterLock() async throws {
        let (f, server, provider, _, _) = try await setup(jobs: 2); defer { f.cleanup() }
        let runner = try makeRunner(f, server: server, provider: provider)
        try await runner.tick(); try await runner.tick(); try await runner.tick()
        #expect(await server.count("claim") == 1)
        #expect((await provider.requests.count) == 1)
        #expect(throws: RunnerError.alreadyOpen) { _ = try LocalStateStore(directory: f.state) }
    }

    @Test func claimConflictStartsNothing() async throws {
        let (f, server, provider, _, _) = try await setup(); defer { f.cleanup() }
        await server.setClaimConflict()
        let runner = try makeRunner(f, server: server, provider: provider)
        try await runner.tick()
        #expect(await provider.requests.isEmpty)
        #expect((await runner.snapshot()).isEmpty)
    }

    @Test func unapprovedRepositoryIsNeverClaimed() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let binding = Binding(repositoryKey: UUID(), label: "Other")
        let server = FakeServer(); let provider = FakeProvider()
        await server.add(job: makeJob(binding: binding), binding: binding)
        let runner = try makeRunner(f, server: server, provider: provider)
        try await runner.tick()
        #expect(await server.count("claim") == 0)
        #expect(await provider.requests.isEmpty)
    }

    @Test func allowlistRejectsAliasesAndRedirectedSymlinks() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let key = try f.allowlist.approve(folder: f.repo)
        #expect(try f.allowlist.approve(folder: f.repo) == key)                       // idempotent per folder
        #expect(throws: RunnerError.invalidConfiguration) { try f.allowlist.approve(folder: f.repo, repositoryKey: UUID()) }
        let link = f.directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.repo)
        #expect(try f.allowlist.approve(folder: link) == key)                         // alias resolves to the same canonical folder
        #expect(try f.allowlist.folder(for: UUID()) == nil)
        try FileManager.default.removeItem(at: f.repo)
        #expect(throws: RunnerError.unapprovedFolder) { try f.allowlist.folder(for: key) }
    }

    // MARK: Restart

    @Test func restartAdoptsAliveProcessWithoutSecondStart() async throws {
        let (f, server, provider, _, _) = try await setup(jobs: 2); defer { f.cleanup() }
        do {
            let first = try makeRunner(f, server: server, provider: provider)
            try await first.tick()
        }
        let pid = await provider.lastPID()
        let second = try makeRunner(f, server: server, provider: provider)
        try await second.tick()
        #expect(await provider.requests.count == 1)
        #expect((await server.count("claim")) == 1)
        #expect(await second.snapshot().first?.phase == .running)
        await provider.finish(pid, AgentResult(text: "ok"))
        #expect(await eventually(second) { await server.count("submit") == 1 })
    }

    @Test func restartWithVanishedProcessFailsRunInsteadOfRestarting() async throws {
        let (f, server, provider, _, _) = try await setup(); defer { f.cleanup() }
        do { let first = try makeRunner(f, server: server, provider: provider); try await first.tick() }
        let pid = await provider.lastPID()
        await provider.observe(pid, .exited)
        await provider.finish(pid, AgentResult(text: "", exitStatus: -1, isError: true))
        let second = try makeRunner(f, server: server, provider: provider)
        try await second.tick()
        #expect(await server.count("fail") == 1)
        #expect(await provider.requests.count == 1)
    }

    @Test func restartWithUnverifiableProcessKeepsFolderReservedUntilRelease() async throws {
        let (f, server, provider, _, _) = try await setup(jobs: 2); defer { f.cleanup() }
        do { let first = try makeRunner(f, server: server, provider: provider); try await first.tick() }
        let pid = await provider.lastPID()
        await provider.observe(pid, .uncertain)
        let second = try makeRunner(f, server: server, provider: provider)
        try await second.tick(); try await second.tick()
        #expect(await second.snapshot().first?.phase == .needsReconciliation)
        #expect(await server.count("claim") == 1)
        #expect((await provider.requests.count) == 1)
        #expect(await server.count("fail") == 0)
        #expect(await server.count("submit") == 0)
        await provider.observe(pid, .exited)
        let id = try #require(await second.snapshot().first?.runID)
        try await second.release(runID: id)
        #expect(await server.count("reconcile stopped") == 1)
        try await second.tick()
        #expect(await server.count("claim") == 2)
    }

    @Test func restartAfterCrashBetweenIntentAndSpawnDoesNotRestart() async throws {
        let (f, server, provider, _, key) = try await setup(); defer { f.cleanup() }
        // Hand-written state: launch intent persisted, no process recorded.
        let run = Run(job: Job(bindingID: UUID(), scope: "s", state: .claimed), generation: 1, leaseUntil: Date().addingTimeInterval(60))
        await server.insert(run: run)
        let local = LocalRun(runID: run.id, job: run.job, repositoryKey: key, folder: f.repo.path, sessionID: UUID(), generation: 1,
                             leaseUntil: run.leaseUntil, phase: .launching, process: nil, contextRevision: 1, note: "")
        do { let store = try LocalStateStore(directory: f.state); try store.save([local]) }
        let runner = try makeRunner(f, server: server, provider: provider)
        try await runner.tick()
        #expect(await runner.snapshot().first?.phase == .needsReconciliation)
        #expect(await provider.requests.isEmpty)
    }

    @Test func unknownServerRunIsReconciledStoppedNotStarted() async throws {
        let (f, server, provider, _, _) = try await setup(); defer { f.cleanup() }
        let orphan = Run(job: Job(bindingID: UUID(), scope: "s", state: .claimed), generation: 3, leaseUntil: Date().addingTimeInterval(60))
        await server.insert(run: orphan)
        let runner = try makeRunner(f, server: server, provider: provider)
        try await runner.tick()
        #expect(await server.count("reconcile stopped g3") == 1)
    }

    @Test func restartAfterLeaseExpiryOfPausedRunReportsPaused() async throws {
        let (f, server, provider, _, _) = try await setup(); defer { f.cleanup() }
        do {
            let first = try makeRunner(f, server: server, provider: provider)
            try await first.tick()
            await provider.finish(await provider.lastPID(), AgentResult(text: "?", question: "Q?"))
            #expect(await eventually(first) { await first.snapshot().first?.phase == .waitingForAnswer })
        }
        let clock = Clock(); clock.advance(200)                       // restart after the 90 s lease has expired
        await server.set(lease: 1000)                                 // renewed leases outlive the skewed test clock
        var settings = RunnerSettings(); settings.now = { clock.now }
        let second = try makeRunner(f, server: server, provider: provider, settings: settings)
        try await second.tick()
        #expect(await server.count("reconcile paused") == 1)
        #expect(await second.snapshot().first?.phase == .waitingForAnswer)
        #expect(await provider.requests.count == 1)
    }

    // MARK: Lease loss and stop

    @Test func leaseLossFencesPublicationKillsProcessAndConfirmsStop() async throws {
        let (f, server, provider, _, _) = try await setup(); defer { f.cleanup() }
        let runner = try makeRunner(f, server: server, provider: provider)
        try await runner.tick()
        let pid = await provider.lastPID()
        await server.set(heartbeatError: .gone("lease lost"))
        try await runner.tick()
        #expect(await provider.stopped == [pid])
        #expect(await runner.snapshot().first?.phase == .closed)
        #expect(await server.count("reconcile stopped") == 1)
        await provider.finish(pid, AgentResult(text: "late result"))
        try await Task.sleep(for: .milliseconds(100)); try await runner.tick()
        for name in ["submit", "checkpoint", "question", "fail"] { #expect(await server.count(name) == 0) }
    }

    @Test func staleGenerationOnPublishFencesRun() async throws {
        let (f, server, provider, _, _) = try await setup(); defer { f.cleanup() }
        let runner = try makeRunner(f, server: server, provider: provider)
        try await runner.tick()
        await server.set(writeError: .conflict("stale generation"), for: "checkpoint")
        await provider.finish(await provider.lastPID(), AgentResult(text: "done"))
        #expect(await eventually(runner) { await runner.snapshot().first?.phase == .closed })
        #expect(await server.count("submit") == 0)
    }

    @Test func localLeaseExpiryWithoutServerContactFailsClosed() async throws {
        let (f, server, provider, _, _) = try await setup(); defer { f.cleanup() }
        let clock = Clock()
        var settings = RunnerSettings(); settings.now = { clock.now }
        let runner = try makeRunner(f, server: server, provider: provider, settings: settings)
        try await runner.tick()
        await server.set(heartbeatError: .transport("offline"))
        try await runner.tick()
        #expect(await runner.snapshot().first?.phase == .running)         // transient failure alone does not kill the run
        clock.advance(120)
        await server.set(writeError: .transport("offline"), for: "reconcile")
        try await runner.tick()
        #expect(await runner.snapshot().first?.phase == .leaseLost)
        #expect(await provider.stopped.count == 1)
        await provider.finish(await provider.lastPID(), AgentResult(text: "x"))
        try await runner.tick()
        #expect(await server.count("submit") == 0)
    }

    @Test func operatorStopKillsProcessAndConfirmsToServer() async throws {
        let (f, server, provider, _, _) = try await setup(); defer { f.cleanup() }
        let runner = try makeRunner(f, server: server, provider: provider)
        try await runner.tick()
        let id = try #require(await runner.snapshot().first?.runID)
        try await runner.stop(runID: id)
        #expect(await eventually(runner) { await server.count("stop") == 1 })
        #expect(await provider.stopped.count == 1)
        #expect(await server.state(of: id) == .cancelled)
        #expect((await server.count("submit")) == 0)
        #expect(await runner.snapshot().first?.phase == .closed)
    }

    @Test func humanCancelOnServerStopsLocalProcess() async throws {
        let (f, server, provider, _, _) = try await setup(); defer { f.cleanup() }
        let runner = try makeRunner(f, server: server, provider: provider)
        try await runner.tick()
        let id = try #require(await runner.snapshot().first?.runID)
        await server.cancel(jobID: await runner.snapshot().first!.job.id)
        #expect(await eventually(runner) { await server.count("stop") == 1 })
        #expect(await provider.stopped.count == 1)
        #expect((await server.count("submit")) == 0)
        #expect(await server.state(of: id) == .cancelled)
    }

    @Test func providerStartFailureReportsFailure() async throws {
        let (f, server, provider, _, _) = try await setup(); defer { f.cleanup() }
        await provider.set(startError: RunnerError.spawn(2))
        let runner = try makeRunner(f, server: server, provider: provider)
        try await runner.tick()
        #expect(await server.count("fail") == 1)
    }

    @Test func stateSurvivesInAtomicFileWithOwnerOnlyPermissions() async throws {
        let (f, server, provider, _, _) = try await setup(); defer { f.cleanup() }
        let runner = try makeRunner(f, server: server, provider: provider)
        try await runner.tick()
        let file = f.state.appendingPathComponent("runs.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.state.path).filter { $0.hasSuffix(".tmp") }.isEmpty)
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var offset: TimeInterval = 0
    var now: Date { lock.withLock { Date().addingTimeInterval(offset) } }
    func advance(_ s: TimeInterval) { lock.withLock { offset += s } }
}
