import Foundation
import Darwin

/// Process rules shared by agents and local commands: argument vector without a shell, own process group,
/// stdout/stderr into owner-only files, a time limit, and signals only to a verified process identity.
actor ProcessSupervisor {
    private var children: Set<Int32> = []
    private var interruptions: [Int32: RunnerError] = [:]

    /// `errorOutput` nil sends stderr into `output` as well.
    func spawn(executable: URL, arguments: [String], environment: [String: String], folder: URL,
               output: URL, errorOutput: URL?) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        for status in [
            posix_spawn_file_actions_addchdir_np(&actions, folder.path),
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600),
            // Order matters: stderr is duplicated only after stdout is open.
            errorOutput.map { posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, $0.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600) }
                ?? posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO),
        ] { guard status == 0 else { throw RunnerError.spawn(status) } }
        for status in [
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)),
            posix_spawnattr_setpgroup(&attributes, 0),
        ] { guard status == 0 else { throw RunnerError.spawn(status) } }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let status = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard status == 0 else { throw RunnerError.spawn(status) }
        children.insert(pid)
        return pid
    }

    /// Process start time (seconds since epoch) from the kernel, nil if the PID does not exist.
    static func startTime(of pid: Int32) -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
    }

    private func isAlive(_ process: ProcessReference) -> Bool {
        guard let start = Self.startTime(of: process.pid) else { return false }
        return process.startTime == 0 || abs(start - process.startTime) < 0.01
    }

    /// Waits for the end of the process. Returns the exit status (128 + signal), or nil for a process adopted after a
    /// runner restart, whose status cannot be learned. Throws `timedOut` or `stopped` when this runner killed it.
    func exitStatus(of process: ProcessReference) async throws -> Int32? {
        // The timeout counts awake time only: systemUptime stands still while the Mac sleeps,
        // so a night in sleep mode does not kill a run on wake.
        let limit = ProcessInfo.processInfo.systemUptime + max(0, process.deadline.timeIntervalSinceNow)
        let ours = children.contains(process.pid)
        var status: Int32 = 0
        var reaped = false
        while true {
            if ours {
                let waited = waitpid(process.pid, &status, WNOHANG)
                if waited == process.pid { reaped = true; break }
                if waited < 0 && errno != EINTR { break }
            } else if !isAlive(process) { break }
            if Task.isCancelled { kill(-process.pid, SIGKILL); interruptions[process.pid] = interruptions[process.pid] ?? .stopped }
            if ProcessInfo.processInfo.systemUptime >= limit, interruptions[process.pid] == nil {
                interruptions[process.pid] = .timedOut
                kill(-process.pid, SIGKILL)
            }
            // Never leave the loop on cancellation before the process is reaped.
            try? await Task.sleep(for: .milliseconds(30))
        }
        children.remove(process.pid)
        if let interruption = interruptions.removeValue(forKey: process.pid) { throw interruption }
        return reaped ? ((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)) : nil
    }

    func stop(_ process: ProcessReference) {
        // Only signal a process whose identity is verified (guards PID reuse).
        guard isAlive(process), getpgid(process.pid) == process.pid else { return }
        interruptions[process.pid] = .stopped
        // SIGKILL on the group: an ignored SIGTERM must not leave tool subprocesses alive.
        kill(-process.pid, SIGKILL)
    }

    func reconcile(_ process: ProcessReference) -> ProcessObservation {
        if children.contains(process.pid) { return .running }
        guard let start = Self.startTime(of: process.pid) else { return .exited }
        if process.startTime == 0 { return .uncertain }
        return abs(start - process.startTime) < 0.01 ? .running : .exited
    }
}
