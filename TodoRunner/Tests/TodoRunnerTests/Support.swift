import Foundation
import Darwin
@testable import TodoRunner

final class Fixture: @unchecked Sendable {
    let directory: URL
    let repo: URL
    let state: URL
    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("runner-test-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        repo = directory.appendingPathComponent("repo")
        state = directory.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }
    var allowlist: FolderAllowlist { FolderAllowlist(file: state.appendingPathComponent("allowlist.json")) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

/// Polls `condition` (ticking the runner in between) until it holds or the timeout hits.
func eventually(_ runner: Runner? = nil, timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        try? await runner?.tick()
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(15))
    }
    return false
}

actor FakeServer: RunnerServer {
    private(set) var calls: [String] = []
    var jobs: [Job] = []
    var bindings: [Binding] = []
    var runsByID: [UUID: Run] = [:]
    var questions: [Question] = []
    var heartbeatError: RunnerServerError?
    var writeErrors: [String: RunnerServerError] = [:]
    var claimConflict = false
    var lease: TimeInterval = 90
    var submitted: [RunResult] = []
    var asked: [(String, [String])] = []
    var checkpoints: [Checkpoint] = []

    func add(job: Job, binding: Binding) { jobs.append(job); if !bindings.contains(where: { $0.id == binding.id }) { bindings.append(binding) } }
    func set(heartbeatError e: RunnerServerError?) { heartbeatError = e }
    func set(writeError e: RunnerServerError?, for name: String) { writeErrors[name] = e }
    func set(lease l: TimeInterval) { lease = l }
    func setClaimConflict() { claimConflict = true }
    func setQuestions(_ q: [Question]) { questions = q }
    func answerAll(_ text: String) { questions = questions.map { var q = $0; q.answer = text; return q } }
    func insert(run: Run) { runsByID[run.id] = run }
    func cancel(jobID: UUID) {
        for (id, var run) in runsByID where run.job.id == jobID { run.job.state = .cancelled; runsByID[id] = run }
    }
    func count(_ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }
    func index(of prefix: String) -> Int? { calls.firstIndex { $0.hasPrefix(prefix) } }
    func generation(of runID: UUID) -> Int? { runsByID[runID]?.generation }
    func state(of runID: UUID) -> JobState? { runsByID[runID]?.job.state }
    func firstRunID() -> UUID? { runsByID.keys.first }

    private func record(_ s: String) { calls.append(s) }

    func bindings() async throws -> [Binding] { record("bindings"); return bindings }
    func jobs() async throws -> [Job] { record("jobs"); return jobs.filter { $0.state == .queued } }
    func detail(jobID: UUID) async throws -> JobDetail {
        record("detail")
        let job = jobs.first { $0.id == jobID } ?? runsByID.values.first { $0.job.id == jobID }!.job
        return JobDetail(job: job, task: TaskInfo(id: job.taskID, title: "Fix the thing", description: "Details here", version: job.taskRevision),
                         questions: questions)
    }
    func claim(jobID: UUID) async throws -> Run {
        record("claim")
        if claimConflict { throw RunnerServerError.conflict("repository busy") }
        // Mirrors the server rule: one open run per repository for this device.
        guard let i = jobs.firstIndex(where: { $0.id == jobID && $0.state == .queued }) else { throw RunnerServerError.notFound }
        jobs[i].state = .claimed
        let run = Run(job: jobs[i], generation: 1, leaseUntil: Date().addingTimeInterval(lease))
        runsByID[run.id] = run
        return run
    }
    func runs() async throws -> [Run] { record("runs"); return Array(runsByID.values.filter { $0.endedAt == nil }) }

    private func write(_ name: String, _ runID: UUID, _ generation: Int, state: JobState? = nil, end: Bool = false) throws -> Run {
        record("\(name) g\(generation)")
        if let e = writeErrors[name] { throw e }
        guard var run = runsByID[runID] else { throw RunnerServerError.notFound }
        guard run.generation == generation else { throw RunnerServerError.conflict("stale generation") }
        if run.endedAt != nil { throw RunnerServerError.gone("ended") }
        run.leaseUntil = Date().addingTimeInterval(lease)
        if let state, run.job.state != .cancelled { run.job.state = state }
        if end { run.endedAt = Date() }
        runsByID[runID] = run
        return run
    }
    func heartbeat(runID: UUID, generation: Int) async throws -> Run {
        if let e = heartbeatError { record("heartbeat"); throw e }
        return try write("heartbeat", runID, generation)
    }
    func progress(runID: UUID, generation: Int, text: String) async throws -> Run { try write("progress", runID, generation, state: .running) }
    func checkpoint(runID: UUID, generation: Int, checkpoint: Checkpoint) async throws -> Run {
        let r = try write("checkpoint", runID, generation); checkpoints.append(checkpoint); return r
    }
    func question(runID: UUID, generation: Int, prompt: String, options: [String]) async throws -> Run {
        let r = try write("question", runID, generation, state: .waitingForAnswer)
        asked.append((prompt, options))
        questions.append(Question(prompt: prompt, options: options))
        return r
    }
    func resume(runID: UUID, generation: Int) async throws -> Run { try write("resume", runID, generation, state: .running) }
    func submit(runID: UUID, generation: Int, result: RunResult) async throws -> Run {
        let r = try write("submit", runID, generation, state: .awaitingReview, end: true); submitted.append(result); return r
    }
    func stop(runID: UUID, generation: Int) async throws -> Run { try write("stop", runID, generation, state: .cancelled, end: true) }
    func fail(runID: UUID, generation: Int) async throws -> Run { try write("fail", runID, generation, state: .failed, end: true) }
    func reconcile(runID: UUID, generation: Int, observation: ReconcileObservation) async throws -> Run {
        record("reconcile \(observation.rawValue) g\(generation)")
        if let e = writeErrors["reconcile"] { throw e }
        guard var run = runsByID[runID] else { throw RunnerServerError.notFound }
        guard run.generation == generation else { throw RunnerServerError.conflict("stale generation") }
        run.generation += 1
        run.leaseUntil = Date().addingTimeInterval(lease)
        if observation == .stopped { if run.job.state != .cancelled { run.job.state = .failed }; run.endedAt = Date() }
        runsByID[runID] = run
        return run
    }
}

actor FakeProvider: AgentProvider {
    private(set) var requests: [AgentRequest] = []
    private(set) var stopped: [Int32] = []
    private var outcomes: [Int32: Result<AgentResult, Error>] = [:]
    private var observations: [Int32: ProcessObservation] = [:]
    private var next: Int32 = 5000
    var startError: Error?

    func set(startError e: Error?) { startError = e }
    func finish(_ pid: Int32, _ result: AgentResult) { outcomes[pid] = .success(result) }
    func observe(_ pid: Int32, _ o: ProcessObservation) { observations[pid] = o }
    func lastPID() -> Int32 { next - 1 }

    func start(_ request: AgentRequest) async throws -> ProcessReference {
        if let startError { throw startError }
        requests.append(request)
        let pid = next; next += 1
        observations[pid] = .running
        return ProcessReference(pid: pid, startTime: 1, outputPath: "", sessionID: request.sessionID)
    }
    func wait(for process: ProcessReference) async throws -> AgentResult {
        while outcomes[process.pid] == nil { try await Task.sleep(for: .milliseconds(5)) }
        observations[process.pid] = .exited
        return try outcomes[process.pid]!.get()
    }
    func stop(_ process: ProcessReference) {
        guard observations[process.pid] == .running || observations[process.pid] == nil else { return }
        stopped.append(process.pid)
        observations[process.pid] = .exited
        outcomes[process.pid] = .failure(RunnerError.stopped)
    }
    func reconcile(_ process: ProcessReference) -> ProcessObservation { observations[process.pid] ?? .exited }
}

func makeJob(binding: Binding, mode: JobMode = .implement) -> Job { Job(bindingID: binding.id, mode: mode, scope: "Fix the bug in main.swift") }

func makeRunner(_ f: Fixture, server: FakeServer, provider: FakeProvider, settings: RunnerSettings = RunnerSettings()) throws -> Runner {
    try Runner(server: server, provider: provider, store: LocalStateStore(directory: f.state), allowlist: f.allowlist, settings: settings)
}
