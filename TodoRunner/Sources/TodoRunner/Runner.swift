import Foundation

public struct RunnerSettings: Sendable {
    public var maxTurns = 20
    public var timeout: TimeInterval = 1800
    public var clarifyTools = ["Read", "Glob", "Grep"]
    public var implementTools = ["Read", "Glob", "Grep", "Edit", "Write"]
    /// Time limit of the local budget command; exceeding it forbids new agent work.
    public var budgetTimeout: TimeInterval = 30
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
    private let commands: LocalCommands
    private let executor: any CommandExecutor
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
    /// Budget decision of the current tick (outer nil = not asked yet), so that one tick runs the command at most once.
    private var tickBudget: String??
    private var heldLogged: [UUID: String] = [:]

    public init(server: any RunnerServer, provider: any AgentProvider, store: LocalStateStore,
                allowlist: FolderAllowlist, settings: RunnerSettings = RunnerSettings(),
                commands: LocalCommands? = nil, executor: any CommandExecutor = ProcessCommandExecutor()) throws {
        self.server = server; self.provider = provider; self.store = store
        self.allowlist = allowlist; self.settings = settings
        self.commands = commands ?? LocalCommands(directory: store.directory); self.executor = executor
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
            let step = $0.job.pipelineStep
            $0.generation = remote.generation; $0.leaseUntil = remote.leaseUntil; $0.job = remote.job
            // The step decides which kind of process the run owns; it never changes during a run.
            $0.job.pipelineStep = remote.job.pipelineStep ?? step
        }
    }

    // MARK: Processes (agent or local command)

    private func isCommand(_ run: LocalRun) -> Bool { run.job.pipelineStep == .validation }

    private func halt(_ process: ProcessReference, of run: LocalRun) async {
        if isCommand(run) { await executor.stop(process) } else { await provider.stop(process) }
    }

    private func observe(_ process: ProcessReference, of run: LocalRun) async -> ProcessObservation {
        isCommand(run) ? await executor.reconcile(process) : await provider.reconcile(process)
    }

    // MARK: Loop

    public func tick() async throws { try await tick(claim: true) }

    func tick(claim: Bool) async throws {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        tickBudget = nil
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
                if let process = local.process { await halt(process, of: local) }
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
        let observation: ProcessObservation = if let p = local.process { await observe(p, of: local) } else { .exited }
        let expired = now >= remote.leaseUntil
        if observation == .uncertain {
            mutate(id) { $0.phase = .needsReconciliation; $0.note = "Process identity cannot be verified; folder stays reserved. Verify, then run `release`." }
            return true
        }
        if remote.job.state == .cancelled {
            mutate(id) { $0.stopRequested = true }
            if let p = local.process { await halt(p, of: local) }
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
            else { await collect(id, process, command: isCommand(local)) }
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
            guard await observe(process, of: run) == .running else { return .lost }
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
        guard let run = runs[id], run.phase == .running, !isCommand(run), let process = run.process, run.outbox.isEmpty,
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
        if let run = runs[id], let process = run.process { await halt(process, of: run) }
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
        if let process = run.process { await halt(process, of: run) }
        else {
            mutate(id) { $0.outbox = [.stop]; $0.afterOutbox = .closed }
            await flushOutbox(id)
        }
    }

    /// Closes the publication fence first, then kills the process. Nothing is sent for this run afterwards
    /// except the final reconcile(stopped) confirmation.
    private func loseLease(_ id: UUID, reason: String) async {
        mutate(id) { $0.phase = .leaseLost; $0.outbox = []; $0.afterOutbox = nil; $0.note = "Ownership lost: \(reason)" }
        if let run = runs[id], let process = run.process { await halt(process, of: run) }
        await confirmLeaseLoss(id)
    }

    private func confirmLeaseLoss(_ id: UUID) async {
        guard let run = runs[id], run.phase == .leaseLost else { return }
        if let process = run.process {
            await halt(process, of: run)
            guard await observe(process, of: run) == .exited else { return }
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
                case .submitStep(let result, let outcome, let plan):
                    remote = try await server.submitStep(runID: id, generation: run.generation, result: result, outcome: outcome, plan: plan)
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
            // Validation starts no agent and costs no tokens; everything else needs the budget's consent.
            if job.pipelineStep != .validation, let reason = await budgetRefusal() {
                await hold(job, reason: reason)
                continue
            }
            let claimed: Run
            do { claimed = try await server.claim(jobID: job.id) }
            catch let error as RunnerServerError where error.isOwnershipLoss || error == .notFound { continue }
            heldLogged[job.id] = nil
            var claimedJob = claimed.job
            claimedJob.pipelineStep = claimedJob.pipelineStep ?? job.pipelineStep
            let local = LocalRun(runID: claimed.id, job: claimedJob, repositoryKey: binding.repositoryKey, folder: folder.path,
                                 sessionID: UUID(), generation: claimed.generation, leaseUntil: claimed.leaseUntil,
                                 phase: .claimed, process: nil, contextRevision: claimed.job.taskRevision,
                                 note: "Claimed; nothing launched yet.")
            runs[claimed.id] = local
            try persist()
            await beginLaunch(claimed.id)
            return
        }
    }

    // MARK: Budget brake

    /// Why no agent may be started or resumed right now, nil if allowed. Fails closed: any doubt about a configured
    /// budget command forbids. Its output stays on this Mac; only these fixed texts reach the server.
    private func budgetRefusal() async -> String? {
        if let known = tickBudget { return known }
        let reason = await askBudget().map { "Kontingent-Bremse: " + $0 }
        tickBudget = .some(reason)
        return reason
    }

    private func askBudget() async -> String? {
        let argv: [String]
        do {
            guard let configured = try commands.budget() else { return nil }
            argv = configured
        } catch { return "Budget-Befehl nicht lesbar" }
        let scratch = store.directory.appendingPathComponent("budget-output", isDirectory: true)
        let name = UUID().uuidString
        let output = scratch.appendingPathComponent(name + ".stdout"), errors = scratch.appendingPathComponent(name + ".stderr")
        defer { for file in [output, errors] { try? FileManager.default.removeItem(at: file) } }
        do {
            let process = try await executor.start(CommandRequest(argv: argv, folder: store.directory, output: output,
                                                                  errorOutput: errors, timeout: settings.budgetTimeout))
            let result = try await executor.wait(for: process)
            guard let code = result.exitCode, code == 0 else { return "Budget-Befehl fehlgeschlagen" }
            return Self.budgetVerdict((try? Data(contentsOf: output)) ?? Data())
        } catch RunnerError.timedOut {
            return "Budget-Befehl hat das Zeitlimit überschritten"
        } catch {
            return "Budget-Befehl nicht ausführbar"
        }
    }

    /// Reads `{"allowed": Bool}` and/or `{"ampel": String}`; nil only for a readable answer that does not forbid.
    static func budgetVerdict(_ data: Data) -> String? {
        struct Answer: Decodable { var allowed: Bool?; var ampel: String? }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data), answer.allowed != nil || answer.ampel != nil else {
            return "Budget-Ausgabe unlesbar"
        }
        if answer.ampel?.lowercased() == "rot" { return "Ampel rot" }
        return answer.allowed == false ? "Budget nicht freigegeben" : nil
    }

    /// Best effort: an older server has no hold endpoint, and the job may be gone meanwhile.
    private func hold(_ job: Job, reason: String) async {
        if heldLogged[job.id] != reason {
            heldLogged[job.id] = reason
            settings.log("Auftrag \(job.id.uuidString.prefix(8).lowercased()) zurückgestellt. \(reason)")
        }
        guard job.progress != reason else { return }
        _ = try? await server.hold(jobID: job.id, reason: reason)
    }

    // MARK: Launch

    private func beginLaunch(_ id: UUID) async {
        guard let run = runs[id], run.phase == .claimed, run.outbox.isEmpty else { return }
        if isCommand(run) { await launchValidation(id); return }
        guard let detail = try? await server.detail(jobID: run.job.id) else { return }
        // Planner and developer continue an earlier session of this execution, but only one this runner ran in this folder.
        var resume = false
        if let step = run.job.pipelineStep, step == .planner || step == .developer,
           let session = detail.pipeline?.resumeSessionReference.flatMap({ UUID(uuidString: $0) }),
           runs.values.contains(where: { $0.runID != id && $0.sessionID == session && $0.folder == run.folder && !isCommand($0) }) {
            mutate(id) { $0.sessionID = session }
            resume = true
        }
        await launch(id, detail: detail, answers: [], resume: resume)
    }

    static func prompt(for detail: JobDetail, answers: [Question]) -> String {
        var lines = [
            "Task: \(detail.task.title) (task revision \(detail.task.version), released at revision \(detail.job.taskRevision))",
            detail.task.description,
            "Scope: \(detail.job.scope)",
        ]
        if let pipeline = detail.pipeline {
            lines += stepLines(pipeline)
        } else {
            lines.append(detail.job.mode == .clarify
                ? "Mode: clarify. Do not modify any file. Identify what is unclear and ask or summarise."
                : "Mode: implement. Make the changes within the scope. Do not commit, push or deploy.")
        }
        lines.append("If Todo MCP tools are available in this session, call get_manual first and follow it for progress notes and questions; otherwise continue without it.")
        if !answers.isEmpty {
            lines.append("Answers to your earlier questions:")
            lines += answers.map { "- Q: \($0.prompt)\n  A: \($0.answer ?? "")" }
        }
        return lines.joined(separator: "\n")
    }

    private static func stepLines(_ context: PipelineContext) -> [String] {
        let verdict = "Set the structured field `verdict` to \"passed\" only if everything holds, otherwise to \"failed\", and explain why in `text`."
        let instruction = switch context.step {
        case .planner: "Pipeline step: planner. Do not modify any file. Write the implementation plan as Markdown (at most 20000 characters), in the language of the task, into the structured field `plan`, and a short summary into `text`."
        case .developer: "Pipeline step: developer. Implement the plan within the scope. Do not commit, push or deploy."
        case .tester: "Pipeline step: tester. Check the change against the task and the plan; you may add or adjust tests. Do not commit, push or deploy. " + verdict
        case .review: "Pipeline step: review. Do not modify any file. Review the change against the task and the plan. " + verdict
        case .validation: "Pipeline step: validation."
        }
        var lines = [instruction]
        if let plan = context.planBody, !plan.isEmpty {
            let title = context.step == .planner ? "Previous plan" : "Plan"
            lines.append("\(title)\(context.planVersion.map { " (version \($0))" } ?? ""):\n\(plan)")
        }
        if let feedback = context.feedback, !feedback.isEmpty { lines.append("Feedback to take into account:\n\(feedback)") }
        return lines
    }

    /// The approved folder of the run, or nil after reporting the run as failed.
    private func approvedFolder(_ id: UUID) async -> URL? {
        guard let run = runs[id] else { return nil }
        if let approved = try? allowlist.folder(for: run.repositoryKey), approved.path == run.folder { return approved }
        mutate(id) { $0.outbox = [.fail]; $0.afterOutbox = .closed; $0.note = "Folder no longer approved; not started." }
        await flushOutbox(id)
        return nil
    }

    private func launch(_ id: UUID, detail: JobDetail, answers: [Question], resume: Bool) async {
        guard let run = runs[id], let folder = await approvedFolder(id) else { return }
        let step = run.job.pipelineStep
        if step != nil, detail.pipeline?.step != step {
            mutate(id) { $0.outbox = [.fail]; $0.afterOutbox = .closed; $0.note = "Pipeline context missing; not started." }
            await flushOutbox(id); return
        }
        mutate(id) { $0.phase = .launching; $0.note = "Launch intent persisted; never replayed automatically." }
        let readOnly = step.map { $0 != .developer && $0 != .tester } ?? (run.job.mode == .clarify)
        func checked(_ value: String?) -> String? {
            guard let value, ClaudeProcessAdapter.isAgentValue(value) else {
                if value != nil { settings.log("Ungültiger Modell- oder Aufwandswert vom Server ignoriert.") }
                return nil
            }
            return value
        }
        let request = AgentRequest(sessionID: run.sessionID, folder: folder, prompt: Self.prompt(for: detail, answers: answers),
                                   resume: resume, allowedTools: readOnly ? settings.clarifyTools : settings.implementTools,
                                   maxTurns: settings.maxTurns, timeout: settings.timeout, step: step,
                                   model: checked(detail.pipeline?.model), effort: checked(detail.pipeline?.effort))
        let process: ProcessReference
        do { process = try await provider.start(request) }
        catch {
            mutate(id) { $0.outbox = [.fail]; $0.afterOutbox = .closed; $0.note = "Provider start failed: \(error)" }
            await flushOutbox(id); return
        }
        await started(id, process, progress: resume ? "Agent resumed." : "Agent started.")
    }

    /// Validation: the locally configured command in the approved folder. No agent, no tokens.
    private func launchValidation(_ id: UUID) async {
        guard let run = runs[id], let folder = await approvedFolder(id) else { return }
        guard let command = try? commands.validation(for: run.repositoryKey) else {
            await finishValidation(id, .failed, "Kein Validierungsbefehl auf dem Runner eingerichtet (`todo-runner validation <Ordner> -- <Programm>`).")
            return
        }
        mutate(id) { $0.phase = .launching; $0.note = "Launch intent persisted; never replayed automatically." }
        let output = store.directory.appendingPathComponent("validation-output", isDirectory: true)
            .appendingPathComponent(run.repositoryKey.uuidString.lowercased() + ".log")
        let process: ProcessReference
        do {
            process = try await executor.start(CommandRequest(argv: command.argv, folder: folder, output: output, timeout: command.timeout))
        } catch {
            settings.log("Validierungsbefehl nicht gestartet: \(error)")
            await finishValidation(id, .failed, "Validierungsbefehl konnte nicht gestartet werden (Details im Runner-Log).")
            return
        }
        await started(id, process, progress: "Validierung gestartet.")
    }

    /// Publishes a validation result. Without a process the run counts as `claimed`, so a restart only resends it.
    private func finishValidation(_ id: UUID, _ outcome: PipelineOutcome, _ summary: String) async {
        mutate(id) {
            if $0.phase == .launching { $0.phase = .claimed }
            $0.outbox = [.submitStep(RunResult(summary: summary, limitations: ["Die Befehlsausgabe bleibt auf dem Runner."]),
                                     outcome: outcome, plan: nil)]
            $0.afterOutbox = .closed
            $0.note = summary
        }
        await flushOutbox(id)
    }

    private func started(_ id: UUID, _ process: ProcessReference, progress: String) async {
        mutate(id) { $0.process = process }
        guard let after = runs[id], after.phase == .launching else {
            // Stopped or fenced while spawning: kill; the watcher reaps and reports nothing for a fenced run.
            if let run = runs[id] { await halt(process, of: run) }
            watch(id, process); return
        }
        mutate(id) { $0.phase = .running; $0.note = isCommand($0) ? "Validation command running." : "Agent process running." }
        watch(id, process)
        if let r = runs[id] {
            progressSent[id] = now
            _ = try? await server.progress(runID: id, generation: r.generation, text: progress)
        }
    }

    private func watch(_ id: UUID, _ process: ProcessReference) {
        guard watchers[id] == nil, let run = runs[id] else { return }
        let command = isCommand(run)
        let provider = self.provider, executor = self.executor
        // Wait without holding the runner: a restarted runner must be able to take over the state folder.
        watchers[id] = Task { [weak self] in
            if command {
                let outcome: Result<CommandResult, Error>
                do { outcome = .success(try await executor.wait(for: process)) } catch { outcome = .failure(error) }
                await self?.commandEnded(id, process, outcome)
            } else {
                let outcome: Result<AgentResult, Error>
                do { outcome = .success(try await provider.wait(for: process)) } catch { outcome = .failure(error) }
                await self?.processEnded(id, outcome)
            }
        }
    }

    /// Waits for the process to end and publishes what it produced (startup adoption).
    private func collect(_ id: UUID, _ process: ProcessReference, command: Bool) async {
        if command {
            let outcome: Result<CommandResult, Error>
            do { outcome = .success(try await executor.wait(for: process)) } catch { outcome = .failure(error) }
            await commandEnded(id, process, outcome)
        } else {
            let outcome: Result<AgentResult, Error>
            do { outcome = .success(try await provider.wait(for: process)) } catch { outcome = .failure(error) }
            await processEnded(id, outcome)
        }
    }

    private func commandEnded(_ id: UUID, _ process: ProcessReference, _ outcome: Result<CommandResult, Error>) async {
        watchers[id] = nil
        progressSent[id] = nil
        guard let run = runs[id] else { return }
        mutate(id) { $0.process = nil }
        guard run.phase == .running || run.phase == .launching else { return }
        if run.stopRequested {
            mutate(id) { $0.outbox = [.stop]; $0.afterOutbox = .closed; $0.note = "Process ended; publishing result." }
            await flushOutbox(id); return
        }
        switch outcome {
        case .success(let result):
            let seconds = Int(result.duration.rounded())
            switch result.exitCode {
            case 0?: await finishValidation(id, .passed, "Validierung bestanden: Exit-Code 0 nach \(seconds) s.")
            case let code?: await finishValidation(id, .failed, "Validierung fehlgeschlagen: Exit-Code \(code) nach \(seconds) s.")
            case nil:
                await finishValidation(id, .failed, "Validierung ohne Ergebnis: Exit-Code unbekannt (Runner während des Laufs neu gestartet). Bitte wiederholen.")
            }
        case .failure(RunnerError.timedOut):
            let seconds = Int(process.deadline.timeIntervalSince1970 - process.startTime)
            await finishValidation(id, .failed, "Validierung abgebrochen: Zeitlimit nach \(max(0, seconds)) s überschritten.")
        case .failure:
            mutate(id) { $0.outbox = [.fail]; $0.afterOutbox = .closed; $0.note = "Validation command did not finish; publishing failure." }
            await flushOutbox(id)
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
                } else if let step = run.job.pipelineStep {
                    let (verdict, plan, summary) = Self.stepResult(step, result)
                    outbox = [.checkpoint(Checkpoint(contextRevision: run.contextRevision, sessionReference: reference,
                                                     nextStep: "Pipeline step \(step.rawValue) finished.")),
                              .submitStep(RunResult(summary: Self.serverText(summary), limitations: [Self.limitation(run.job.mode)]),
                                          outcome: verdict, plan: plan)]
                } else {
                    let limitation = Self.limitation(run.job.mode)
                    outbox = [.checkpoint(Checkpoint(contextRevision: run.contextRevision, sessionReference: reference,
                                                     nextStep: "Awaiting human review.")),
                              .submit(RunResult(summary: Self.serverText(result.text), limitations: [limitation]))]
                }
            }
        }
        mutate(id) { $0.outbox = outbox; $0.afterOutbox = after; $0.note = "Process ended; publishing result." }
        await flushOutbox(id)
    }

    private static func limitation(_ mode: JobMode) -> String {
        mode == .clarify ? "Clarification only; no files changed." : "Runner did not execute checks itself."
    }

    /// Maps the agent's structured answer to the step outcome. A missing plan or verdict never counts as passed.
    static func stepResult(_ step: PipelineStep, _ result: AgentResult) -> (PipelineOutcome, String?, String) {
        switch step {
        case .planner:
            guard let plan = result.plan, !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return (.failed, nil, "Der Planer lieferte keinen Plan.\n" + result.text)
            }
            guard plan.count <= 20000 else {
                return (.failed, nil, "Der Plan ist länger als 20000 Zeichen und wurde nicht übernommen.\n" + result.text)
            }
            return (.passed, plan, result.text)
        case .tester, .review:
            switch result.verdict {
            case "passed": return (.passed, nil, result.text)
            case "failed": return (.failed, nil, result.text)
            default: return (.failed, nil, "Kein Urteil (verdict) geliefert.\n" + result.text)
            }
        case .developer, .validation:
            return (.passed, nil, result.text)
        }
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
        if let reason = await budgetRefusal() {
            mutate(id) { $0.note = reason + "; Fortsetzen zurückgestellt." }
            return
        }
        guard runs[id]?.phase == .waitingForAnswer else { return }
        mutate(id) { $0.phase = .resuming; $0.deliveredQuestions += fresh.map(\.id) }
        do { adopt(id, try await server.resume(runID: id, generation: run.generation)) }
        catch let error as RunnerServerError where error.isOwnershipLoss {
            await loseLease(id, reason: "Resume rejected (\(error))."); return
        } catch {
            mutate(id) { $0.phase = .waitingForAnswer; $0.deliveredQuestions.removeAll { id in fresh.contains { $0.id == id } } }
            lastError = "Resume deferred: \(error)"; return
        }
        await launch(id, detail: detail, answers: fresh, resume: true)
    }

    // MARK: Operator actions

    /// Stops the local process and confirms the stop to the server (job becomes cancelled).
    public func stop(runID id: UUID) async throws {
        guard let run = runs[id], run.phase != .closed else { throw RunnerError.invalidConfiguration }
        guard run.phase != .needsReconciliation else { throw RunnerError.unknownProcess }
        mutate(id) { $0.stopRequested = true }
        if let process = run.process { await halt(process, of: run) }
        else if run.phase != .leaseLost {
            mutate(id) { $0.outbox = [.stop]; $0.afterOutbox = .closed }
            await flushOutbox(id)
        }
    }

    /// Operator confirms that no agent process of an ambiguous run exists; frees the server's repository seat.
    public func release(runID id: UUID) async throws {
        guard let run = runs[id], run.phase == .needsReconciliation else { throw RunnerError.invalidConfiguration }
        if let process = run.process, await observe(process, of: run) != .exited { throw RunnerError.unknownProcess }
        _ = try await server.reconcile(runID: id, generation: run.generation, observation: .stopped)
        mutate(id) { $0.phase = .closed; $0.process = nil; $0.note = "Released by operator after verification." }
    }
}
