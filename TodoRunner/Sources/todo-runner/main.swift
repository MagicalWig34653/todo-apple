import Foundation
import TodoRunner

// User-facing strings (German first; moving them into a Localizable resource is a follow-up).
private enum Text {
    static let usage = """
    Verwendung: todo-runner <Befehl>
      pair <Server-URL> <Code>          Gerät mit Einmalcode koppeln
      approve <Ordner> [Repository-UUID] Ordner freigeben (gibt die Repository-UUID aus)
      bindings                          Bindings dieses Geräts beim Server anzeigen
      status                            Lokale Läufe anzeigen
      run                               Runner starten (Abfrage, Heartbeat, Claude-Start)
      release <Lauf-UUID>               Unklaren Lauf nach manueller Prüfung freigeben
    Umgebung: TODO_RUNNER_HOME (Zustand), TODO_RUNNER_CLAUDE (Pfad zur claude-CLI)
    """
    static let paired = "Gekoppelt. Token lokal gespeichert."
    static func approved(_ key: UUID) -> String { "Ordner freigegeben. Repository-UUID: \(key.uuidString.lowercased())" }
    static let released = "Lauf freigegeben."
    static func failure(_ error: Error) -> String { "Fehler: \(error)\n" }
}

@main struct RunnerCommand {
    static func main() async {
        do { try await execute(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data(Text.failure(error).utf8))
            exit(1)
        }
    }

    static func execute(_ args: [String]) async throws {
        guard let command = args.first else { print(Text.usage); return }
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["TODO_RUNNER_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? LocalStateStore.defaultDirectory
        let allowlist = FolderAllowlist(file: directory.appendingPathComponent("allowlist.json"))
        switch command {
        case "pair":
            guard args.count == 3, let url = URL(string: args[1]) else { throw RunnerError.invalidConfiguration }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let device = try await URLSessionRunnerServer.pair(baseURL: url, code: args[2])
            try RunnerConfig(baseURL: url, deviceID: device.deviceID, token: device.token).save(to: directory)
            print(Text.paired)
        case "approve":
            guard args.count == 2 || args.count == 3 else { throw RunnerError.invalidConfiguration }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let key = try allowlist.approve(folder: URL(fileURLWithPath: args[1]),
                                            repositoryKey: args.count == 3 ? UUID(uuidString: args[2]) : nil)
            print(Text.approved(key))
        case "bindings":
            let config = try RunnerConfig.load(from: directory)
            let server = URLSessionRunnerServer(baseURL: config.baseURL, token: config.token)
            for binding in try await server.bindings() {
                print("\(binding.id.uuidString.lowercased())\t\(binding.repositoryKey.uuidString.lowercased())\t\(binding.label)")
            }
        case "status":
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(LocalStateStore(directory: directory).load()), as: UTF8.self))
        case "run", "release":
            let store = try LocalStateStore(directory: directory)
            let config = try RunnerConfig.load(from: directory)
            let server = URLSessionRunnerServer(baseURL: config.baseURL, token: config.token)
            let executable = environment["TODO_RUNNER_CLAUDE"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")
            let provider = ClaudeProcessAdapter(executable: executable, scratch: directory.appendingPathComponent("process-output"))
            let runner = try Runner(server: server, provider: provider, store: store, allowlist: allowlist)
            if command == "release" {
                guard args.count == 2, let id = UUID(uuidString: args[1]) else { throw RunnerError.invalidConfiguration }
                try await runner.release(runID: id)
                print(Text.released)
            } else {
                let interval = environment["TODO_RUNNER_INTERVAL"].flatMap(Double.init) ?? 15
                await runner.runLoop(interval: .seconds(interval))
            }
        default: print(Text.usage)
        }
    }
}
