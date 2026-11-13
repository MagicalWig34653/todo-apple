import Foundation
import Testing
import CryptoKit
@testable import TodoRunner
import TodoRunnerWhisper

/// Real native backend (scripts/runner-voice-live.sh): account with virtual passkey, paired device token, real M4A recordings,
/// voice_in posted like the app does, the voice worker against /v1/runner/voice/*, result read back from the channel.
/// Real WhisperKit transcription runs only when RUNNER_VOICE_MODEL_FOLDER points at a downloaded model; otherwise the
/// speech-to-text engine is a fake and that test is skipped (reported as not proven).
actor VoiceLiveAdmin {
    static let shared = VoiceLiveAdmin()
    private var client: LiveBackend?
    func get() async throws -> LiveBackend {
        if let client { return client }
        let env = ProcessInfo.processInfo.environment
        let c = try await LiveBackend.register(baseURL: LiveBackend.fromEnvironment(),
                                               token: env["RUNNER_LIVE_BOOTSTRAP_TOKEN"] ?? "dev-bootstrap-only", displayName: "Voice E2E")
        client = c
        return c
    }
}

struct LiveVoiceDevice {
    let server: URLSessionVoiceServer
    static func pair(_ admin: LiveBackend, label: String) async throws -> LiveVoiceDevice {
        let pairing = try await admin.call("POST", "/v1/agents/devices", ["label": label])
        let device = try await URLSessionRunnerServer.pair(baseURL: admin.baseURL, code: pairing["code"] as! String)
        return LiveVoiceDevice(server: URLSessionVoiceServer(baseURL: admin.baseURL, token: device.token))
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RUNNER_VOICE_LIVE"] == "1" && LiveBackend.configured))
struct VoiceLiveTests {
    static let modelFolder = ProcessInfo.processInfo.environment["RUNNER_VOICE_MODEL_FOLDER"]
    static let spoken = "Wie steht es um meine Aufgaben heute?"

    private func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voice-live-\(UUID().uuidString)").resolvingSymlinksInPath()
    }

    /// A real German M4A recording (system voice).
    private func recording(_ text: String, in directory: URL) async throws -> Data {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("spoken.m4a")
        try await AVSpeechTextToSpeech().synthesize(text, to: file)
        return try Data(contentsOf: file)
    }

    /// The person's side: upload the recording as a task-less voice attachment and post voice_in. Returns the message id.
    private func postVoice(_ admin: LiveBackend, _ audio: Data) async throws -> String {
        let begin = try await admin.call("POST", "/v1/attachments/begin", [
            "filename": "voice.m4a", "role": "voice", "mediaType": "audio/mp4", "size": audio.count,
            "checksum": SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()])
        var put = URLRequest(url: admin.baseURL.appending(path: (begin["uploadURL"] as! String)))
        put.httpMethod = "PUT"
        put.setValue("Bearer \(begin["token"] as! String)", forHTTPHeaderField: "Authorization")
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: put, from: audio)
        #expect((response as? HTTPURLResponse)?.statusCode == 200 || (response as? HTTPURLResponse)?.statusCode == 204)
        let attachmentID = begin["attachmentID"] as! String
        try await admin.call("POST", "/v1/attachments/\(attachmentID)/complete")
        let message = try await admin.call("POST", "/v1/channels/brain/messages", [
            "kind": "voice_in", "attachmentID": attachmentID, "clientUUID": UUID().uuidString.lowercased()])
        return message["id"] as! String
    }

    private func messages(_ admin: LiveBackend) async throws -> [[String: Any]] {
        (try await admin.call("GET", "/v1/channels/brain/messages"))["items"] as! [[String: Any]]
    }

    private func worker(_ device: LiveVoiceDevice, stt: any SpeechToText, tts: any TextToSpeech, work: URL,
                        lease: Duration = .seconds(30)) -> VoiceWorker {
        var settings = VoiceWorkerSettings(workDirectory: work.appendingPathComponent("work"))
        settings.leaseInterval = lease
        return VoiceWorker(server: device.server, stt: stt, tts: tts, settings: settings)
    }

    @Test func fakeSpeechEngineEndToEndWithRealTTSAndBackend() async throws {
        let admin = try await VoiceLiveAdmin.shared.get()
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let device = try await LiveVoiceDevice.pair(admin, label: "voice live Mac")
        let stt = FakeSTT(); stt.transcript = "Live Testsatz fuer den Brain Kanal"
        let w = worker(device, stt: stt, tts: AVSpeechTextToSpeech(), work: dir)
        try #require(w.capabilities() == ["sprache"], "needs a German system voice")
        _ = await w.reportCapabilities()
        let messageID = try await postVoice(admin, try await recording(Self.spoken, in: dir))

        #expect(await w.pollOnce() == .done)
        let items = try await messages(admin)
        let incoming = try #require(items.first { $0["id"] as? String == messageID })
        #expect(incoming["text"] as? String == stt.transcript)
        let reply = try #require(items.first { $0["kind"] as? String == "voice_out" })
        #expect(reply["text"] as? String == AcknowledgementResponseProvider.text)
        let replyAudio = try #require(reply["attachmentID"] as? String)
        var download = URLRequest(url: admin.baseURL.appending(path: "/v1/attachments/\(replyAudio)/download"))
        download.setValue("Bearer \(admin.session!)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await URLSession.shared.data(for: download)
        #expect((response as? HTTPURLResponse)?.statusCode == 200 && bytes.count > 1000)
        #expect(bytes.dropFirst(4).prefix(4) == Data("ftyp".utf8))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("work").path))?.isEmpty ?? true)
    }

    @Test func secondRunnerCannotTakeAJobWhileTheFirstHoldsTheLease() async throws {
        let admin = try await VoiceLiveAdmin.shared.get()
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await LiveVoiceDevice.pair(admin, label: "voice live A"), b = try await LiveVoiceDevice.pair(admin, label: "voice live B")
        let slow = FakeSTT(); slow.delay = .seconds(2)
        let first = worker(a, stt: slow, tts: FakeTTS(), work: dir.appendingPathComponent("a"), lease: .milliseconds(300))
        let second = worker(b, stt: FakeSTT(), tts: FakeTTS(), work: dir.appendingPathComponent("b"))
        _ = await first.reportCapabilities(); _ = await second.reportCapabilities()
        _ = try await postVoice(admin, try await recording("Zweiter Runner Test.", in: dir))
        async let firstOutcome = first.pollOnce()
        try await Task.sleep(for: .milliseconds(700))
        #expect(await second.pollOnce() == nil, "the lease of runner A (kept alive by heartbeats) blocks runner B")
        #expect(await firstOutcome == .done)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("a/work").path))?.isEmpty ?? true)
    }

    @Test(.enabled(if: VoiceLiveTests.modelFolder != nil)) func realWhisperKitTranscribesTheRecordingLocally() async throws {
        let admin = try await VoiceLiveAdmin.shared.get()
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let device = try await LiveVoiceDevice.pair(admin, label: "voice live whisper")
        let stt = WhisperKitSpeechToText(modelFolder: URL(fileURLWithPath: Self.modelFolder!))
        try #require(stt.isReady)
        let w = worker(device, stt: stt, tts: AVSpeechTextToSpeech(), work: dir)
        _ = await w.reportCapabilities()
        let messageID = try await postVoice(admin, try await recording(Self.spoken, in: dir))
        #expect(await w.pollOnce() == .done)
        let items = try await messages(admin)
        let text = ((try #require(items.first { $0["id"] as? String == messageID }))["text"] as? String ?? "").lowercased()
        print("LIVE-TRANSCRIPT-LENGTH", text.count)
        #expect(text.contains("aufgaben") && text.contains("heute"), "transcript did not contain the spoken keywords")
        #expect(items.contains { $0["kind"] as? String == "voice_out" })
    }
}
