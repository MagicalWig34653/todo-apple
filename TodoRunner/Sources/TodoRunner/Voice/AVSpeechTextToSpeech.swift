import Foundation
import AVFoundation

/// Local TTS with `AVSpeechSynthesizer` (German system voice), written to an M4A (AAC) or WAV file. Nothing is played
/// and nothing leaves the Mac: `write(_:toBufferCallback:)` renders the speech into buffers only.
public final class AVSpeechTextToSpeech: TextToSpeech, @unchecked Sendable {
    public let language: String
    public let voiceIdentifier: String?
    public let timeout: TimeInterval

    public init(language: String = "de-DE", voiceIdentifier: String? = nil, timeout: TimeInterval = 90) {
        self.language = language; self.voiceIdentifier = voiceIdentifier; self.timeout = timeout
    }

    private func voice() -> AVSpeechSynthesisVoice? {
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) { return voice }
        return AVSpeechSynthesisVoice(language: language)
    }

    public var isReady: Bool { voice() != nil }

    /// Keeps the synthesizer alive and ends the session when speech is finished. An empty buffer is not a reliable end marker
    /// (long texts deliver empty buffers between sentences), so the delegate decides.
    private final class Holder: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        var synthesizer: AVSpeechSynthesizer?
        var session: Session?
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { session?.finish() }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { session?.finish() }
    }

    /// State shared between the synthesizer callback thread and the awaiting task.
    private final class Session: @unchecked Sendable {
        let lock = NSLock()
        var file: AVAudioFile?
        var frames: AVAudioFramePosition = 0
        var sampleRate: Double = 0
        var failure: Error?
        var finished = false
        var continuation: CheckedContinuation<Void, Never>?
        func attach(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            if finished { lock.unlock(); continuation.resume() } else { self.continuation = continuation; lock.unlock() }
        }
        /// Closes the file (finalizes the AAC container) and returns the outcome.
        func close() -> (failure: Error?, frames: AVAudioFramePosition) {
            lock.lock(); defer { lock.unlock() }
            file = nil
            return (failure, frames)
        }
        func finish(_ error: Error? = nil) {
            lock.lock()
            if let error, failure == nil { failure = error }
            let waiting = finished ? nil : continuation
            finished = true; continuation = nil
            lock.unlock()
            waiting?.resume()
        }
    }

    public func synthesize(_ text: String, to file: URL) async throws {
        guard let voice = voice() else { throw VoiceEngineError.engineUnavailable }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let wav = file.pathExtension.lowercased() == "wav"
        let session = Session()
        let holder = Holder()
        holder.session = session
        let url = file
        let limit = VoiceLimits.maxSeconds

        await MainActor.run {
            let synthesizer = AVSpeechSynthesizer()
            holder.synthesizer = synthesizer
            synthesizer.delegate = holder
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { return }
                session.lock.lock()
                defer { session.lock.unlock() }
                guard session.failure == nil, !session.finished else { return }
                do {
                    if session.file == nil {
                        let settings: [String: Any] = wav
                            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: pcm.format.sampleRate, AVNumberOfChannelsKey: 1,
                               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
                            : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: pcm.format.sampleRate, AVNumberOfChannelsKey: 1,
                               AVEncoderBitRateKey: 48_000]
                        session.file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: pcm.format.commonFormat,
                                                       interleaved: pcm.format.isInterleaved)
                        session.sampleRate = pcm.format.sampleRate
                    }
                    try session.file?.write(from: pcm)
                    session.frames += AVAudioFramePosition(pcm.frameLength)
                    if Double(session.frames) / max(session.sampleRate, 1) > limit {
                        session.failure = VoiceEngineError.replyTooLong
                        DispatchQueue.main.async { holder.synthesizer?.stopSpeaking(at: .immediate) }
                        // stopSpeaking may not deliver the final empty buffer; do not wait for it.
                        DispatchQueue.global().async { session.finish(VoiceEngineError.replyTooLong) }
                    }
                } catch {
                    session.failure = error
                    DispatchQueue.global().async { session.finish(error) }
                }
            }
        }

        let deadline = Task { [timeout] in
            try? await Task.sleep(for: .seconds(timeout))
            session.finish(VoiceEngineError.synthesisFailed("timeout"))
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.attach(continuation)
        }
        deadline.cancel()
        withExtendedLifetime(holder) {}
        let (failure, frames) = session.close()
        if let failure { try? FileManager.default.removeItem(at: file); throw failure }
        guard frames > 0 else { try? FileManager.default.removeItem(at: file); throw VoiceEngineError.emptyResult }
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int) ?? 0
        guard size <= VoiceLimits.maxBytes else { try? FileManager.default.removeItem(at: file); throw VoiceEngineError.replyTooLong }
    }
}
