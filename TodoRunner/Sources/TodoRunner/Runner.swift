import Foundation

public struct RunnerSettings: Sendable {
    public var maxTurns = 20
    public var timeout: TimeInterval = 1800
    public var clarifyTools = ["Read", "Glob", "Grep"]
    public var implementTools = ["Read", "Glob", "Grep", "Edit", "Write"]
    public var now: @Sendable () -> Date = { Date() }
    /// Minimum time between two progress messages of one run; tool steps in between are summarised.
    public var progressInterval: TimeInterval = 30
    /// After a detected wake-up the runner re-adopts expired leases for this long (the network may need a moment).
    public var wakeGrace: TimeInterval = 300
    /// Receives human-readable log lines (the CLI redacts and persists them).
    public var log: @Sendable (String) -> Void = { _ in }
    /// Keeps the Mac awake while an agent process runs.
    public var activity: any ActivityAssertion = NoActivityAssertion()
    public init() {}
}

/// Prevents idle system sleep while agent processes run. A closed lid or low battery still sleeps the Mac;
/// that case is handled by the wake-up recovery in `Runner`.
public protocol ActivityAssertion: Sendable {
    func begin()
    func end()
}

public struct NoActivityAssertion: ActivityAssertion {
    public init() {}
    public func begin() {}
    public func end() {}
}

/// `ProcessInfo.beginActivity` with idle-system-sleep disabled (display may still sleep and lock).
public final class ProcessInfoActivityAssertion: ActivityAssertion, @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?
    public init() {}
    public func begin() {
        lock.withLock {
            guard token == nil else { return }
            token = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                                                          reason: "Todo Runner: Claude-Code-Lauf aktiv")
        }
    }
    public func end() {
        lock.withLock {
            if let token { ProcessInfo.processInfo.endActivity(token) }
            token = nil
        }
    }
}

/// Runner state machine. Rules enforced here:
/// - Local state is persisted before every external effect (claim, spawn, publish).
/// - At most one non-closed run per canonical folder; no automatic re-execution of a prompt.
/// - After startup the runner reconciles local state with the server BEFORE it claims anything.
/// - Every server write carries the generation; losing the lease (409/410 or local expiry)
///   permanently fences publishing for that run.
public actor Runner {
    private let server: any RunnerServer
    private let provider: any AgentProvider
    private let store: LocalStateStore
    private let allowlist: FolderAllowlist
    private let settings: RunnerSettings
    private var runs: [UUID: LocalRun]
    private var watchers: [UUID: Task<Void, Never>] = [:]
    private var startupPending: Set<UUID>
    private var startupDone = false
    private var ticking = false
    /// Actor reentrancy: only one outbox flush per run at a time, or steps would be sent twice.
    private var flushing: Set<UUID> = []
    public private(set) var lastError: String? {
        didSet { if let error = lastError, error != oldValue { settings.log("Fehler: \(error)") } }
    }
    private var progressState: [UUID: ProgressAggregator] = [:]
    private var progressSent: [UUID: Date] = [:]
    private var wakeGraceUntil: Date?
    private var activityHeld = false

    public init(server: any RunnerServer, provider: any AgentProvider, store: LocalStateStore,
                allowlist: FolderAllowlist, settings: RunnerSettings = RunnerSettings()) throws {
        self.server = server; self.provider = provider; self.store = store
        self.allowlist = allowlist; self.settings = settings
        let loaded = try store.load()
        runs = Dictionary(uniqueKeysWithValues: loaded.map { ($0.runID, $0) })
        startupPending = Set(loaded.filter { $0.phase != .closed }.map(\.runID))
    }

    public func snapshot() -> [LocalRun] { runs.values.sorted { $0.runID.uuidString < $1.runID.uuidString } }
    private func persist() throws { try store.save(Array(runs.values)) }
    private var now: Date { settings.now() }

    private func mutate(_ id: UUID, _ change: (inout LocalRun) -> Void) {
        guard var run = runs[id] else { return }
        let oldNote = run.note, oldPhase = run.phase
        change(&run)
        runs[id] = run
        do { try persist() } catch { lastError = "State write failed: \(error)" }
        if run.note != oldNote || run.phase != oldPhase {
            settings.log("Lauf \(id.uuidString.prefix(8).lowercased()) [\(run.phase.rawValue)]: \(run.note)")
        }
        updateActivity()
    }

    private func updateActivity() {
        let needed = runs.values.contains { $0.phase == .launching || $0.phase == .running || $0.phase == .resuming }
        guard needed != activityHeld else { return }
        activityHeld = needed
        if needed { settings.activity.begin() } else { settings.activity.end() }
    }

    /// Call when the Mac woke up. For a grace period, expired leases of live runs are re-adopted
    /// instead of being treated as lost (the server decides; a refusal marks the run as interrupted).
    public func noteWake() {
        wakeGraceUntil = now.addingTimeInterval(settings.wakeGrace)
        settings.log("Aufwachen aus dem Ruhezustand erkannt; Leases werden neu uebernommen.")
    }

    /// True when the wall clock advanced noticeably more than the awake time, i.e. the Mac slept in between.
    static func sleptDuring(wall: Duration, awake: Duration, tolerance: Duration = .seconds(5)) -> Bool {
        wall - awake > tolerance
    }

    private func adopt(_ id: UUID, _ remote: Run) {
        mutate(id) {
            guard $0.phase != .leaseLost else { return }
            $0.generation = remote.generation; $0.leaseUntil = remote.leaseUntil; $0.job = remote.job
        }
    }

    // MARK: Loop

    public func tick() async throws { try await tick(claim: true) }

    func tick(claim: Bool) async throws {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        if !startupDone || !startupPending.isEmpty { try await reconcileAtStart() }
        for id in runs.keys.sorted(by: { $0.uuidString < $1.uuidString }) { await service(id) }
        if claim { try await claimNext() }
        updateActivity()
    }

    public func runLoop(interval: Duration = .seconds(15)) async {
        let continuous = ContinuousClock(), suspending = SuspendingClock()
        while !Task.isCancelled {
            let wallStart = continuous.now, awakeStart = suspending.now
            do { try await tick(); lastError = nil } catch { lastError = String(describing: error) }
            try? await Task.sleep(for: interval)
            if Self.sleptDuring(wall: wallStart.duration(to: continuous.now), awake: awakeStart.duration(to: suspending.now)) {
                noteWake()
            }
        }
    }

    /// Claims at most one job (unless a run is already active), works it until it is settled
    /// (closed, waiting for an answer or needing manual reconciliation) and returns the runs.
    public func runOnce(interval: Duration = .seconds(5), maxDuration: TimeInterval = 7200) async throws -> [LocalRun] {
        func isActive(_ run: LocalRun) -> Bool {
            ![RunPhase.closed, .waitingForAnswer, .needsReconciliation].contains(run.phase)
        }
        let known = Set(runs.keys)
        var allowClaim = !runs.values.contains(where: isActive)
        let deadline = now.addingTimeInterval(maxDuration)
        let continuous = ContinuousClock(), suspending = SuspendingClock()
        while !Task.isCancelled {
            let wallStart = continuous.now, awakeStart = suspending.now
            try await tick(claim: allowClaim)
            if runs.keys.contains(where: { !known.contains($0) }) { allowClaim = false }
            if !runs.values.contains(where: isActive), startupDone, startupPending.isEmpty { break }
            if now >= deadline { break }
            try? await Task.sleep(for: interval)
            if Self.sleptDuring(wall: wallStart.duration(to: continuous.now), awake: awakeStart.duration(to: suspending.now)) {
                noteWake()
            }
        }
        return snapshot()
    }

    // MARK: Startup reconciliation

    private func reconcileAtStart() async throws {
        let serverRuns = try await server.runs()
        let remote = Dictionary(uniqueKeysWithValues: serverRuns.map { ($0.id, $0) })
        for id in startupPending {
            guard let local = runs[id], local.phase != .closed else { startupPending.remove(id); continue }
            guard let current = remote[id] else {
                // Server no longer lists the run: finished or cancelled elsewhere.
                if let process = local.process { await provider.stop(process) }
                mutate(id) { $0.phase = .closed; $0.process = nil; $0.outbox = []; $0.note = "Run is no longer open on the server." }
                startupPending.remove(id); continue
            }
            if await reconcileStartup(id, remote: current) { startupPending.remove(id) }
        }
        // Server runs unknown locally: nothing was ever spawned for them (spawn follows persistence).
        for unknown in serverRuns where runs[unknown.id] == nil {
            _ = try? await server.reconcile(runID: unknown.id, generation: unknown.generation, observation: .stopped)
        }
        startupDone = true
    }

    /// Returns true when this run is settled for startup purposes.
    private func reconcileStartup(_ id: UUID, remote: Run) async -> Bool {
        adopt(id, remote)
        guard var local = runs[id] else { return true }
        if local.phase == .needsReconciliation || local.phase == .leaseLost { return true }
        let observation: ProcessObservation = if let p = local.process { await provider.reconcile(p) } else { .exited }
        let expired = now >= remote.leaseUntil
        if observation == .uncertain {
            mutate(id) { $0.phase = .needsReconciliation; $0.note = "Process identity cannot be verified; folder stays reserved. Verify, then run `release`." }
            return true
        }
        if remote.job.state == .cancelled {
            mutate(id) { $0.stopRequested = true }
            if let p = local.process { await provider.stop(p) }
            mutate(id) { $0.process = nil; $0.outbox = [.stop]; $0.afterOutbox = .closed }
            if expired { await loseLease(id, reason: "Cancelled while lease had expired.") } else { await flushOutbox(id) }
            return true
        }
        if observation == .running, let process = local.process {
            if expired {
                do { adopt(id, try await server.reconcile(runID: id, generation: remote.generation, observation: .alive)) }
                catch let error as RunnerServerError where error.isOwnershipLoss {
                    await loseLease(id, reason: "Server refused to re-adopt the running process."); return true
                } catch { lastError = "Startup reconcile deferred: \(error)"; return false }
            }
            mutate(id) { $0.phase = .running; $0.note = "Adopted running process after restart." }
            watch(id, process)
            return true
        }
        // The process (if any) is verified gone.
        switch local.phase {
        case .claimed:
            if expired { await loseLease(id, reason: "Claim lease expired before launch.") }
        case .waitingForAnswer:
            if expired && local.outbox.isEmpty {
                do { adopt(id, try await server.reconcile(runID: id, generation: remote.generation, observation: .paused)) }
                catch let error as RunnerServerError where error.isOwnershipLoss { await loseLease(id, reason: "Pause not confirmed.") }
                catch { lastError = "Startup reconcile deferred: \(error)"; return false }
            } else if expired { await loseLease(id, reason: "Lease expired with unsent events.") }
        case .running, .launching:
            guard let process = local.process else {
                mutate(id) { $0.phase = .needsReconciliation; $0.note = "Spawn outcome unknown after crash; no blind restart." }
                return true
            }
            if expired { await loseLease(id, reason: "Process ended while lease had expired.") }
            else {
                let outcome: Result<AgentResult, Error>
                do { outcome = .success(try await provider.wait(for: process)) } catch { outcome = .failure(error) }
                await processEnded(id, outcome)
            }
        case .resuming:
            if remote.job.state == .waitingForAnswer {
                mutate(id) { $0.phase = .waitingForAnswer; $0.deliveredQuestions = [] }
            } else {
                mutate(id) { $0.phase = .needsReconciliation; $0.note = "Resume interrupted; outcome unknown." }
            }
        default: break
        }
        local = runs[id] ?? local
        if expired, local.phase != .closed, local.phase != .leaseLost, local.phase != .needsReconciliation, !local.outbox.isEmpty {
            await loseLease(id, reason: "Lease expired with unsent events.")
        }
        return true
    }

    // MARK: Per-run servicing

    private func service(_ id: UUID) async {
        guard let run = runs[id], run.phase != .closed, run.phase != .needsReconciliation,
              !startupPending.contains(id) else { return }
        if run.phase == .leaseLost { await confirmLeaseLoss(id); return }
        if now >= run.leaseUntil {
            switch await recoverAfterWake(id) {
            case .recovered: break
            case .retryLater: return
            case .lost: await loseLease(id, reason: wakeGraceUntil == nil ? "Lease expired locally."
                                                    : "Interrupted by sleep: the server no longer accepts the lease."); return
            }
        }
        guard let run = runs[id] else { return }
        do {
            let remote = try await server.heartbeat(runID: id, generation: run.generation)
            adopt(id, remote)
            if remote.job.state == .cancelled { await cancelByServer(id) }
        } catch let error as RunnerServerError where error.isOwnershipLoss {
            await handleOwnershipLoss(id); return
        } catch { lastError = "Heartbeat failed: \(error)" }
        guard let current = runs[id], current.phase != .leaseLost, current.phase != .closed else { return }
        if current.phase == .claimed { await beginLaunch(id) }
        await flushOutbox(id)
        await pumpProgress(id)
        if let after = runs[id], after.phase == .waitingForAnswer, after.outbox.isEmpty { await tryResume(id) }
    }

    private enum WakeOutcome { case recovered, retryLater, lost }

    /// Within the wake grace period, tells the server that the run is still alive (or paused) so the expired lease is renewed.
    private func recoverAfterWake(_ id: UUID) async -> WakeOutcome {
        guard let grace = wakeGraceUntil, now < grace, let run = runs[id] else { return .lost }
        let observation: ReconcileObservation
        if let process = run.process {
            guard await provider.reconcile(process) == .running else { return .lost }
            observation = .alive
        } else if run.phase == .waitingForAnswer, run.outbox.isEmpty {
            observation = .paused
        } else { return .lost }
        do {
            adopt(id, try await server.reconcile(runID: id, generation: run.generation, observation: observation))
            mutate(id) { $0.note = "Mac aus dem Ruhezustand aufgewacht; Lauf wieder uebernommen." }
            return .recovered
        } catch let error as RunnerServerError where error.isOwnershipLoss {
            return .lost
        } catch {
            lastError = "Wake recovery deferred: \(error)"
            return .retryLater
        }
    }

    /// Streams tool steps from the agent output to the board, summarised and throttled.
    private func pumpProgress(_ id: UUID) async {
        guard let run = runs[id], run.phase == .running, let process = run.process, run.outbox.isEmpty,
              !run.stopRequested else { return }
        var aggregate = progressState[id] ?? ProgressAggregator()
        aggregate.add(await provider.drainProgress(process))
        progressState[id] = aggregate
        guard !aggregate.isEmpty, now.timeIntervalSince(progressSent[id] ?? .distantPast) >= settings.progressInterval,
              let current = runs[id], current.phase == .running else { return }
        do {
            adopt(id, try await server.progress(runID: id, generation: current.generation, text: aggregate.render()))
            progressState[id] = ProgressAggregator(); progressSent[id] = now
        } catch let error as RunnerServerError where error.isOwnershipLoss {
            await handleOwnershipLoss(id)
        } catch { lastError = "Progress deferred: \(error)" }
    }

    private func handleOwnershipLoss(_ id: UUID) async {
        // A heartbeat can be in flight while the result is published (actor reentrancy): the server then answers
        // 410 run_ended for a run this runner already closed cleanly. Nothing to fence or confirm.
        guard let phase = runs[id]?.phase, phase != .closed else { return }
        if let process = runs[id]?.process { await provider.stop(process) }
        // A human stop reports 410 "local stop required": confirm it instead of treating it as lost.
        if let list = try? await server.runs(), let remote = list.first(where: { $0.id == id }),
           remote.job.state == .cancelled, remote.generation == runs[id]?.generation, now < remote.leaseUntil {
            adopt(id, remote)
            await cancelByServer(id)
        } else {
            await loseLease(id, reason: "Server rejected generation or lease.")
        }
    }

    private func cancelByServer(_ id: UUID) async {
        guard let run = runs[id], !run.stopRequested else { return }
        mutate(id) { $0.stopRequested = true }
        if let process = run.process { await provider.stop(process) }
        else {
            mutate(id) { $0.outbox = [.stop]; $0.afterOutbox = .closed }
            await flushOutbox(id)
        }
    }

    /// Closes the publication fence first, then kills the process. Nothing is sent for this run afterwards
    /// except the final reconcile(stopped) confirmation.
    private func loseLease(_ id: UUID, reason: String) async {
        mutate(id) { $0.phase = .leaseLost; $0.outbox = []; $0.afterOutbox = nil; $0.note = "Ownership lost: \(reason)" }
        if let process = runs[id]?.process { await provider.stop(process) }
        await confirmLeaseLoss(id)
    }

    private func confirmLeaseLoss(_ id: UUID) async {
        guard let run = runs[id], run.phase == .leaseLost else { return }
        if let process = run.process {
            await provider.stop(process)
            guard await provider.reconcile(process) == .exited else { return }
            mutate(id) { $0.process = nil }
        }
        do {
            _ = try await server.reconcile(runID: id, generation: run.generation, observation: .stopped)
            mutate(id) { $0.phase = .closed; $0.note += " Local stop confirmed." }
        } catch let error as RunnerServerError where error.isOwnershipLoss {
            mutate(id) { $0.phase = .closed; $0.note += " Run already settled on the server." }
        } catch { lastError = "Lease-loss confirmation deferred: \(error)" }
    }

    // MARK: Outbox

    private func flushOutbox(_ id: UUID) async {
        guard flushing.insert(id).inserted else { return }
        defer { flushing.remove(id) }
        while let run = runs[id], run.phase != .leaseLost, run.phase != .closed, let step = run.outbox.first {
            guard now < run.leaseUntil else { await loseLease(id, reason: "Lease expired before publishing."); return }
            do {
                let remote: Run
                switch step {
                case .checkpoint(let c): remote = try await server.checkpoint(runID: id, generation: run.generation, checkpoint: c)
                case .question(let prompt, let options):
                    remote = try await server.question(runID: id, generation: run.generation, prompt: prompt, options: options)
                case .submit(let result): remote = try await server.submit(runID: id, generation: run.generation, result: result)
                case .fail: remote = try await server.fail(runID: id, generation: run.generation)
                case .stop: remote = try await server.stop(runID: id, generation: run.generation)
                }
                adopt(id, remote)
                mutate(id) { if $0.outbox.first == step { $0.outbox.removeFirst() } }
            } catch let error as RunnerServerError where error.isOwnershipLoss {
                await loseLease(id, reason: "Publish rejected (\(error)).")
                return
            } catch RunnerServerError.badRequest(let reason) where step != .fail && step != .stop {
                // A permanent rejection will not heal by retrying: report the run as failed instead of looping.
                mutate(id) {
                    $0.outbox = [.fail]; $0.afterOutbox = .closed
                    $0.note = "Server rejected \(step) (\(reason)); reporting failure."
                }
            } catch { lastError = "Publish deferred: \(error)"; return }
        }
        if let run = runs[id], run.outbox.isEmpty, run.phase != .leaseLost, let after = run.afterOutbox {
            mutate(id) { $0.phase = after; $0.afterOutbox = nil }
        }
    }

    // MARK: Claim and launch

    private func claimNext() async throws {
        guard startupDone, startupPending.isEmpty else { return }
        let busy = Set(runs.values.filter { $0.phase.reservesFolder }.map(\.folder))
        let jobs = try await server.jobs().filter { $0.state == .queued }
        guard !jobs.isEmpty else { return }
        let bindings = try await server.bindings()
        for job in jobs {
            guard let binding = bindings.first(where: { $0.id == job.bindingID }),
                  let folder = try? allowlist.folder(for: binding.repositoryKey),
                  !busy.contains(folder.path) else { continue }
            let claimed: Run
            do { claimed = try await server.claim(jobID: job.id) }
            catch let error as RunnerServerError where error.isOwnershipLoss || error == .notFound { continue }
            let local = LocalRun(runID: claimed.id, job: claimed.job, repositoryKey: binding.repositoryKey, folder: folder.path,
                                 sessionID: UUID(), generation: claimed.generation, leaseUntil: claimed.leaseUntil,
                                 phase: .claimed, process: nil, contextRevision: claimed.job.taskRevision,
                                 note: "Claimed; nothing launched yet.")
            runs[claimed.id] = local
            try persist()
            await beginLaunch(claimed.id)
            return
        }
    }

    private func beginLaunch(_ id: UUID) async {
        guard let run = runs[id], run.phase == .claimed else { return }
        guard let detail = try? await server.detail(jobID: run.job.id) else { return }
        await launch(id, prompt: Self.prompt(for: detail, answers: []), resume: false)
    }

    static func prompt(for detail: JobDetail, answers: [Question]) -> String {
        var lines = [
            "Task: \(detail.task.title) (task revision \(detail.task.version), released at revision \(detail.job.taskRevision))",
            detail.task.description,
            "Scope: \(detail.job.scope)",
            detail.job.mode == .clarify
                ? "Mode: clarify. Do not modify any file. Identify what is unclear and ask or summarise."
                : "Mode: implement. Make the changes within the scope. Do not commit, push or deploy.",
        ]
        lines.append("If Todo MCP tools are available in this session, call get_manual first and follow it for progress notes and questions; otherwise continue without it.")
        if !answers.isEmpty {
            lines.append("Answers to your earlier questions:")
            lines += answers.map { "- Q: \($0.prompt)\n  A: \($0.answer ?? "")" }
        }
        return lines.joined(separator: "\n")
    }

    private func launch(_ id: UUID, prompt: String, resume: Bool) async {
        guard let run = runs[id] else { return }
        let folder: URL
        do {
            guard let approved = try allowlist.folder(for: run.repositoryKey), approved.path == run.folder else { throw RunnerError.unapprovedFolder }
            folder = approved
        } catch {
            mutate(id) { $0.outbox = [.fail]; $0.afterOutbox = .closed; $0.note = "Folder no longer approved; not started." }
            await flushOutbox(id); return
        }
        mutate(id) { $0.phase = .launching; $0.note = "Launch intent persisted; never replayed automatically." }
        let tools = run.job.mode == .clarify ? settings.clarifyTools : settings.implementTools
        let request = AgentRequest(sessionID: run.sessionID, folder: folder, prompt: prompt, resume: resume,
                                   allowedTools: tools, maxTurns: settings.maxTurns, timeout: settings.timeout)
        let process: ProcessReference
        do { process = try await provider.start(request) }
        catch {
            mutate(id) { $0.outbox = [.fail]; $0.afterOutbox = .closed; $0.note = "Provider start failed: \(error)" }
            await flushOutbox(id); return
        }
        mutate(id) { $0.process = process }
        guard let after = runs[id], after.phase == .launching else {
            // Stopped or fenced while spawning: kill; the watcher reaps and reports nothing for a fenced run.
            await provider.stop(process)
            watch(id, process); return
        }
        mutate(id) { $0.phase = .running; $0.note = "Agent process running." }
        watch(id, process)
        if let r = runs[id] {
            progressSent[id] = now
            _ = try? await server.progress(runID: id, generation: r.generation, text: resume ? "Agent resumed." : "Agent started.")
        }
    }

    private func watch(_ id: UUID, _ process: ProcessReference) {
        guard watchers[id] == nil else { return }
        let provider = self.provider
        watchers[id] = Task { [weak self] in
            let outcome: Result<AgentResult, Error>
            do { outcome = .success(try await provider.wait(for: process)) } catch { outcome = .failure(error) }
            await self?.processEnded(id, outcome)
        }
    }

    private func processEnded(_ id: UUID, _ outcome: Result<AgentResult, Error>) async {
        watchers[id] = nil
        progressState[id] = nil; progressSent[id] = nil
        guard let run = runs[id] else { return }
        mutate(id) { $0.process = nil }
        guard run.phase == .running || run.phase == .launching else { return }
        var outbox: [OutboxStep]
        var after: RunPhase = .closed
        let reference = run.sessionID.uuidString.lowercased()
        if run.stopRequested {
            outbox = [.stop]
        } else {
            switch outcome {
            case .failure: outbox = [.fail]
            case .success(let result) where result.isError: outbox = [.fail]
            case .success(let result):
                if let question = result.question.map(Self.serverText) {
                    let options = Array(result.options.prefix(20)).map { String($0.prefix(500)) }
                    outbox = [.checkpoint(Checkpoint(contextRevision: run.contextRevision, sessionReference: reference,
                                                     nextStep: "Waiting for human answer: \(question)")),
                              .question(prompt: question, options: options)]
                    after = .waitingForAnswer
                } else {
                    let limitation = run.job.mode == .clarify ? "Clarification only; no files changed." : "Runner did not execute checks itself."
                    outbox = [.checkpoint(Checkpoint(contextRevision: run.contextRevision, sessionReference: reference,
                                                     nextStep: "Awaiting human review.")),
                              .submit(RunResult(summary: Self.serverText(result.text), limitations: [limitation]))]
                }
            }
        }
        mutate(id) { $0.outbox = outbox; $0.afterOutbox = after; $0.note = "Process ended; publishing result." }
        await flushOutbox(id)
    }

    /// The server rejects blank text and anything over 4000 characters (400); an oversized or empty agent answer
    /// must not make the publication retry forever.
    static func serverText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(no text returned by the agent)" }
        return trimmed.count <= 4000 ? trimmed : String(trimmed.prefix(3980)) + "\n[truncated]"
    }

    private func tryResume(_ id: UUID) async {
        guard let run = runs[id], run.phase == .waitingForAnswer, run.outbox.isEmpty,
              let detail = try? await server.detail(jobID: run.job.id) else { return }
        guard !detail.questions.isEmpty, !detail.questions.contains(where: { $0.answer == nil }) else { return }
        let fresh = detail.questions.filter { !run.deliveredQuestions.contains($0.id) }
        guard !fresh.isEmpty, runs[id]?.phase == .waitingForAnswer else { return }
        let prompt = Self.prompt(for: detail, answers: fresh)
        mutate(id) { $0.phase = .resuming; $0.deliveredQuestions += fresh.map(\.id) }
        do { adopt(id, try await server.resume(runID: id, generation: run.generation)) }
        catch let error as RunnerServerError where error.isOwnershipLoss {
            await loseLease(id, reason: "Resume rejected (\(error))."); return
        } catch {
            mutate(id) { $0.phase = .waitingForAnswer; $0.deliveredQuestions.removeAll { id in fresh.contains { $0.id == id } } }
            lastError = "Resume deferred: \(error)"; return
        }
        await launch(id, prompt: prompt, resume: true)
    }

    // MARK: Operator actions

    /// Stops the local process and confirms the stop to the server (job becomes cancelled).
    public func stop(runID id: UUID) async throws {
        guard let run = runs[id], run.phase != .closed else { throw RunnerError.invalidConfiguration }
        guard run.phase != .needsReconciliation else { throw RunnerError.unknownProcess }
        mutate(id) { $0.stopRequested = true }
        if let process = run.process { await provider.stop(process) }
        else if run.phase != .leaseLost {
            mutate(id) { $0.outbox = [.stop]; $0.afterOutbox = .closed }
            await flushOutbox(id)
        }
    }

    /// Operator confirms that no agent process of an ambiguous run exists; frees the server's repository seat.
    public func release(runID id: UUID) async throws {
        guard let run = runs[id], run.phase == .needsReconciliation else { throw RunnerError.invalidConfiguration }
        if let process = run.process, await provider.reconcile(process) != .exited { throw RunnerError.unknownProcess }
        _ = try await server.reconcile(runID: id, generation: run.generation, observation: .stopped)
        mutate(id) { $0.phase = .closed; $0.process = nil; $0.note = "Released by operator after verification." }
    }
}
