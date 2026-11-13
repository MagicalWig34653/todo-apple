import AVFoundation
import SwiftUI
import TodoCore

/// Plays the audio of channel messages (the brain's answers, and your own recordings). One message at a time; the file is
/// downloaded through the signed-in session into the caches folder and reused.
@MainActor @Observable
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    /// The message that is loading or playing.
    private(set) var activeID: UUID?
    private(set) var isLoading = false
    private(set) var isPlaying = false
    var failed = false

    @ObservationIgnored private var player: AVAudioPlayer?

    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "brain-audio", directoryHint: .isDirectory)
    }

    /// Removes downloaded audio (revoked consent, sign-out).
    static func clearCache() { try? FileManager.default.removeItem(at: cacheDirectory) }

    func isActive(_ message: BrainMessage) -> Bool { activeID == message.id && (isLoading || isPlaying) }

    func toggle(_ message: BrainMessage, _ app: AppModel) async {
        if isActive(message) { stop(); return }
        guard let attachmentID = message.attachmentID, let client = app.client else { return }
        stop()
        activeID = message.id
        isLoading = true; failed = false
        do {
            let file = try await client.downloadVoiceFile(attachmentID, into: Self.cacheDirectory)
            guard activeID == message.id else { return }  // stopped or replaced while loading
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            #endif
            let player = try AVAudioPlayer(contentsOf: file)
            player.delegate = self
            #if DEBUG
            if DebugVoice.muted { player.volume = 0 }
            #endif
            guard player.play() else { throw VoiceRecorderError.cannotStart }
            self.player = player
            isLoading = false; isPlaying = true
        } catch {
            isLoading = false; isPlaying = false; failed = true
            activeID = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false; isLoading = false; activeID = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
