import Foundation

public actor Runner {
    private let server: any RunnerServer
    private let provider: any AgentProvider
    private let store: LocalStateStore
    private let approvals: FolderApprovals
    private let timeout: TimeInterval
    private var runs: [LocalRun]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var ready = false
    private var ticking = false

    public init(server: any RunnerServer, provider: any AgentProvider, store: LocalStateStore,
                approvals: FolderApprovals, timeout: TimeInterval = 300) throws {
        self.server = server; self.provider = provider; self.store = store
        self.approvals = approvals; self.timeout = timeout; runs = try store.load()
    }
    public func snapshot() -> [LocalRun] { runs }
    private func save() throws { try store.save(runs) }
    private func index(_ id: UUID) -> Int { runs.firstIndex { $0.job.runID == id }! }

    /// Recovered processes cannot be reattached through POSIX waitpid. Keep the
    /// folder reserved and require explicit recovery; never replay an old prompt.
    public func reconcile() async throws {
        guard !ready else { return }
        for i in runs.indices where runs[i].phase.reservesFolder {
            let observation: ProcessObservation
            if let process = runs[i].process { observation = await provider.reconcile(process) }
            else { observation = .exited }
            if runs[i].phase == .waitingForAnswer && runs[i].process == nil { continue }
            runs[i].phase = .needsReconciliation
            switch observation {
            case .exited:
                runs[i].process = nil
                runs[i].checkpoint = "Process exited; explicit checkpoint-based recovery required."
            case .running, .uncertain:
                runs[i].checkpoint = "Existing process requires identity verification; folder remains reserved."
            }
        }
        try save()
        ready = true
    }

    /// Call periodically, or use runLoop. A slow transport never causes parallel claims.
    public func tick() async throws {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        try await reconcile()
        for id in runs.map({ $0.job.runID }) {
            let i = index(id)
            if runs[i].phase == .leaseLost { continue }
            if runs[i].phase.reservesFolder || runs[i].pendingEvent != nil {
                guard try await renew(id) else { continue }
                try await flush(id)
                if runs[i].phase == .waitingForAnswer, let answer = try await server.answer(for: runs[i].job) {
                    try await resume(runID: id, prompt: answer)
                }
            }
        }
        let bindings = try approvals.bindings()
        let busy = Set(runs.filter { $0.phase.reservesFolder || $0.process != nil }.map { $0.folder.path })
        let eligible = bindings.filter { !busy.contains($0.value.path) }.map(\.key).sorted()
        guard !eligible.isEmpty, let job = try await server.claim(eligibleProjects: eligible) else { return }
        guard eligible.contains(job.projectID), let folder = bindings[job.projectID],
              job.leaseExpiresAt > Date(), !runs.contains(where: { $0.job.runID == job.runID }) else {
            throw RunnerError.invalidConfiguration
        }
        let run = LocalRun(job: job, sessionID: UUID(), folder: folder, process: nil,
                           phase: .launching, checkpoint: "Claim persisted before process launch.")
        runs.append(run)
        try save()
        try await launch(job.runID, prompt: job.prompt, resume: false)
    }

    private func renew(_ id: UUID) async throws -> Bool {
        let i = index(id)
        guard runs[i].phase != .leaseLost else { return false }
        let expiry: Date?
        do { expiry = try await server.renew(runs[i].job) }
        catch {
            // Fail closed on network uncertainty. No publication or new work.
            await loseLease(id)
            throw error
        }
        guard let expiry, expiry > Date(), runs[i].phase != .leaseLost else {
            await loseLease(id); return false
        }
        runs[i].job.leaseExpiresAt = expiry
        try save()
        return true
    }

    private func loseLease(_ id: UUID) async {
        let i = index(id)
        runs[i].phase = .leaseLost
        runs[i].pendingEvent = nil
        runs[i].checkpoint = "Ownership lost; publication disabled."
        // Even if persisting fails, the in-memory fence is already closed.
        try? save()
        if let process = runs[i].process { await provider.stop(process) }
    }

    private func launch(_ id: UUID, prompt: String, resume: Bool) async throws {
        let i = index(id)
        guard try approvals.bindings()[runs[i].job.projectID] == runs[i].folder else {
            throw RunnerError.unapprovedFolder
        }
        guard try await renew(id) else { return }
        runs[i].phase = .launching
        runs[i].checkpoint = "Launch intent persisted; reconcile before any retry."
        try save()
        let request = AgentRequest(sessionID: runs[i].sessionID, folder: runs[i].folder,
                                   prompt: prompt, resume: resume, allowedTools: runs[i].job.allowedTools,
                                   maxTurns: runs[i].job.maxTurns, timeout: timeout)
        let process: ProcessReference
        do { process = try await provider.start(request) }
        catch {
            guard runs[i].phase == .launching else { throw error }
            runs[i].phase = .failed
            runs[i].checkpoint = "Provider launch failed."
            runs[i].pendingEvent = RunnerEvent(phase: .failed, checkpoint: runs[i].checkpoint)
            try save()
            throw error
        }
        runs[i].process = process
        // A stop or heartbeat may have arrived while start was suspended.
        guard runs[i].phase == .launching else {
            await provider.stop(process)
            tasks[id] = Task { await self.finish(id, process: process) }
            return
        }
        runs[i].phase = .running
        runs[i].checkpoint = "Agent process running."
        do { try save() }
        catch { await loseLease(id); tasks[id] = Task { await self.finish(id, process: process) }; throw error }
        tasks[id] = Task { await self.finish(id, process: process) }
    }

    private func finish(_ id: UUID, process: ProcessReference) async {
        let result: AgentResult
        do { result = try await provider.wait(for: process) }
        catch { result = AgentResult(text: "Provider execution interrupted or failed.", exitStatus: -1, isError: true) }
        let i = index(id)
        runs[i].process = nil
        tasks[id] = nil
        if runs[i].phase == .leaseLost {
            runs[i].phase = .stopped
            runs[i].checkpoint = "Process reaped after lease loss; no owner event published."
            try? save(); return
        }
        if runs[i].phase == .stopping {
            runs[i].phase = .stopped
        } else if runs[i].phase != .stopped {
            runs[i].phase = result.isError ? .failed : (result.question == nil ? .awaitingReview : .waitingForAnswer)
            runs[i].checkpoint = result.question ?? result.text
            runs[i].pendingEvent = RunnerEvent(phase: runs[i].phase, checkpoint: runs[i].checkpoint, result: result)
        }
        do {
            try save()
            guard try await renew(id) else { return }
            try await flush(id)
        } catch {
            // Durable pending events are retried by tick; never restart the agent.
        }
    }

    private func flush(_ id: UUID) async throws {
        let i = index(id)
        guard runs[i].phase != .leaseLost, runs[i].job.leaseExpiresAt > Date(),
              let event = runs[i].pendingEvent else { return }
        try await server.publish(event, for: runs[i].job)
        runs[i].pendingEvent = nil
        try save()
    }

    public func resume(runID id: UUID, prompt: String) async throws {
        guard ready, let i = runs.firstIndex(where: { $0.job.runID == id }),
              runs[i].phase == .waitingForAnswer || runs[i].phase == .needsReconciliation,
              runs[i].pendingEvent == nil else { throw RunnerError.invalidConfiguration }
        if let process = runs[i].process {
            guard await provider.reconcile(process) == .exited else { throw RunnerError.unknownProcess }
            runs[i].process = nil
        }
        // Reserve the phase before the first suspension to prevent concurrent resumes.
        runs[i].phase = .launching
        try save()
        try await launch(id, prompt: prompt, resume: true)
    }

    public func stop(runID id: UUID) async throws {
        guard let i = runs.firstIndex(where: { $0.job.runID == id }) else { throw RunnerError.invalidConfiguration }
        guard runs[i].phase != .needsReconciliation else { throw RunnerError.unknownProcess }
        guard try await renew(id) else { return }
        let launching = runs[i].phase == .launching
        runs[i].phase = .stopping
        runs[i].checkpoint = "Stopped by local operator."
        runs[i].pendingEvent = RunnerEvent(phase: .stopped, checkpoint: runs[i].checkpoint)
        try save()
        if let process = runs[i].process { await provider.stop(process) }
        else if !launching {
            runs[i].phase = .stopped
            try save()
            try await flush(id)
        }
    }

    public func runLoop(interval: Duration = .seconds(1)) async throws {
        while !Task.isCancelled {
            try await tick()
            try await Task.sleep(for: interval)
        }
    }
}
