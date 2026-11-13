import XCTest
@testable import TodoCore

/// A Mac runner as the voice jobs see it: paired device token, plain HTTP against `/v1/runner/*` (no mocks).
/// Used by the live test here and mirrored by the UI tests' own helper.
struct LiveVoiceRunner {
    let baseURL: URL
    let token: String

    struct Job: Decodable {
        let id: UUID
        let generation: Int
        let messageID: UUID
        let attachmentID: UUID
        let audio: Audio?
        struct Audio: Decodable { let mediaType: String; let size: Int; let checksum: String }
    }

    /// Pairs a new device for the account of `client` (one-time code from the session, exchanged without a session).
    static func pair(_ client: APIClient, label: String) async throws -> LiveVoiceRunner {
        let pairing = try await client.pairRunner(label: label)
        var request = URLRequest(url: client.baseURL.appending(path: "v1/runner/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": pairing.code])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return LiveVoiceRunner(baseURL: client.baseURL, token: try XCTUnwrap(object["token"] as? String))
    }

    private func call(_ method: String, _ path: String, query: [String: String] = [:], json: [String: Any]? = nil, body: Data? = nil,
                      contentType: String? = nil) async throws -> (Data, Int) {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let body {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        } else if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as! HTTPURLResponse).statusCode)
    }

    func heartbeat(_ capabilities: [String] = ["sprache"]) async throws {
        let (_, status) = try await call("POST", "v1/runner/voice/heartbeat", json: ["capabilities": capabilities])
        XCTAssertEqual(status, 200)
    }

    /// Claims the oldest job; nil when there is none (204).
    func claim() async throws -> Job? {
        let (data, status) = try await call("POST", "v1/runner/voice/claim")
        if status == 204 { return nil }
        XCTAssertEqual(status, 200, String(decoding: data, as: UTF8.self))
        return try JSONDecoder().decode(Job.self, from: data)
    }

    func downloadAudio(_ job: Job) async throws -> Data {
        let (data, status) = try await call("GET", "v1/runner/voice/jobs/\(job.id.uuidString)/audio", query: ["generation": String(job.generation)])
        XCTAssertEqual(status, 200)
        return data
    }

    func uploadReplyAudio(_ job: Job, _ audio: Data) async throws {
        let (data, status) = try await call("PUT", "v1/runner/voice/jobs/\(job.id.uuidString)/reply-audio",
                                            query: ["generation": String(job.generation)], body: audio, contentType: "audio/mp4")
        XCTAssertEqual(status, 200, String(decoding: data, as: UTF8.self))
    }

    func result(_ job: Job, transcript: String? = nil, replyText: String? = nil, errorCode: String? = nil) async throws {
        var body: [String: Any] = ["generation": job.generation]
        if let transcript { body["transcript"] = transcript }
        if let replyText { body["replyText"] = replyText }
        if let errorCode { body["errorCode"] = errorCode }
        let (data, status) = try await call("POST", "v1/runner/voice/jobs/\(job.id.uuidString)/result", json: body)
        XCTAssertEqual(status, 200, String(decoding: data, as: UTF8.self))
    }
}

/// The app client against the real native backend: voice upload without a task, `voice_in`, a runner that answers
/// through `/v1/runner/voice/*`, and reading the thread (cursor, since, audio download). Needs a FRESH database like the
/// other live tests (`TODO_LIVE_BASE_URL`).
final class LiveBrainTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "App/UITests/Fixtures")

    func testVoiceRoundTripThroughRunner() async throws {
        let f = try await LiveEtappe2Tests().fixture()
        let me = f.admin
        let recording = try Data(contentsOf: Self.fixtures.appending(path: "voice-sample.m4a"))
        let replyAudio = try Data(contentsOf: Self.fixtures.appending(path: "voice-reply.m4a"))

        // Empty channel is readable before anything was written.
        let empty = try await me.brainMessages()
        XCTAssertTrue(empty.items.isEmpty)

        // 1. No runner with the capability: the server answers with a status line, no job.
        let att1 = try await me.uploadVoiceRecording(data: recording)
        XCTAssertEqual(att1.role, "voice")
        XCTAssertEqual(att1.mediaType, "audio/mp4")
        let key1 = UUID()
        let first = try await me.postBrainVoice(attachmentID: att1.id, clientUUID: key1)
        XCTAssertTrue(first.created)
        XCTAssertEqual(first.message.kind, .voiceIn)
        XCTAssertEqual(first.message.attachmentID, att1.id)
        let repeated = try await me.postBrainVoice(attachmentID: att1.id, clientUUID: key1)
        XCTAssertFalse(repeated.created, "same clientUUID: idempotent repeat")
        XCTAssertEqual(repeated.message.id, first.message.id)
        var thread = BrainThread()
        let initial = try await me.brainMessages()
        thread.merge(firstPage: initial)
        let unreachable = try XCTUnwrap(thread.messages.first { $0.kind == .status })
        XCTAssertEqual(unreachable.author, .agent)
        XCTAssertEqual(unreachable.trimmedText, "Brain gerade nur per Text erreichbar.")
        XCTAssertTrue(thread.processingIDs.isEmpty, "the status line ends the wait")

        // 2. A paired runner reports "sprache" and answers the next recording.
        // The server stamps messages with second precision; a person never sends two recordings within one second.
        try await Task.sleep(for: .seconds(1.1))
        let runner = try await LiveVoiceRunner.pair(me, label: "Test-Mac \(f.suffix)")
        try await runner.heartbeat()
        let att2 = try await me.uploadVoiceRecording(data: recording)
        let second = try await me.postBrainVoice(attachmentID: att2.id)
        thread.add(second.message)
        XCTAssertEqual(thread.processingIDs, [second.message.id], "waiting for the runner")

        let claimed = try await runner.claim()
        let job = try XCTUnwrap(claimed)
        XCTAssertEqual(job.messageID, second.message.id)
        XCTAssertEqual(job.audio?.checksum, AttachmentRules.sha256Hex(recording))
        let heard = try await runner.downloadAudio(job)
        XCTAssertEqual(heard, recording, "the runner receives exactly what the app uploaded")
        try await runner.uploadReplyAudio(job, replyAudio)
        try await runner.result(job, transcript: "Hallo Brain, was steht heute an?", replyText: "Heute stehen zwei Aufgaben an.")

        // 3. The app reads the answer: since = only newer, voice_out has text and audio, the transcript is filled.
        let newer = try await me.brainMessages(since: second.message.createdAt)
        XCTAssertTrue(newer.items.contains { $0.kind == .voiceOut })
        thread.merge(newer: newer)
        let refreshed = try await me.brainMessages()
        thread.merge(firstPage: refreshed)
        let answer = try XCTUnwrap(thread.messages.first { $0.kind == .voiceOut })
        XCTAssertEqual(answer.author, .agent)
        XCTAssertEqual(answer.trimmedText, "Heute stehen zwei Aufgaben an.")
        let answerAudio = try XCTUnwrap(answer.attachmentID)
        XCTAssertTrue(thread.processingIDs.isEmpty)
        XCTAssertEqual(thread.messages.first { $0.id == second.message.id }?.trimmedText, "Hallo Brain, was steht heute an?")

        // The reply plays from the account's own download route (task-less voice attachment).
        let dir = FileManager.default.temporaryDirectory.appending(path: "live-brain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try await me.downloadVoiceFile(answerAudio, into: dir)
        XCTAssertEqual(try Data(contentsOf: file), replyAudio)

        // 4. Cursor paging: one message per page walks the whole history without gaps or duplicates.
        var walked: [UUID] = []
        var page = try await me.brainMessages(limit: 1)
        walked += page.items.map(\.id)
        while let next = page.nextCursor {
            page = try await me.brainMessages(limit: 1, cursor: next)
            walked += page.items.map(\.id)
        }
        XCTAssertEqual(walked, thread.messages.map(\.id))
        XCTAssertEqual(Set(walked).count, walked.count)

        // 5. Text goes through the same channel; another account sees nothing of it.
        let text = try await me.postBrainText("Danke dir")
        XCTAssertEqual(text.message.kind, .text)
        let bobSees = try await f.bob.brainMessages()
        XCTAssertTrue(bobSees.items.isEmpty, "the channel belongs to its owner")
        do { _ = try await f.bob.downloadVoiceFile(answerAudio, into: dir.appending(path: "bob")); XCTFail("foreign voice audio readable") }
        catch { XCTAssertEqual(error as? APIError, .notFound) }
    }
}
