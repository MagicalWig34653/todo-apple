import AVFoundation
import SwiftUI
import TodoCore

/// A finished recording on disk (AAC in an M4A container, mono).
struct VoiceRecording: Equatable {
    let url: URL
    let duration: TimeInterval
}

/// Push-to-talk recorder for the channel #brain: AAC/M4A mono, at most `VoiceRules.maxDuration` seconds.
/// Recording only runs between `start()` and `finish()`/`cancel()`; nothing is kept when cancelled.
@MainActor @Observable
final class VoiceRecorder: NSObject {
    enum Permission: Equatable { case granted, denied, undetermined }

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// 0...1, for the level indicator.
    private(set) var level: Float = 0
    /// Called once when the recording reached the maximum length and stopped by itself.
    @ObservationIgnored var onLimit: (() -> Void)?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?
    #if DEBUG
    @ObservationIgnored private var debugFile: URL?
    #endif

    static let minimumDuration: TimeInterval = 0.6

    static var permission: Permission {
        #if DEBUG
        if DebugVoice.fileURL != nil { return .granted }
        #endif
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    static func requestPermission() async -> Bool {
        #if DEBUG
        if DebugVoice.fileURL != nil { return true }
        #endif
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Starts recording. Throws when the audio session or the recorder cannot start (no input, interrupted by a call).
    func start() throws {
        guard !isRecording else { return }
        elapsed = 0; level = 0
        #if DEBUG
        if let file = DebugVoice.fileURL {
            // Simulator without microphone: the prepared real M4A stands in for the captured audio.
            debugFile = file
            begin()
            return
        }
        #endif
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
        if #available(iOS 26, *) { options.insert(.allowBluetoothHFP) } else { options.insert(.allowBluetooth) }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setActive(true)
        #endif
        let url = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString.lowercased()).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: VoiceRules.maxDuration) else { throw VoiceRecorderError.cannotStart }
        self.recorder = recorder
        begin()
    }

    private func begin() {
        isRecording = true
        startedAt = Date()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.isRecording else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let seconds = Date().timeIntervalSince(startedAt ?? Date())
        elapsed = min(seconds, VoiceRules.maxDuration)
        if let recorder {
            recorder.updateMeters()
            // -50 dB (quiet) ... 0 dB (loud) mapped to 0...1.
            level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 50) / 50))
        } else {
            level = 0.3 + 0.4 * Float(abs(sin(seconds * 6)))
        }
        if seconds >= VoiceRules.maxDuration {
            onLimit?()
        }
    }

    /// Stops and returns the recording; nil when it was shorter than `minimumDuration` (file removed).
    func finish() -> VoiceRecording? {
        guard isRecording else { return nil }
        let length = Date().timeIntervalSince(startedAt ?? Date())
        var url: URL?
        #if DEBUG
        if let debugFile {
            let copy = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString.lowercased()).m4a")
            try? FileManager.default.copyItem(at: debugFile, to: copy)
            url = copy
            self.debugFile = nil
        }
        #endif
        if let recorder {
            recorder.stop()
            url = recorder.url
            self.recorder = nil
        }
        reset()
        guard let url else { return nil }
        let duration = Self.duration(of: url) ?? length
        guard length >= Self.minimumDuration, duration >= Self.minimumDuration else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return VoiceRecording(url: url, duration: min(duration, VoiceRules.maxDuration))
    }

    /// Stops and throws the audio away.
    func cancel() {
        guard isRecording else { return }
        let url = recorder?.url
        recorder?.stop()
        recorder = nil
        #if DEBUG
        debugFile = nil
        #endif
        if let url { try? FileManager.default.removeItem(at: url) }
        reset()
    }

    private func reset() {
        ticker?.cancel(); ticker = nil
        isRecording = false
        elapsed = 0; level = 0
        startedAt = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

enum VoiceRecorderError: Error { case cannotStart }

#if DEBUG
/// Debug builds only: `TODO_DEBUG_VOICE_FILE=<path to an M4A>` replaces the microphone (the simulator has none): pressing
/// the record button "records" that file, everything after it (upload, `voice_in`, states) is the real code path.
enum DebugVoice {
    static var fileURL: URL? {
        guard let path = ProcessInfo.processInfo.environment["TODO_DEBUG_VOICE_FILE"], !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
    /// `TODO_DEBUG_VOICE_MUTE=1`: playback with volume 0 (UI tests must not speak out of the host's speakers).
    static var muted: Bool { ProcessInfo.processInfo.environment["TODO_DEBUG_VOICE_MUTE"] == "1" }
    /// `TODO_DEBUG_VOICE_AUTOSTART=1`: the brain screen starts "recording" on its own (screenshots of the recording state).
    static var autostart: Bool { ProcessInfo.processInfo.environment["TODO_DEBUG_VOICE_AUTOSTART"] == "1" }
    /// `TODO_DEBUG_VOICE_CONSENT=granted|off`: sets the consent of the signed-in account before the screen opens.
    static var consent: String? { ProcessInfo.processInfo.environment["TODO_DEBUG_VOICE_CONSENT"] }
}
#endif
