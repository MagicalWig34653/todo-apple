@preconcurrency import Foundation
import TodoRunner
import TodoRunnerWhisper

/// Runs an executable with a 10 second limit and returns its stdout (nil on failure or timeout).
private func probe(_ executable: URL, _ arguments: [String]) async -> String? {
    await withCheckedContinuation { continuation in
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { continuation.resume(returning: nil); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if process.isRunning { process.terminate() } }
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            continuation.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
        }
    }
}

@main struct RunnerCommand {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["TODO_RUNNER_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? LocalStateStore.defaultDirectory
        let secrets: any SecretStore = environment["TODO_RUNNER_SECRETS"] == "file"
            ? FileSecretStore(directory: directory) : KeychainSecretStore()
        let claude = environment["TODO_RUNNER_CLAUDE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let context = CLIContext(
            directory: directory, secrets: secrets, claudeExecutable: claude,
            executablePath: executable.hasPrefix("/") ? executable : FileManager.default.currentDirectoryPath + "/" + executable,
            environment: environment, interval: .seconds(environment["TODO_RUNNER_INTERVAL"].flatMap(Double.init) ?? 15),
            makeProvider: { ClaudeProcessAdapter(executable: claude, scratch: $0) },
            probe: probe, activity: ProcessInfoActivityAssertion(),
            makeVoiceEngines: { config, _, secrets in
                let tts = AVSpeechTextToSpeech()
                switch config.engine {
                case .whisperKit:
                    guard let folder = config.modelFolder else { throw VoiceEngineError.engineUnavailable }
                    return VoiceEngines(stt: WhisperKitSpeechToText(modelFolder: URL(fileURLWithPath: folder)), tts: tts)
                case .http:
                    guard let endpoint = config.endpoint, let key = try secrets.read(account: VoiceConfig.apiKeyAccount) else {
                        throw VoiceEngineError.engineUnavailable
                    }
                    return VoiceEngines(stt: try HTTPSpeechToText(endpoint: endpoint, apiKey: key), tts: tts)
                }
            },
            downloadVoiceModel: { model, base in try await WhisperKitSpeechToText.download(model: model, base: base) },
            out: { print($0) },
            err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
        do {
            exit(try await RunnerCLI(context: context).execute(Array(CommandLine.arguments.dropFirst())))
        } catch {
            FileHandle.standardError.write(Data("Fehler: \(RunnerCLI.describe(error))\n".utf8))
            exit(1)
        }
    }
}
