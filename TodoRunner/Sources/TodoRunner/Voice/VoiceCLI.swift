import Foundation

public struct VoiceEngines: Sendable {
    public var stt: any SpeechToText
    public var tts: any TextToSpeech
    public init(stt: any SpeechToText, tts: any TextToSpeech) { self.stt = stt; self.tts = tts }
}

extension RunnerCLI {
    /// nil when no voice configuration exists or the build has no engines.
    func makeVoiceWorker(config: RunnerConfig) throws -> VoiceWorker? {
        guard VoiceConfig.exists(in: context.directory), let factory = context.makeVoiceEngines else { return nil }
        let voiceConfig = try VoiceConfig.load(from: context.directory)
        let engines = try factory(voiceConfig, context.directory, context.secrets)
        let log = RunnerLogFile(directory: context.directory, redactor: Redactor(secrets: [config.token]))
        var settings = VoiceWorkerSettings(workDirectory: context.directory.appendingPathComponent("voice-work", isDirectory: true))
        settings.log = { log.append($0) }
        if let seconds = context.environment["TODO_RUNNER_VOICE_POLL"].flatMap(Double.init) { settings.pollInterval = .seconds(seconds) }
        let server = URLSessionVoiceServer(baseURL: config.baseURL, token: config.token)
        return VoiceWorker(server: server, stt: engines.stt, tts: engines.tts, settings: settings)
    }

    func voiceSetup(_ args: [String]) async throws -> Int32 {
        try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let index = args.firstIndex(of: "--http") {
            guard args.indices.contains(index + 1), let url = URL(string: args[index + 1]) else { throw RunnerError.invalidConfiguration }
            do { try LoopbackGuard.validate(url) } catch {
                context.err("Abgelehnt: Die Engine muss auf diesem Mac (127.0.0.1, ::1 oder localhost) lauschen. Audio verlässt den Mac nur zu deinem Todolino-Server.")
                return 1
            }
            guard let key = context.environment["TODO_RUNNER_VOICE_KEY"], !key.isEmpty else {
                context.err("TODO_RUNNER_VOICE_KEY (API-Key der Engine) fehlt. Die Engine soll nur mit Schlüssel und nur auf Loopback erreichbar sein.")
                return 1
            }
            try context.secrets.write(key, account: VoiceConfig.apiKeyAccount)
            try VoiceConfig(engine: .http, endpoint: url).save(to: context.directory)
            context.out("Externe Engine \(url.absoluteString) gespeichert (Schlüssel im Schlüsselbund).")
            return 0
        }
        var model = VoiceConfig.defaultModel
        if let index = args.firstIndex(of: "--model") {
            guard args.indices.contains(index + 1) else { throw RunnerError.invalidConfiguration }
            model = args[index + 1]
        }
        guard let download = context.downloadVoiceModel else { context.err("Dieser Build enthält keine lokale Sprach-Engine."); return 1 }
        context.out("Lade Modell \(model) einmalig herunter (Verbindung zu huggingface.co, danach nie wieder) ...")
        let folder = try await download(model, VoiceConfig.modelBase(in: context.directory))
        try VoiceConfig(model: model, modelFolder: folder.path).save(to: context.directory)
        context.out("Modell bereit: \(folder.path)")
        return voiceStatus()
    }

    func voiceStatus() -> Int32 {
        guard VoiceConfig.exists(in: context.directory) else {
            context.out("Sprache nicht eingerichtet. `todo-runner voice-setup` ausführen."); return 1
        }
        guard let config = try? VoiceConfig.load(from: context.directory), let factory = context.makeVoiceEngines,
              let engines = try? factory(config, context.directory, context.secrets) else {
            context.out("Sprachkonfiguration nicht lesbar oder Engine nicht verfügbar."); return 1
        }
        context.out("Engine: \(config.engine.rawValue), Modell: \(config.model)")
        context.out("Spracherkennung: \(engines.stt.isReady ? "bereit" : "Modell fehlt (`voice-setup`)")")
        context.out("Sprachausgabe: \(engines.tts.isReady ? "deutsche Stimme vorhanden" : "keine deutsche Stimme installiert (Systemeinstellungen > Bedienungshilfen > Gesprochene Inhalte)")")
        let ready = engines.stt.isReady && engines.tts.isReady
        context.out("Fähigkeit sprache: \(ready ? "wird gemeldet" : "wird NICHT gemeldet")")
        return ready ? 0 : 1
    }

    func voiceOnce(_ args: [String]) async throws -> Int32 {
        var timeout: TimeInterval = 120
        if let index = args.firstIndex(of: "--timeout") {
            guard args.indices.contains(index + 1), let value = Double(args[index + 1]), value > 0 else { throw RunnerError.invalidConfiguration }
            timeout = value
        }
        let config = try loadConfig()
        guard let worker = try makeVoiceWorker(config: config) else { context.err("Sprache nicht eingerichtet."); return 1 }
        await worker.sweepWorkDirectory()
        guard !worker.capabilities().isEmpty else { context.err("Fähigkeit sprache nicht verfügbar (`voice-status`)."); return 1 }
        await worker.reportCapabilities()
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let outcome = await worker.pollOnce() {
                context.out("Sprachauftrag: \(outcome)")
                return outcome == .done ? 0 : 2
            }
            try? await Task.sleep(for: .seconds(1))
        }
        context.out("Kein Sprachauftrag innerhalb von \(Int(timeout)) s.")
        return 3
    }
}
