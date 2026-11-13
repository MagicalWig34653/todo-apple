import Foundation
import WhisperKit
import TodoRunner

public enum WhisperSetupError: Error, Equatable { case modelMissing(String) }

/// Local German speech recognition with WhisperKit. The model folder is a local path; nothing is downloaded when audio is processed.
public actor WhisperKitSpeechToText: SpeechToText {
    public let modelFolder: URL
    private var pipeline: WhisperKit?

    public init(modelFolder: URL) { self.modelFolder = modelFolder }

    /// Model files are present (CoreML bundles for mel, encoder, decoder and the tokenizer).
    public nonisolated var isReady: Bool { Self.isModelFolder(modelFolder) }

    public static func isModelFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"].allSatisfy {
            fm.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    public func transcribe(audioFile: URL) async throws -> String {
        guard Self.isModelFolder(modelFolder) else { throw WhisperSetupError.modelMissing(modelFolder.path) }
        if pipeline == nil {
            // download: false and a fixed modelFolder: loading never touches the network.
            let config = WhisperKitConfig(modelFolder: modelFolder.path, verbose: false, logLevel: .none, prewarm: false, load: true, download: false)
            pipeline = try await WhisperKit(config)
        }
        guard let pipeline else { throw WhisperSetupError.modelMissing(modelFolder.path) }
        var options = DecodingOptions()
        options.language = "de"
        options.task = .transcribe
        options.detectLanguage = false
        let results = try await pipeline.transcribe(audioPath: audioFile.path, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Explicit one-time model download into `base` (the only network access of the speech stack).
    /// Returns the local model folder.
    public static func download(model: String, base: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return try await WhisperKit.download(variant: model, downloadBase: base, progressCallback: { p in progress?(p.fractionCompleted) })
    }
}
