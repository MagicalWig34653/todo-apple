import Foundation

/// Local speech recognition. Implementations must not use the network while transcribing; model downloads are a separate,
/// explicit setup step (`todo-runner voice-setup`).
public protocol SpeechToText: Sendable {
    /// The model is installed locally and loadable. The runner reports the capability only while this holds.
    var isReady: Bool { get }
    /// German transcript of an audio file (M4A or WAV).
    func transcribe(audioFile: URL) async throws -> String
}

/// Local speech synthesis into an audio file.
public protocol TextToSpeech: Sendable {
    /// A usable German voice exists.
    var isReady: Bool { get }
    /// Writes M4A or WAV of at most `VoiceLimits.maxSeconds` and `VoiceLimits.maxBytes`. The file extension of `file` selects the container.
    func synthesize(_ text: String, to file: URL) async throws
}

/// Server-side limits for reply audio (contracts/voice.yaml): 120 s and 5 MiB.
public enum VoiceLimits {
    public static let maxSeconds: TimeInterval = 120
    public static let maxBytes = 5 * 1024 * 1024
    public static let maxTextCharacters = 4000
}

public enum VoiceEngineError: Error, Equatable {
    case notLoopback(String)
    case engineUnavailable
    case emptyResult
    case replyTooLong
    case synthesisFailed(String)
}

/// Selectable engine. `whisperKit` is the default (in-process, Core ML); `http` talks to an engine on this Mac,
/// e.g. an optional VoiceStudio (not bundled).
public struct VoiceConfig: Codable, Sendable, Equatable {
    public enum Engine: String, Codable, Sendable { case whisperKit = "whisperkit", http }
    public var engine: Engine
    /// WhisperKit model variant (folder name in argmaxinc/whisperkit-coreml).
    public var model: String
    /// Local model directory (set by `voice-setup`). Never inside the repository.
    public var modelFolder: String?
    /// `http` engine: base URL on this Mac. Only loopback hosts are accepted.
    public var endpoint: URL?

    public static let defaultModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    public static let fileName = "voice.json"
    /// Keychain / secret store account of the API key for an external engine.
    public static let apiKeyAccount = "voice-engine-key"

    public init(engine: Engine = .whisperKit, model: String = VoiceConfig.defaultModel, modelFolder: String? = nil, endpoint: URL? = nil) {
        self.engine = engine; self.model = model; self.modelFolder = modelFolder; self.endpoint = endpoint
    }

    public static func exists(in directory: URL) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path) }

    public static func load(from directory: URL) throws -> VoiceConfig {
        try JSONDecoder().decode(VoiceConfig.self, from: Data(contentsOf: directory.appendingPathComponent(fileName)))
    }

    public func save(to directory: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Default model storage: below the state directory, outside any repository.
    public static func modelBase(in directory: URL) -> URL { directory.appendingPathComponent("voice-models", isDirectory: true) }
}

/// Only engines on this Mac are acceptable: audio must not leave the machine except to the user's own server.
public enum LoopbackGuard {
    public static func validate(_ url: URL) throws {
        guard let host = url.host?.lowercased(), ["127.0.0.1", "::1", "localhost"].contains(host) else {
            throw VoiceEngineError.notLoopback(url.host ?? "")
        }
    }
}

/// External speech-to-text engine on loopback (for example VoiceStudio). Request: POST `<endpoint>/transcribe` with the raw audio
/// and `Authorization: Bearer <API key>`; response: JSON `{"text": "..."}`. The engine must bind to 127.0.0.1 and require the key.
public struct HTTPSpeechToText: SpeechToText {
    public let endpoint: URL
    private let apiKey: String
    private let session: URLSession

    public init(endpoint: URL, apiKey: String, session: URLSession = .shared) throws {
        try LoopbackGuard.validate(endpoint)
        self.endpoint = endpoint; self.apiKey = apiKey; self.session = session
    }

    public var isReady: Bool { !apiKey.isEmpty }

    public func transcribe(audioFile: URL) async throws -> String {
        var request = URLRequest(url: endpoint.appending(path: "transcribe"), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue(audioFile.pathExtension.lowercased() == "wav" ? "audio/wav" : "audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.upload(for: request, fromFile: audioFile)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String else {
            throw VoiceEngineError.engineUnavailable
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Creates the reply text for a transcript. T1-5 replaces the acknowledgement with the real Brain logic.
public protocol ResponseProvider: Sendable {
    func reply(toTranscript transcript: String) async throws -> String
}

public struct AcknowledgementResponseProvider: ResponseProvider {
    public static let text = "Verstanden, ich habe deine Sprachnachricht erhalten."
    public init() {}
    public func reply(toTranscript transcript: String) async throws -> String { Self.text }
}
