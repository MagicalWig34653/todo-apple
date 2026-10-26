import Foundation
import TodoRunner

/// A single local smoke job, explicitly not a substitute for the server API.
private actor LocalJobServer: RunnerServer {
    var job: RunnerJob?
    init(_ job: RunnerJob) { self.job = job }
    func claim(eligibleProjects: [String]) -> RunnerJob? {
        guard let job, eligibleProjects.contains(job.projectID) else { return nil }
        self.job = nil
        return job
    }
    func renew(_ job: RunnerJob) -> Date? { Date().addingTimeInterval(60) }
    func publish(_ event: RunnerEvent, for job: RunnerJob) throws {
        print(String(decoding: try JSONEncoder().encode(event), as: UTF8.self))
    }
    func answer(for job: RunnerJob) -> String? { nil }
}

@main struct RunnerCommand {
    static func localized(_ key: String) -> String { NSLocalizedString(key, bundle: .module, comment: "") }
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first, ["approve", "status", "run-local"].contains(command) else {
                print(localized("usage")); return
            }
            let environment = ProcessInfo.processInfo.environment
            let directory = environment["TODO_RUNNER_HOME"].map { URL(fileURLWithPath: $0) }
                ?? LocalStateStore.defaultDirectory
            let store = try LocalStateStore(directory: directory)
            let approvals = FolderApprovals(file: directory.appendingPathComponent("allowlist.json"))
            switch command {
            case "approve":
                guard args.count == 3 else { throw RunnerError.invalidConfiguration }
                try approvals.approve(projectID: args[1], folder: URL(fileURLWithPath: args[2]))
                print(localized("approved"))
            case "status":
                print(String(decoding: try JSONEncoder().encode(store.load()), as: UTF8.self))
            default:
                guard args.count == 3 else { throw RunnerError.invalidConfiguration }
                let executable = environment["TODO_RUNNER_CLAUDE"].map { URL(fileURLWithPath: $0) }
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")
                let job = RunnerJob(projectID: args[1], generation: 1,
                                    leaseExpiresAt: Date().addingTimeInterval(60), prompt: args[2])
                let server = LocalJobServer(job)
                let provider = ClaudeProcessAdapter(executable: executable,
                                                  scratch: directory.appendingPathComponent("process-output"))
                let runner = try Runner(server: server, provider: provider, store: store, approvals: approvals)
                repeat {
                    try await runner.tick()
                    let runs = await runner.snapshot()
                    if runs.contains(where: { $0.job.runID == job.runID && $0.phase != .running && $0.phase != .launching }) { break }
                    if !runs.contains(where: { $0.job.runID == job.runID }) { throw RunnerError.unapprovedFolder }
                    try await Task.sleep(for: .seconds(1))
                } while !Task.isCancelled
            }
        } catch {
            let message = String(format: localized("error"), String(describing: error)) + "\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }
}
