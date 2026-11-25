import Foundation

// MARK: Log file

/// Append-only log with owner-only permissions, size-based rotation and credential redaction.
public final class RunnerLogFile: @unchecked Sendable {
    public let url: URL
    private let maxBytes: UInt64
    private let redactor: Redactor
    private let lock = NSLock()

    public init(directory: URL, redactor: Redactor = Redactor(), maxBytes: UInt64 = 1_000_000) {
        url = directory.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("runner.log")
        self.redactor = redactor; self.maxBytes = maxBytes
    }

    public func append(_ message: String, date: Date = Date()) {
        lock.withLock {
            let folder = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size >= maxBytes {
                let old = folder.appendingPathComponent("runner.log.1")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let line = "\(ISO8601DateFormatter().string(from: date)) \(redactor.redact(message).replacingOccurrences(of: "\n", with: " "))\n"
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    public func tail(_ count: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(max(0, count)).map(String.init))
    }
}

// MARK: launchd

public enum LaunchdPlist {
    /// Renders a LaunchAgent property list. The plist is only generated, never installed by the runner.
    public static func make(label: String, executable: String, arguments: [String], environment: [String: String],
                            logDirectory: String) throws -> String {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable] + arguments,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 30,
            "ProcessType": "Background",
            "EnvironmentVariables": environment,
            "StandardOutPath": logDirectory + "/launchd.out.log",
            "StandardErrorPath": logDirectory + "/launchd.err.log",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: Doctor

public struct DoctorCheck: Sendable, Equatable {
    public enum Level: String, Sendable { case ok = "OK", warning = "WARNUNG", error = "FEHLER" }
    public var level: Level
    public var title: String
    public var detail: String
}

// MARK: CLI

/// Everything the command line needs from the outside world, injectable for tests.
public struct CLIContext: Sendable {
    public var directory: URL
    public var secrets: any SecretStore
    public var claudeExecutable: URL
    /// Absolute path of the running todo-runner binary (for the launchd plist).
    public var executablePath: String
    public var environment: [String: String]
    public var interval: Duration
    public var makeServer: @Sendable (URL, String) -> any RunnerServer
    public var makeProvider: @Sendable (URL) -> any AgentProvider
    public var pair: @Sendable (URL, String) async throws -> DeviceToken
    /// Runs an executable with arguments, returns stdout or nil on failure/timeout.
    public var probe: @Sendable (URL, [String]) async -> String?
    public var activity: any ActivityAssertion
    /// Builds the local speech engines for a voice configuration (WhisperKit lives outside this target); nil = voice not supported.
    public var makeVoiceEngines: (@Sendable (VoiceConfig, URL, any SecretStore) throws -> VoiceEngines)?
    /// One-time explicit model download (the only network access of the speech stack). Returns the local model folder.
    public var downloadVoiceModel: (@Sendable (String, URL) async throws -> URL)?
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void

    public init(directory: URL, secrets: any SecretStore, claudeExecutable: URL, executablePath: String,
                environment: [String: String] = [:], interval: Duration = .seconds(15),
                makeServer: @escaping @Sendable (URL, String) -> any RunnerServer = { URLSessionRunnerServer(baseURL: $0, token: $1) },
                makeProvider: @escaping @Sendable (URL) -> any AgentProvider,
                pair: @escaping @Sendable (URL, String) async throws -> DeviceToken = { try await URLSessionRunnerServer.pair(baseURL: $0, code: $1) },
                probe: @escaping @Sendable (URL, [String]) async -> String? = { _, _ in nil },
                activity: any ActivityAssertion = NoActivityAssertion(),
                makeVoiceEngines: (@Sendable (VoiceConfig, URL, any SecretStore) throws -> VoiceEngines)? = nil,
                downloadVoiceModel: (@Sendable (String, URL) async throws -> URL)? = nil,
                out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void) {
        self.directory = directory; self.secrets = secrets; self.claudeExecutable = claudeExecutable
        self.executablePath = executablePath; self.environment = environment; self.interval = interval
        self.makeServer = makeServer; self.makeProvider = makeProvider; self.pair = pair; self.probe = probe
        self.activity = activity; self.makeVoiceEngines = makeVoiceEngines; self.downloadVoiceModel = downloadVoiceModel; self.out = out; self.err = err
    }
}

public struct RunnerCLI: Sendable {
    public let context: CLIContext
    public init(context: CLIContext) { self.context = context }

    // User-facing strings (German first; moving them into a Localizable resource is a follow-up).
    static let usage = """
    Verwendung: todo-runner <Befehl>
      pair <Server-URL> <Code>           Gerät mit dem Einmalcode aus der App koppeln (Token landet im Schlüsselbund)
      approve <Ordner> [Repository-UUID] Ordner freigeben (gibt die Repository-UUID aus)
      bindings                           Bindings dieses Geräts beim Server anzeigen
      status [--json]                    Kopplung und lokale Läufe anzeigen
      run                                Runner dauerhaft starten (Abfrage, Heartbeat, Claude-Start)
      run-once                           Höchstens einen Auftrag annehmen, abarbeiten und beenden
      logs [-n Anzahl]                   Letzte Zeilen des Runner-Logs anzeigen
      doctor                             Einrichtung prüfen (claude-CLI, Kopplung, Server, Ordner)
      launchd-plist [--label L]          LaunchAgent-Plist ausgeben (wird nicht installiert)
      release <Lauf-UUID>                Unklaren Lauf nach manueller Prüfung freigeben
      validation <Repository-UUID|Ordner> [--timeout Sekunden] -- <Programm> [Argumente…]
                                         Validierungsbefehl der Pipeline lokal speichern (ohne Shell; --clear entfernt ihn)
      budget -- <Programm> [Argumente…]  Kontingent-Bremse: JSON-Befehl vor jedem Agentenstart (--clear entfernt sie)
      voice-setup [--model M]            Sprach-Engine einrichten: lädt das WhisperKit-Modell EINMALIG herunter (einziger Netzzugriff dieser Art)
      voice-setup --http <URL>           Externe Engine auf Loopback (z. B. VoiceStudio) nutzen; API-Key aus TODO_RUNNER_VOICE_KEY
      voice-status                       Sprach-Fähigkeit prüfen (Modell, deutsche Stimme)
      voice-once [--timeout Sekunden]    Genau einen Sprachauftrag annehmen und bearbeiten
    Umgebung: TODO_RUNNER_HOME (Zustand), TODO_RUNNER_CLAUDE (Pfad zur claude-CLI),
              TODO_RUNNER_INTERVAL (Sekunden), TODO_RUNNER_SECRETS=file (statt Schlüsselbund, nur Tests/Headless)
    """

    public static func describe(_ error: Error) -> String {
        switch error {
        case RunnerServerError.unauthorized: return "Der Server lehnt das Gerät ab (Token ungültig oder Gerät widerrufen). Neu koppeln mit `todo-runner pair`."
        case RunnerServerError.transport(let detail): return "Server nicht erreichbar (\(detail))."
        case RunnerServerError.badRequest(let reason): return "Server lehnt die Anfrage ab: \(reason)"
        case RunnerServerError.notFound: return "Nicht gefunden (Code abgelaufen oder bereits verwendet?)."
        case RunnerError.missingToken: return "Kein Token im Schlüsselbund. Bitte `todo-runner pair` ausführen."
        case RunnerError.alreadyOpen: return "Ein anderer Runner nutzt diesen Zustandsordner bereits."
        case RunnerError.invalidConfiguration: return "Ungültige Eingabe oder Konfiguration. `todo-runner` ohne Argumente zeigt die Hilfe."
        case RunnerError.unapprovedFolder: return "Ordner existiert nicht oder ist kein freigegebener Ordner."
        case RunnerError.unknownProgram: return "Programm nicht gefunden. Bitte den vollständigen Pfad angeben."
        case RunnerError.unknownProcess: return "Der Prozess des Laufs ist nicht eindeutig beendet; Freigabe nicht möglich."
        case DecodingError.dataCorrupted, DecodingError.keyNotFound: return "Konfigurationsdatei ist beschädigt. Neu koppeln mit `todo-runner pair`."
        case SecretStoreError.keychain(let status): return "Schlüsselbund-Fehler (Status \(status))."
        default: return String(describing: error)
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    var allowlist: FolderAllowlist { FolderAllowlist(file: context.directory.appendingPathComponent("allowlist.json")) }

    func loadConfig() throws -> RunnerConfig {
        guard RunnerConfig.exists(in: context.directory) else { throw RunnerError.missingToken }
        return try RunnerConfig.load(from: context.directory, secrets: context.secrets)
    }

    private func logFile(token: String? = nil) -> RunnerLogFile {
        RunnerLogFile(directory: context.directory, redactor: Redactor(secrets: token.map { [$0] } ?? []))
    }

    private func makeRunner(config: RunnerConfig) throws -> Runner {
        var settings = RunnerSettings()
        let log = logFile(token: config.token)
        settings.log = { log.append($0) }
        settings.activity = context.activity
        let server = context.makeServer(config.baseURL, config.token)
        let provider = context.makeProvider(context.directory.appendingPathComponent("process-output"))
        return try Runner(server: server, provider: provider, store: LocalStateStore(directory: context.directory),
                          allowlist: allowlist, settings: settings)
    }

    /// Returns the process exit code.
    public func execute(_ args: [String]) async throws -> Int32 {
        guard let command = args.first else { context.out(Self.usage); return 0 }
        switch command {
        case "pair":
            guard args.count == 3, let url = URL(string: args[1]), url.scheme != nil, url.host != nil else { throw RunnerError.invalidConfiguration }
            try prepareDirectory()
            let device = try await context.pair(url, args[2])
            try RunnerConfig(baseURL: url, deviceID: device.deviceID, token: device.token).save(to: context.directory, secrets: context.secrets)
            context.out("Gekoppelt. Gerät \(device.deviceID.uuidString.lowercased()). Token im Schlüsselbund gespeichert.")
            context.out("Nächste Schritte: `todo-runner approve <Ordner>`, danach `todo-runner doctor`.")
        case "approve":
            guard args.count == 2 || args.count == 3 else { throw RunnerError.invalidConfiguration }
            try prepareDirectory()
            let key = try allowlist.approve(folder: URL(fileURLWithPath: args[1]),
                                            repositoryKey: args.count == 3 ? UUID(uuidString: args[2]) : nil)
            context.out("Ordner freigegeben. Repository-UUID: \(key.uuidString.lowercased())")
        case "bindings":
            let config = try loadConfig()
            let bindings = try await context.makeServer(config.baseURL, config.token).bindings()
            if bindings.isEmpty { context.out("Keine Bindings für dieses Gerät.") }
            for binding in bindings {
                context.out("\(binding.id.uuidString.lowercased())\t\(binding.repositoryKey.uuidString.lowercased())\t\(binding.label)")
            }
        case "validation": try configureValidation(Array(args.dropFirst()))
        case "budget": try configureBudget(Array(args.dropFirst()))
        case "status": try status(json: args.contains("--json"))
        case "run":
            let config = try loadConfig()
            let runner = try makeRunner(config: config)
            logFile(token: config.token).append("Runner gestartet (Gerät \(config.deviceID.uuidString.lowercased())).")
            let voice = try? makeVoiceWorker(config: config)
            if let voice {
                logFile(token: config.token).append("Sprach-Worker aktiv (Fähigkeit sprache: \(voice.capabilities().isEmpty ? "nein" : "ja")).")
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await runner.runLoop(interval: context.interval) }
                if let voice { group.addTask { await voice.runLoop() } }
                await group.waitForAll()
            }
        case "run-once":
            let config = try loadConfig()
            let runner = try makeRunner(config: config)
            let runs = try await runner.runOnce(interval: min(context.interval, .seconds(5)))
            if runs.isEmpty { context.out("Kein Auftrag in der Warteschlange.") }
            for run in runs { context.out(Self.line(run)) }
            return runs.contains { $0.phase == .needsReconciliation || $0.phase == .leaseLost } ? 2 : 0
        case "logs":
            var count = 50
            if let index = args.firstIndex(of: "-n") {
                guard args.indices.contains(index + 1), let n = Int(args[index + 1]), n > 0 else { throw RunnerError.invalidConfiguration }
                count = n
            }
            let lines = logFile().tail(count)
            if lines.isEmpty { context.out("Noch keine Log-Einträge (\(logFile().url.path)).") }
            lines.forEach(context.out)
        case "voice-setup": return try await voiceSetup(Array(args.dropFirst()))
        case "voice-status": return voiceStatus()
        case "voice-once": return try await voiceOnce(Array(args.dropFirst()))
        case "doctor": return await doctor()
        case "launchd-plist":
            var label = "de.todo.runner"
            if let index = args.firstIndex(of: "--label") {
                guard args.indices.contains(index + 1) else { throw RunnerError.invalidConfiguration }
                label = args[index + 1]
            }
            var environment = ["PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"]
            for key in ["TODO_RUNNER_HOME", "TODO_RUNNER_CLAUDE", "TODO_RUNNER_SECRETS", "TODO_RUNNER_INTERVAL"] {
                if let value = context.environment[key] { environment[key] = value }
            }
            context.out(try LaunchdPlist.make(label: label, executable: context.executablePath, arguments: ["run"], environment: environment,
                                              logDirectory: context.directory.appendingPathComponent("logs").path))
            context.err("""
            Nur erzeugt, nichts installiert. Zum Aktivieren: `mkdir -p \(context.directory.path)/logs`, Ausgabe nach ~/Library/LaunchAgents/\(label).plist speichern, dann
            `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/\(label).plist`. Entfernen: `launchctl bootout gui/$(id -u)/\(label)`.
            """)
        case "release":
            guard args.count == 2, let id = UUID(uuidString: args[1]) else { throw RunnerError.invalidConfiguration }
            try await makeRunner(config: loadConfig()).release(runID: id)
            context.out("Lauf freigegeben.")
        default: context.out(Self.usage); return command == "help" || command == "--help" ? 0 : 64
        }
        return 0
    }

    // MARK: local commands

    var commands: LocalCommands { LocalCommands(directory: context.directory) }

    /// Bare program names are resolved now, so that a launchd runner with its short PATH starts the same program.
    private func resolved(_ program: String) throws -> String {
        guard !program.contains("/") else { return program }
        guard let path = ProcessCommandExecutor.search(program, path: context.environment["PATH"]) else { throw RunnerError.unknownProgram }
        return path
    }

    private func configureValidation(_ args: [String]) throws {
        guard let target = args.first else { throw RunnerError.invalidConfiguration }
        var command: LocalCommand?
        if Array(args.dropFirst()) != ["--clear"] {
            guard let separator = args.firstIndex(of: "--"), separator >= 1, separator + 1 < args.count else { throw RunnerError.invalidConfiguration }
            var timeout = LocalCommands.defaultValidationTimeout
            let options = Array(args[1..<separator])
            if !options.isEmpty {
                guard options.count == 2, options[0] == "--timeout", let seconds = Double(options[1]), seconds > 0, seconds.isFinite else {
                    throw RunnerError.invalidConfiguration
                }
                timeout = seconds
            }
            var argv = Array(args[(separator + 1)...])
            argv[0] = try resolved(argv[0])
            command = LocalCommand(argv: argv, timeout: timeout)
        }
        let entries = try allowlist.entries()
        let key: UUID
        if let id = UUID(uuidString: target) {
            guard entries[id] != nil else { throw RunnerError.unapprovedFolder }
            key = id
        } else {
            let path = FolderAllowlist.canonical(URL(fileURLWithPath: target)).path
            guard let entry = entries.first(where: { $0.value == path }) else { throw RunnerError.unapprovedFolder }
            key = entry.key
        }
        try commands.setValidation(command, for: key)
        context.out(command == nil ? "Validierungsbefehl entfernt." : "Validierungsbefehl lokal gespeichert (verlässt diesen Mac nicht).")
    }

    private func configureBudget(_ args: [String]) throws {
        if args == ["--clear"] {
            try commands.setBudget(nil)
            context.out("Kontingent-Bremse entfernt.")
            return
        }
        guard args.first == "--", args.count > 1 else { throw RunnerError.invalidConfiguration }
        var argv = Array(args.dropFirst())
        argv[0] = try resolved(argv[0])
        // The command runs in the state folder; a relative program path means "relative to here".
        if !argv[0].hasPrefix("/") { argv[0] = URL(fileURLWithPath: argv[0]).standardizedFileURL.path }
        try commands.setBudget(argv)
        context.out("Kontingent-Bremse lokal gespeichert. Argumente mit Pfaden bitte absolut angeben.")
    }

    private static func commandText(_ command: LocalCommand) -> String {
        "\(command.argv.joined(separator: " ")) (Zeitlimit \(Int(command.timeout.rounded(.up))) s)"
    }

    private func commandChecks(entries: [UUID: String]) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        func executable(_ program: String, in folder: String?) -> Bool {
            let path = program.hasPrefix("/") ? program : (folder ?? context.directory.path) + "/" + program
            return FileManager.default.isExecutableFile(atPath: path)
        }
        do {
            if let argv = try commands.budget() {
                checks.append(DoctorCheck(level: executable(argv.first ?? "", in: nil) ? .ok : .warning, title: "Kontingent-Bremse",
                                          detail: argv.joined(separator: " ")))
            }
            for (key, command) in try commands.validations().sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                let folder = entries[key]
                let usable = folder != nil && executable(command.argv.first ?? "", in: folder)
                checks.append(DoctorCheck(level: usable ? .ok : .warning, title: "Validierung",
                                          detail: "\(folder ?? key.uuidString.lowercased()): \(Self.commandText(command))"))
            }
        } catch {
            checks.append(DoctorCheck(level: .error, title: "Befehle",
                                      detail: "commands.json ist beschädigt; Agentenaufträge werden bei eingerichteter Bremse nicht angenommen."))
        }
        return checks
    }

    // MARK: status

    static func line(_ run: LocalRun) -> String {
        "\(run.runID.uuidString.prefix(8).lowercased())  \(phaseText(run.phase))  \(run.job.pipelineStep?.rawValue ?? run.job.mode.rawValue)  \(URL(fileURLWithPath: run.folder).lastPathComponent)  \(run.note)"
    }

    static func phaseText(_ phase: RunPhase) -> String {
        switch phase {
        case .claimed: "angenommen"
        case .launching: "startet"
        case .running: "läuft"
        case .waitingForAnswer: "wartet auf Antwort"
        case .resuming: "setzt fort"
        case .needsReconciliation: "UNKLAR (release nötig)"
        case .leaseLost: "Besitz verloren"
        case .closed: "beendet"
        }
    }

    private func status(json: Bool) throws {
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let runs = try LocalStateStore.readRuns(in: context.directory)
            context.out(String(decoding: try encoder.encode(runs), as: UTF8.self))
            return
        }
        if RunnerConfig.exists(in: context.directory), let config = try? RunnerConfig.load(from: context.directory, secrets: context.secrets) {
            context.out("Gekoppelt mit \(config.baseURL.absoluteString) als Gerät \(config.deviceID.uuidString.lowercased()).")
        } else {
            context.out("Nicht gekoppelt (oder Token fehlt). `todo-runner pair <Server-URL> <Code>` ausführen.")
        }
        guard FileManager.default.fileExists(atPath: context.directory.path) else { return }
        let runs = try LocalStateStore.readRuns(in: context.directory).sorted { $0.runID.uuidString < $1.runID.uuidString }
        let open = runs.filter { $0.phase != .closed }
        context.out("Freigegebene Ordner: \((try? allowlist.entries().count) ?? 0). Offene Läufe: \(open.count), beendet: \(runs.count - open.count).")
        open.forEach { context.out("  " + Self.line($0)) }
        if let budget = try commands.budget() { context.out("Kontingent-Bremse: \(budget.joined(separator: " "))") }
        let entries = (try? allowlist.entries()) ?? [:]
        for (key, command) in try commands.validations().sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let name = entries[key].map { URL(fileURLWithPath: $0).lastPathComponent } ?? key.uuidString.lowercased()
            context.out("Validierung (\(name)): \(Self.commandText(command))")
        }
    }

    // MARK: doctor

    public func runChecks() async -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        func add(_ level: DoctorCheck.Level, _ title: String, _ detail: String) { checks.append(DoctorCheck(level: level, title: title, detail: detail)) }

        // claude CLI
        let claude = context.claudeExecutable
        if !FileManager.default.isExecutableFile(atPath: claude.path) {
            add(.error, "claude-CLI", "Nicht gefunden oder nicht ausführbar: \(claude.path). Pfad per TODO_RUNNER_CLAUDE setzen.")
        } else if let version = await context.probe(claude, ["--version"]) {
            add(.ok, "claude-CLI", version.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            add(.error, "claude-CLI", "`\(claude.path) --version` liefert keine Antwort. In einem Terminal `claude` starten und anmelden.")
        }

        // State directory
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: context.directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let mode = ((try? FileManager.default.attributesOfItem(atPath: context.directory.path))?[.posixPermissions] as? Int ?? 0) & 0o777
            if mode & 0o077 == 0 { add(.ok, "Zustandsordner", context.directory.path) }
            else { add(.warning, "Zustandsordner", "Zu offene Rechte (\(String(mode, radix: 8))). Empfohlen: chmod 700 \"\(context.directory.path)\".") }
        } else {
            add(.warning, "Zustandsordner", "Existiert noch nicht (\(context.directory.path)); wird bei `pair` angelegt.")
        }

        // Pairing + server
        var config: RunnerConfig?
        if !RunnerConfig.exists(in: context.directory) {
            add(.error, "Kopplung", "Nicht gekoppelt. `todo-runner pair <Server-URL> <Code>` ausführen.")
        } else {
            do { config = try RunnerConfig.load(from: context.directory, secrets: context.secrets); add(.ok, "Kopplung", "Token im Schlüsselbund vorhanden.") }
            catch { add(.error, "Kopplung", Self.describe(error)) }
        }
        var bindings: [Binding] = []
        if let config {
            do {
                bindings = try await context.makeServer(config.baseURL, config.token).bindings()
                add(.ok, "Server", "\(config.baseURL.absoluteString) erreichbar, Token gültig, \(bindings.count) Binding(s).")
            } catch { add(.error, "Server", Self.describe(error)) }
        }

        // Folders
        let entries = (try? allowlist.entries()) ?? [:]
        if entries.isEmpty { add(.warning, "Ordner", "Kein Ordner freigegeben. `todo-runner approve <Ordner>` ausführen.") }
        for (key, path) in entries.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &dir), dir.boolValue, FileManager.default.isReadableFile(atPath: path),
               FileManager.default.isWritableFile(atPath: path) {
                add(.ok, "Ordner", "\(path) (\(key.uuidString.prefix(8).lowercased()))")
            } else {
                add(.error, "Ordner", "\(path) fehlt oder ist nicht les-/schreibbar (macOS-Datenschutz: Terminal bzw. todo-runner braucht Zugriff).")
            }
        }
        for binding in bindings where entries[binding.repositoryKey] == nil {
            add(.warning, "Binding", "\"\(binding.label)\" hat keinen freigegebenen Ordner; Aufträge dafür werden nicht angenommen.")
        }

        checks += commandChecks(entries: entries)

        // Voice (optional)
        if VoiceConfig.exists(in: context.directory), let voiceConfig = try? VoiceConfig.load(from: context.directory),
           let engines = try? context.makeVoiceEngines?(voiceConfig, context.directory, context.secrets) {
            if engines.stt.isReady && engines.tts.isReady { add(.ok, "Sprache", "Modell und deutsche Stimme bereit; Fähigkeit sprache wird gemeldet.") }
            else { add(.warning, "Sprache", "Modell oder deutsche Stimme fehlt; Fähigkeit sprache wird nicht gemeldet (`todo-runner voice-status`).") }
        }

        // Local runs needing attention
        if let runs = try? LocalStateStore.readRuns(in: context.directory) {
            let unclear = runs.filter { $0.phase == .needsReconciliation }
            if !unclear.isEmpty { add(.warning, "Läufe", "\(unclear.count) unklarer Lauf/Läufe blockieren Ordner: `todo-runner release <Lauf-UUID>` nach Prüfung.") }
        } else {
            add(.warning, "Läufe", "Lokaler Laufzustand ist nicht lesbar (runs.json beschädigt?).")
        }
        return checks
    }

    private func doctor() async -> Int32 {
        let checks = await runChecks()
        for check in checks { context.out("[\(check.level.rawValue)] \(check.title): \(check.detail)") }
        let errors = checks.filter { $0.level == .error }.count, warnings = checks.filter { $0.level == .warning }.count
        context.out(errors == 0 ? "Ergebnis: bereit (\(warnings) Warnung(en))." : "Ergebnis: \(errors) Fehler, \(warnings) Warnung(en).")
        return errors == 0 ? 0 : 1
    }
}
