import Foundation
import Testing
import CryptoKit
@testable import TodoRunner

// MARK: Fakes

actor FakeVoiceServer: VoiceServer {
    var queue: [VoiceJob] = []
    var audio = Data("recording-bytes".utf8)
    var claimError: RunnerServerError?
    var leaseError: RunnerServerError?
    var uploadError: RunnerServerError?
    var resultError: RunnerServerError?
    var downloadError: RunnerServerError?
    private(set) var capabilityReports: [[String]] = []
    private(set) var claimCalls = 0
    private(set) var leaseCalls: [Int] = []
    private(set) var downloads: [Int] = []
    private(set) var uploads: [Data] = []
    private(set) var results: [(generation: Int, transcript: String?, replyText: String?, errorCode: String?)] = []

    func set(audio: Data) { self.audio = audio }
    func enqueue(_ job: VoiceJob) { queue.append(job) }
    func set(claimError e: RunnerServerError?) { claimError = e }
    func set(leaseError e: RunnerServerError?) { leaseError = e }
    func set(uploadError e: RunnerServerError?) { uploadError = e }
    func set(resultError e: RunnerServerError?) { resultError = e }
    func set(downloadError e: RunnerServerError?) { downloadError = e }

    func heartbeat(capabilities: [String]) async throws -> [String] { capabilityReports.append(capabilities); return capabilities }
    func claimNext() async throws -> VoiceJob? {
        claimCalls += 1
        if let claimError { throw claimError }
        return queue.isEmpty ? nil : queue.removeFirst()
    }
    func heartbeat(jobID: UUID, generation: Int) async throws -> VoiceJob {
        leaseCalls.append(generation)
        if let leaseError { throw leaseError }
        return VoiceJob(id: jobID, generation: generation, leaseUntil: Date().addingTimeInterval(60))
    }
    func downloadAudio(jobID: UUID, generation: Int) async throws -> Data {
        downloads.append(generation)
        if let downloadError { throw downloadError }
        return audio
    }
    func uploadReplyAudio(jobID: UUID, generation: Int, audio: Data, mediaType: String) async throws {
        if let uploadError { throw uploadError }
        uploads.append(audio)
    }
    func result(jobID: UUID, generation: Int, transcript: String?, replyText: String?, errorCode: String?) async throws {
        if let resultError { throw resultError }
        results.append((generation, transcript, replyText, errorCode))
    }
}

final class FakeSTT: SpeechToText, @unchecked Sendable {
    var ready = true
    var transcript = "Das ist ein geheimer Testsatz."
    var delay: Duration = .zero
    var error: Error?
    private let lock = NSLock()
    private var _seen: [(path: String, existed: Bool)] = []
    var seen: [(path: String, existed: Bool)] { lock.withLock { _seen } }
    var isReady: Bool { ready }
    func transcribe(audioFile: URL) async throws -> String {
        lock.withLock { _seen.append((audioFile.path, FileManager.default.fileExists(atPath: audioFile.path))) }
        if delay != .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
        return transcript
    }
}

final class FakeTTS: TextToSpeech, @unchecked Sendable {
    var ready = true
    var error: Error?
    private let lock = NSLock()
    private var _files: [String] = []
    var files: [String] { lock.withLock { _files } }
    var isReady: Bool { ready }
    func synthesize(_ text: String, to file: URL) async throws {
        if let error { throw error }
        lock.withLock { _files.append(file.path) }
        try Data("reply-audio".utf8).write(to: file)
    }
}

final class VoiceLogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

func voiceJob(generation: Int = 1, audio: Data = Data("recording-bytes".utf8), checksum: String? = nil) -> VoiceJob {
    VoiceJob(generation: generation, leaseUntil: Date().addingTimeInterval(60),
             audio: VoiceAudioInfo(mediaType: "audio/mp4", size: audio.count, checksum: checksum ?? sha(audio)))
}

struct VoiceRig {
    let server = FakeVoiceServer()
    let stt = FakeSTT()
    let tts = FakeTTS()
    let log = VoiceLogBox()
    let work: URL
    init() { work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voice-test-\(UUID().uuidString)").resolvingSymlinksInPath() }
    func worker(lease: Duration = .milliseconds(30), responder: any ResponseProvider = AcknowledgementResponseProvider()) -> VoiceWorker {
        var settings = VoiceWorkerSettings(workDirectory: work)
        settings.leaseInterval = lease; settings.capabilityInterval = .milliseconds(30); settings.pollInterval = .milliseconds(10)
        let log = log
        settings.log = { log.add($0) }
        return VoiceWorker(server: server, stt: stt, tts: tts, responder: responder, settings: settings)
    }
    func leftovers() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? [] }
    func cleanup() { try? FileManager.default.removeItem(at: work) }
}

struct ThrowingResponder: ResponseProvider {
    func reply(toTranscript transcript: String) async throws -> String { throw VoiceEngineError.emptyResult }
}

// MARK: Tests

@Suite struct VoiceWorkerTests {
    @Test func capabilityNeedsSpeechModelAndVoice() async {
        let rig = VoiceRig(); defer { rig.cleanup() }
        let worker = rig.worker()
        #expect(worker.capabilities() == ["sprache"])
        rig.stt.ready = false
        #expect(worker.capabilities() == [])
        rig.stt.ready = true; rig.tts.ready = false
        #expect(worker.capabilities() == [])
        rig.tts.ready = false; rig.stt.ready = false
        #expect(worker.capabilities() == [])
    }

    @Test func capabilityHeartbeatReportsWhatIsAvailable() async {
        let rig = VoiceRig(); defer { rig.cleanup() }
        let worker = rig.worker()
        _ = await worker.reportCapabilities()
        rig.tts.ready = false
        _ = await worker.reportCapabilities()
        #expect(await rig.server.capabilityReports == [["sprache"], []])
    }

    @Test func noClaimWithoutCapability() async {
        let rig = VoiceRig(); defer { rig.cleanup() }
        rig.stt.ready = false
        await rig.server.enqueue(voiceJob())
        #expect(await rig.worker().pollOnce() == nil)
        #expect(await rig.server.claimCalls == 0)
    }

    @Test func happyPathDeliversTranscriptAcknowledgementAndAudioAndCleansUp() async throws {
        let rig = VoiceRig(); defer { rig.cleanup() }
        await rig.server.enqueue(voiceJob(generation: 3))
        let outcome = await rig.worker().pollOnce()
        #expect(outcome == .done)
        let results = await rig.server.results
        #expect(results.count == 1)
        #expect(results[0].generation == 3 && results[0].transcript == rig.stt.transcript)
        #expect(results[0].replyText == AcknowledgementResponseProvider.text && results[0].errorCode == nil)
        #expect(await rig.server.uploads == [Data("reply-audio".utf8)])
        #expect(await rig.server.downloads == [3])
        // The engine got a real file, and nothing is left behind afterwards.
        let seen = try #require(rig.stt.seen.first)
        #expect(seen.existed)
        #expect(!FileManager.default.fileExists(atPath: seen.path))
        #expect(!FileManager.default.fileExists(atPath: try #require(rig.tts.files.first)))
        #expect(rig.leftovers().isEmpty)
    }

    @Test func claimRaceLoserDoesNothing() async {
        let rig = VoiceRig(); defer { rig.cleanup() }
        await rig.server.set(claimError: .conflict("voice_job_running"))
        #expect(await rig.worker().pollOnce() == nil)
        await rig.server.set(claimError: .gone("job_ended"))
        #expect(await rig.worker().pollOnce() == nil)
        await rig.server.set(claimError: nil)  // nothing queued: 204
        #expect(await rig.worker().pollOnce() == nil)
        #expect(rig.stt.seen.isEmpty)
        #expect(await rig.server.results.isEmpty && rig.leftovers().isEmpty)
    }

    @Test func leaseHeartbeatsRunWithTheClaimedGenerationWhileWorking() async {
        let rig = VoiceRig(); defer { rig.cleanup() }
        rig.stt.delay = .milliseconds(250)
        await rig.server.enqueue(voiceJob(generation: 7))
        #expect(await rig.worker(lease: .milliseconds(40)).pollOnce() == .done)
        let beats = await rig.server.leaseCalls
        #expect(beats.count >= 3 && Set(beats) == [7])
    }

    @Test func lostLeaseStopsPublishingAndCleansUp() async {
        let rig = VoiceRig(); defer { rig.cleanup() }
        rig.stt.delay = .seconds(5)
        await rig.server.set(leaseError: .gone("lease_lost"))
        await rig.server.enqueue(voiceJob())
        let started = Date()
        #expect(await rig.worker(lease: .milliseconds(30)).pollOnce() == .leaseLost)
        #expect(Date().timeIntervalSince(started) < 3, "the slow engine must be cancelled")
        #expect(await rig.server.results.isEmpty)
        #expect(await rig.server.uploads.isEmpty)
        #expect(rig.leftovers().isEmpty)
    }

    @Test func staleGenerationOnHeartbeatIsLeaseLossToo() async {
        let rig = VoiceRig(); defer { rig.cleanup() }
        rig.stt.delay = .seconds(5)
        await rig.server.set(leaseError: .conflict("stale_generation"))
        await rig.server.enqueue(voiceJob())
        #expect(await rig.worker(lease: .milliseconds(30)).pollOnce() == .leaseLost)
        #expect(await rig.server.results.isEmpty && rig.leftovers().isEmpty)
    }

    @Test func conflictOnResultOrUploadMeansLeaseLost() async {
        let rig = VoiceRig(); defer { rig.cleanup() }
        await rig.server.set(resultError: .gone("lease_lost"))
        await rig.server.enqueue(voiceJob())
        #expect(await rig.worker().pollOnce() == .leaseLost)
        #expect(rig.leftovers().isEmpty)

        await rig.server.set(resultError: nil)
        await rig.server.set(uploadError: .conflict("stale_generation"))
        await rig.server.enqueue(voiceJob())
        #expect(await rig.worker().pollOnce() == .leaseLost)
        #expect(await rig.server.results.isEmpty, "no result after a fenced upload")
        #expect(rig.leftovers().isEmpty)
    }

    @Test func downloadFencedOrNetworkDown() async {
        let rig = VoiceRig(); defer { rig.cleanup() }
        await rig.server.set(downloadError: .gone("lease_lost"))
        await rig.server.enqueue(voiceJob())
        #expect(await rig.worker().pollOnce() == .leaseLost)
        await rig.server.set(downloadError: .transport("offline"))
        await rig.server.enqueue(voiceJob())
        #expect(await rig.worker().pollOnce() == .undelivered)
        #expect(rig.stt.seen.isEmpty && rig.leftovers().isEmpty)
    }

    @Test func engineFailureIsReportedAsErrorCodeAndFilesAreRemoved() async throws {
        let rig = VoiceRig(); defer { rig.cleanup() }
        rig.stt.error = VoiceEngineError.engineUnavailable
        await rig.server.enqueue(voiceJob())
        #expect(await rig.worker().pollOnce() == .reportedFailure("transcription_failed"))
        let result = try #require(await rig.server.results.first)
        #expect(result.errorCode == "transcription_failed" && result.transcript == nil && result.replyText == nil)
        #expect(!FileManager.default.fileExists(atPath: try #require(rig.stt.seen.first).path))
        #expect(rig.leftovers().isEmpty)
    }

    @Test func responderFailureIsReported() async throws {
        let rig = VoiceRig(); defer { rig.cleanup() }
        await rig.server.enqueue(voiceJob())
        #expect(await rig.worker(responder: ThrowingResponder()).pollOnce() == .reportedFailure("reply_failed"))
        #expect(rig.leftovers().isEmpty)
    }

    @Test func corruptDownloadIsRejectedBeforeAnyEngineSeesIt() async {
        let rig = VoiceRig(); defer { rig.cleanup() }
        await rig.server.enqueue(voiceJob(checksum: String(repeating: "0", count: 64)))
        #expect(await rig.worker().pollOnce() == .reportedFailure("audio_corrupt"))
        #expect(rig.stt.seen.isEmpty && rig.leftovers().isEmpty)
    }

    @Test func missingSynthesisStillDeliversTextOnly() async throws {
        let rig = VoiceRig(); defer { rig.cleanup() }
        rig.tts.error = VoiceEngineError.synthesisFailed("x")
        await rig.server.enqueue(voiceJob())
        #expect(await rig.worker().pollOnce() == .done)
        #expect(await rig.server.uploads.isEmpty)
        let result = try #require(await rig.server.results.first)
        #expect(result.replyText == AcknowledgementResponseProvider.text)
        #expect(rig.leftovers().isEmpty)
    }

    @Test func logsNeverContainTranscriptsOrReplyTexts() async {
        let rig = VoiceRig(); defer { rig.cleanup() }
        rig.stt.transcript = "STRENGGEHEIMER-SATZ-4711"
        await rig.server.enqueue(voiceJob())
        _ = await rig.worker().pollOnce()
        rig.stt.error = VoiceEngineError.engineUnavailable
        await rig.server.enqueue(voiceJob())
        _ = await rig.worker().pollOnce()
        let joined = rig.log.all.joined(separator: "\n")
        #expect(!rig.log.all.isEmpty)
        #expect(!joined.contains("STRENGGEHEIMER") && !joined.contains(AcknowledgementResponseProvider.text))
    }

    @Test func startupSweepRemovesLeftoversOfACrash() async throws {
        let rig = VoiceRig(); defer { rig.cleanup() }
        let stale = rig.work.appendingPathComponent("old-job-1")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stale.appendingPathComponent("in.m4a"))
        await rig.worker().sweepWorkDirectory()
        #expect(rig.leftovers().isEmpty)
    }

    @Test func runLoopReportsCapabilitiesAndWorksQueuedJobs() async {
        let rig = VoiceRig(); defer { rig.cleanup() }
        await rig.server.enqueue(voiceJob())
        let worker = rig.worker()
        let task = Task { await worker.runLoop() }
        let done = await eventually { await rig.server.results.count == 1 }
        task.cancel()
        await task.value
        #expect(done)
        #expect(await rig.server.capabilityReports.first == ["sprache"])
        #expect(rig.leftovers().isEmpty)
    }
}

// MARK: Network guard

/// Records every request that reaches the "network"; answers like the voice API of a user's server.
final class VoiceGuardProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data("{}".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let status = request.url?.path.hasSuffix("/claim") == true && Self.body.isEmpty ? 204 : Self.status
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct VoiceNetworkTests {
    let base = URL(string: "https://todo.example/")!
    func server(status: Int = 200, body: String = "{}") -> URLSessionVoiceServer {
        VoiceGuardProtocol.requests = []; VoiceGuardProtocol.status = status; VoiceGuardProtocol.body = Data(body.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceGuardProtocol.self]
        return URLSessionVoiceServer(baseURL: base, token: "device-token", session: URLSession(configuration: configuration))
    }

    @Test func requestShapesFollowTheContract() async throws {
        let s = server(body: #"{"capabilities":["sprache"]}"#)
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        #expect(try await s.heartbeat(capabilities: ["sprache"]) == ["sprache"])
        VoiceGuardProtocol.body = Data(#"{"id":"11111111-1111-1111-1111-111111111111","state":"claimed","generation":4,"messageID":"22222222-2222-2222-2222-222222222222","attachmentID":"33333333-3333-3333-3333-333333333333","leaseUntil":"2026-11-13T12:00:00.500Z","audio":{"mediaType":"audio/mp4","size":3,"checksum":"abc"}}"#.utf8)
        let job = try #require(try await s.claimNext())
        #expect(job.generation == 4 && job.audio?.size == 3)
        _ = try await s.heartbeat(jobID: id, generation: 4)
        _ = try await s.downloadAudio(jobID: id, generation: 4)
        try await s.uploadReplyAudio(jobID: id, generation: 4, audio: Data("a".utf8), mediaType: "audio/mp4")
        try await s.result(jobID: id, generation: 4, transcript: "t", replyText: "r", errorCode: nil)
        let seen = VoiceGuardProtocol.requests
        #expect(seen.map { "\($0.httpMethod!) \($0.url!.path)" } == [
            "POST /v1/runner/voice/heartbeat", "POST /v1/runner/voice/claim",
            "POST /v1/runner/voice/jobs/11111111-1111-1111-1111-111111111111/heartbeat",
            "GET /v1/runner/voice/jobs/11111111-1111-1111-1111-111111111111/audio",
            "PUT /v1/runner/voice/jobs/11111111-1111-1111-1111-111111111111/reply-audio",
            "POST /v1/runner/voice/jobs/11111111-1111-1111-1111-111111111111/result"])
        #expect(seen.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer device-token" })
        #expect(seen[3].url?.query == "generation=4" && seen[4].url?.query == "generation=4")
        #expect(seen[4].value(forHTTPHeaderField: "Content-Type") == "audio/mp4")
    }

    @Test func noContentMeansNoJobAndFencingStatusesAreMapped() async throws {
        let s = server(body: "")
        #expect(try await s.claimNext() == nil)
        let id = UUID()
        for (status, expected) in [(409, RunnerServerError.conflict("")), (410, .gone("")), (404, .notFound), (401, .unauthorized)] {
            let failing = server(status: status, body: "{}")
            await #expect(throws: expected) { try await failing.heartbeat(jobID: id, generation: 1) }
        }
    }

    /// The whole job goes through a real `URLSessionVoiceServer`; every request must go to the user's server and to nothing else.
    @Test func jobProcessingTouchesOnlyTheUsersServer() async throws {
        let rig = VoiceRig(); defer { rig.cleanup() }
        let audio = Data("recording-bytes".utf8)
        VoiceGuardProtocol.requests = []; VoiceGuardProtocol.status = 200
        VoiceGuardProtocol.body = Data(#"{"id":"11111111-1111-1111-1111-111111111111","state":"claimed","generation":2,"messageID":"22222222-2222-2222-2222-222222222222","attachmentID":"33333333-3333-3333-3333-333333333333","audio":{"mediaType":"audio/mp4","size":\#(audio.count),"checksum":"\#(sha(audio))"}}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceGuardProtocol.self]
        let server = URLSessionVoiceServer(baseURL: URL(string: "https://todo.example/")!, token: "t", session: URLSession(configuration: configuration))
        var settings = VoiceWorkerSettings(workDirectory: rig.work); settings.leaseInterval = .seconds(30)
        // The audio download returns the JSON above, so serve the right bytes for that one path.
        let worker = VoiceWorker(server: GuardedAudio(inner: server, audio: audio), stt: rig.stt, tts: rig.tts, settings: settings)
        #expect(await worker.pollOnce() == .done)
        let hosts = Set(VoiceGuardProtocol.requests.compactMap { $0.url?.host })
        #expect(hosts == ["todo.example"])
        #expect(VoiceGuardProtocol.requests.allSatisfy { $0.url!.path.hasPrefix("/v1/runner/voice/") })
    }

    @Test func externalEnginesMustBeOnLoopback() throws {
        #expect(throws: VoiceEngineError.notLoopback("voice.example.com")) {
            try HTTPSpeechToText(endpoint: URL(string: "https://voice.example.com")!, apiKey: "k")
        }
        #expect(throws: VoiceEngineError.notLoopback("192.168.1.20")) {
            try HTTPSpeechToText(endpoint: URL(string: "http://192.168.1.20:8080")!, apiKey: "k")
        }
        _ = try HTTPSpeechToText(endpoint: URL(string: "http://127.0.0.1:8080")!, apiKey: "k")
        _ = try HTTPSpeechToText(endpoint: URL(string: "http://localhost:8080")!, apiKey: "k")
    }

    @Test func voiceConfigRoundTripsAndDefaultsToWhisperKit() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voice-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!VoiceConfig.exists(in: dir))
        try VoiceConfig(modelFolder: "/models/x").save(to: dir)
        let loaded = try VoiceConfig.load(from: dir)
        #expect(loaded.engine == .whisperKit && loaded.model == VoiceConfig.defaultModel && loaded.modelFolder == "/models/x")
    }
}

/// Wraps a real `URLSessionVoiceServer` but returns real audio bytes for the download (the guard protocol answers JSON for all paths).
struct GuardedAudio: VoiceServer {
    let inner: URLSessionVoiceServer
    let audio: Data
    func heartbeat(capabilities: [String]) async throws -> [String] { try await inner.heartbeat(capabilities: capabilities) }
    func claimNext() async throws -> VoiceJob? { try await inner.claimNext() }
    func heartbeat(jobID: UUID, generation: Int) async throws -> VoiceJob { try await inner.heartbeat(jobID: jobID, generation: generation) }
    func downloadAudio(jobID: UUID, generation: Int) async throws -> Data {
        _ = try await inner.downloadAudio(jobID: jobID, generation: generation)  // the request itself still goes through the guard
        return audio
    }
    func uploadReplyAudio(jobID: UUID, generation: Int, audio: Data, mediaType: String) async throws {
        try await inner.uploadReplyAudio(jobID: jobID, generation: generation, audio: audio, mediaType: mediaType)
    }
    func result(jobID: UUID, generation: Int, transcript: String?, replyText: String?, errorCode: String?) async throws {
        try await inner.result(jobID: jobID, generation: generation, transcript: transcript, replyText: replyText, errorCode: errorCode)
    }
}
