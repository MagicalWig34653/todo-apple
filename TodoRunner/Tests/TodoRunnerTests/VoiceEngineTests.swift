import Foundation
import Testing
import AVFoundation
@testable import TodoRunner
import TodoRunnerWhisper

/// Real local engines: AVSpeechSynthesizer (system voice). Skipped where no German voice is installed.
@Suite(.serialized) struct VoiceEngineTests {
    let tts = AVSpeechTextToSpeech()
    func temp(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tts-\(UUID().uuidString)-\(name)").resolvingSymlinksInPath()
    }

    @Test(.enabled(if: AVSpeechTextToSpeech().isReady)) func germanVoiceWritesPlayableM4AWithinServerLimits() async throws {
        let file = temp("reply.m4a"); defer { try? FileManager.default.removeItem(at: file) }
        try await tts.synthesize(AcknowledgementResponseProvider.text, to: file)
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        #expect(size > 1000 && size <= VoiceLimits.maxBytes)
        let head = try Data(contentsOf: file).prefix(12)
        #expect(head.dropFirst(4).prefix(4) == Data("ftyp".utf8), "M4A container")
        let audio = try AVAudioFile(forReading: file)
        let seconds = Double(audio.length) / audio.processingFormat.sampleRate
        #expect(seconds > 1 && seconds <= VoiceLimits.maxSeconds)
    }

    @Test(.enabled(if: AVSpeechTextToSpeech().isReady)) func wavOutputIsSelectedByExtension() async throws {
        let file = temp("reply.wav"); defer { try? FileManager.default.removeItem(at: file) }
        try await tts.synthesize("Kurz.", to: file)
        #expect(try Data(contentsOf: file).prefix(4) == Data("RIFF".utf8))
    }

    @Test(.enabled(if: AVSpeechTextToSpeech().isReady)) func overlongReplyIsRefusedAndLeavesNoFile() async throws {
        let file = temp("long.m4a"); defer { try? FileManager.default.removeItem(at: file) }
        let text = String(repeating: "Dies ist ein sehr langer Satz, der nicht enden will. ", count: 80)
        await #expect(throws: VoiceEngineError.replyTooLong) { try await tts.synthesize(text, to: file) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func missingVoiceMeansNotReady() {
        #expect(!AVSpeechTextToSpeech(language: "xx-XX").isReady)
    }

    @Test func whisperAdapterIsNotReadyWithoutModelAndNeverDownloads() async {
        let folder = temp("no-model")
        let stt = WhisperKitSpeechToText(modelFolder: folder)
        #expect(!stt.isReady)
        await #expect(throws: WhisperSetupError.modelMissing(folder.path)) {
            try await stt.transcribe(audioFile: URL(fileURLWithPath: "/nonexistent.m4a"))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path), "no download attempt, no folder created")
    }
}
