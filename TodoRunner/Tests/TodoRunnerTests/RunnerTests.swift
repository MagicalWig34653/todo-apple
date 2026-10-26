import Foundation
import Testing
@testable import TodoRunner

actor FakeProvider: AgentProvider {
    var requests: [AgentRequest] = []
    var stopped: [ProcessReference] = []
    var observations: [Int32: ProcessObservation] = [:]
    var results: [Int32: AgentResult] = [:]
    var waiters: [Int32: CheckedContinuation<AgentResult, Never>] = [:]
    var finishOnStop = true
    func start(_ request: AgentRequest) -> ProcessReference {
        requests.append(request)
        let process = ProcessReference(pid: Int32(100_000 + requests.count))
        observations[process.pid] = .running
        return process
    }
    func wait(for process: ProcessReference) async -> AgentResult {
        if let result = results.removeValue(forKey: process.pid) { return result }
        return await withCheckedContinuation { waiters[process.pid] = $0 }
    }
    func complete(_ pid: Int32, _ result: AgentResult = AgentResult(text: "Done")) {
        observations[pid] = .exited
        if let waiter = waiters.removeValue(forKey: pid) { waiter.resume(returning: result) }
        else { results[pid] = result }
    }
    func stop(_ process: ProcessReference) {
        stopped.append(process)
        if finishOnStop { complete(process.pid, AgentResult(text: "Stopped", exitStatus: 137, isError: true)) }
    }
    func setFinishOnStop(_ value: Bool) { finishOnStop = value }
    func reconcile(_ process: ProcessReference) -> ProcessObservation { observations[process.pid] ?? .uncertain }
    func setObservation(_ pid: Int32, _ observation: ProcessObservation) { observations[pid] = observation }
}

actor FakeServer: RunnerServer {
    var jobs: [RunnerJob]
    var events: [(RunnerJob, RunnerEvent)] = []
    var lost = false
    var publishFails = false
    var nextAnswer: String?
    var claims: [[String]] = []
    init(_ jobs: [RunnerJob]) { self.jobs = jobs }
    func claim(eligibleProjects: [String]) -> RunnerJob? {
        claims.append(eligibleProjects)
        guard let i = jobs.firstIndex(where: { eligibleProjects.contains($0.projectID) }) else { return nil }
        return jobs.remove(at: i)
    }
    func renew(_ job: RunnerJob) -> Date? { lost ? nil : Date().addingTimeInterval(60) }
    func publish(_ event: RunnerEvent, for job: RunnerJob) throws {
        guard !lost, !publishFails, job.leaseExpiresAt > Date() else { throw RunnerError.invalidConfiguration }
        events.append((job, event))
    }
    func answer(for job: RunnerJob) -> String? {
        defer { nextAnswer = nil }
        return nextAnswer
    }
    func setLost() { lost = true }
    func setAnswer(_ answer: String) { nextAnswer = answer }
    func setPublishFails(_ value: Bool) { publishFails = value }
}

struct Fixture {
    let directory: URL
    let store: LocalStateStore
    let approvals: FolderApprovals
    init() throws {
        directory = Self.root.appendingPathComponent(UUID().uuidString)
        store = try LocalStateStore(directory: directory)
        approvals = FolderApprovals(file: directory.appendingPathComponent("allowlist.json"))
        try approvals.approve(projectID: "project", folder: directory)
    }
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/test-runtime")
    }
    func job(project: String = "project") -> RunnerJob {
        RunnerJob(projectID: project, generation: 7, leaseExpiresAt: Date().addingTimeInterval(60), prompt: "Work")
    }
    func runner(_ server: FakeServer, _ provider: FakeProvider) throws -> Runner {
        try Runner(server: server, provider: provider, store: store, approvals: approvals)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<300 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Condition did not become true")
    throw RunnerError.timedOut
}

@Test func resultRequiresReviewAndPersistsCheckpoint() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let job = f.job(), provider = FakeProvider(), server = FakeServer([job])
    let runner = try f.runner(server, provider)
    try await runner.tick()
    let local = try #require(await runner.snapshot().first)
    #expect(local.job.generation == 7)
    #expect(await local.sessionID == provider.requests.first?.sessionID)
    await provider.complete(try #require(local.process).pid)
    try await eventually { await server.events.count == 1 }
    #expect(await server.events.first?.1.phase == .awaitingReview)
    let saved = try #require(f.store.load().first)
    #expect(saved.sessionID == local.sessionID)
    #expect(saved.checkpoint == "Done")
    #expect(saved.phase == .awaitingReview)
}

@Test func doubleStartAndFolderAliasesArePrevented() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.approvals.approve(projectID: "alias", folder: f.directory)
    let provider = FakeProvider(), server = FakeServer([f.job(), f.job(project: "alias")])
    let runner = try f.runner(server, provider)
    try await runner.tick()
    async let first: Void = runner.tick()
    async let second: Void = runner.tick()
    _ = try await (first, second)
    #expect(await provider.requests.count == 1)
    #expect(await server.jobs.count == 1)
    let id = try #require(await runner.snapshot().first?.job.runID)
    try await runner.stop(runID: id)
    try await eventually { await runner.snapshot().first?.process == nil }
}

@Test func restartReconcilesBeforeClaimAndNeedsExplicitRecovery() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let old = LocalRun(job: f.job(), sessionID: UUID(), folder: f.directory,
                       process: ProcessReference(pid: 3456), phase: .running, checkpoint: "Old checkpoint")
    try f.store.save([old])
    let provider = FakeProvider(), server = FakeServer([f.job()])
    let runner = try f.runner(server, provider)
    try await runner.tick()
    #expect(await runner.snapshot().first?.phase == .needsReconciliation)
    #expect(await provider.requests.isEmpty)
    #expect(await server.claims.isEmpty)
    await #expect(throws: RunnerError.self) { try await runner.resume(runID: old.job.runID, prompt: "Recover") }
    await provider.setObservation(3456, .exited)
    try await runner.resume(runID: old.job.runID, prompt: "Continue from verified checkpoint")
    #expect(await provider.requests.first?.resume == true)
    #expect(await provider.requests.first?.sessionID == old.sessionID)
    try await runner.stop(runID: old.job.runID)
    try await eventually { await runner.snapshot().first?.process == nil }
}

@Test func launchIntentWithoutPIDNeverRestartsAutomatically() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.store.save([LocalRun(job: f.job(), sessionID: UUID(), folder: f.directory,
                              phase: .launching, checkpoint: "Intent")])
    let provider = FakeProvider(), server = FakeServer([f.job()])
    let runner = try f.runner(server, provider)
    try await runner.tick()
    #expect(await runner.snapshot().first?.phase == .needsReconciliation)
    #expect(await provider.requests.isEmpty)
}

@Test func leaseLossStopsWithoutPublishingAndKeepsFolderUntilExit() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let provider = FakeProvider(), server = FakeServer([f.job(), f.job()])
    await provider.setFinishOnStop(false)
    let runner = try f.runner(server, provider)
    try await runner.tick()
    let process = try #require(await runner.snapshot().first?.process)
    await server.setLost()
    try await runner.tick()
    #expect(await provider.stopped == [process])
    #expect(await runner.snapshot().first?.phase == .leaseLost)
    #expect(await provider.requests.count == 1)
    await provider.complete(process.pid)
    try await eventually { await runner.snapshot().first?.phase == .stopped }
    #expect(await server.events.isEmpty)
}

@Test func stopDoesNotReleaseFolderBeforeReaping() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let provider = FakeProvider(), server = FakeServer([f.job(), f.job()])
    await provider.setFinishOnStop(false)
    let runner = try f.runner(server, provider)
    try await runner.tick()
    let local = try #require(await runner.snapshot().first)
    try await runner.stop(runID: local.job.runID)
    try await runner.tick()
    #expect(await provider.requests.count == 1)
    #expect(await runner.snapshot().first?.phase == .stopping)
    await provider.complete(try #require(local.process).pid)
    try await eventually { await server.events.count == 1 }
    #expect(await server.events.first?.1.phase == .stopped)
}

@Test func questionPausesAndAnswerResumesSameSession() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let provider = FakeProvider(), server = FakeServer([f.job()])
    let runner = try f.runner(server, provider)
    try await runner.tick()
    let local = try #require(await runner.snapshot().first)
    await provider.complete(try #require(local.process).pid, AgentResult(text: "Need input", question: "Which option?"))
    try await eventually { await server.events.count == 1 }
    #expect(await runner.snapshot().first?.phase == .waitingForAnswer)
    await server.setAnswer("Option A")
    try await runner.tick()
    #expect(await provider.requests.count == 2)
    let request = try #require(await provider.requests.last)
    #expect(request.resume && request.sessionID == local.sessionID && request.prompt == "Option A")
    await provider.complete(100_002)
    try await eventually { await server.events.count == 2 }
    #expect(await server.events.last?.1.phase == .awaitingReview)
}

@Test func pendingResultRetriesWithoutRestartingAgent() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let provider = FakeProvider(), server = FakeServer([f.job()])
    await server.setPublishFails(true)
    let runner = try f.runner(server, provider)
    try await runner.tick()
    await provider.complete(100_001)
    try await eventually { await runner.snapshot().first?.pendingEvent != nil }
    await server.setPublishFails(false)
    try await runner.tick()
    #expect(await server.events.count == 1)
    #expect(await provider.requests.count == 1)
}

@Test func storeLocksAndRejectsCorruption() throws {
    let f = try Fixture(); defer { f.cleanup() }
    #expect(throws: RunnerError.self) { try LocalStateStore(directory: f.directory) }
    try Data("not JSON".utf8).write(to: f.directory.appendingPathComponent("runs.json"))
    #expect(throws: (any Error).self) { try f.store.load() }
}

@Test func unapprovedProjectsCannotStart() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let provider = FakeProvider(), server = FakeServer([f.job(project: "foreign")])
    let runner = try f.runner(server, provider)
    try await runner.tick()
    #expect(await provider.requests.isEmpty)
    #expect(await server.jobs.count == 1)
}
