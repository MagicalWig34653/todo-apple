import XCTest
@testable import TodoCore

final class BrainChannelTests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let aid = UUID()
    let m4a = Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20, 1, 2, 3, 4])

    override func setUp() {
        MockURLProtocol.seen = []
        MockURLProtocol.handler = nil
        try? store.save("tok")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: URL(string: "http://test.invalid")!, session: URLSession(configuration: config), tokenStore: store)
    }

    private func message(_ id: UUID = UUID(), kind: String = "text", author: String = "person", text: String? = "hi",
                         at: String = "2026-11-13T10:00:00.000Z", attachment: UUID? = nil) -> String {
        let t = text.map { #""text":"\#($0)","# } ?? ""
        let a = attachment.map { #""attachmentID":"\#($0)","# } ?? ""
        return #"{"id":"\#(id)","kind":"\#(kind)","author":"\#(author)",\#(t)\#(a)"createdAt":"\#(at)"}"#
    }

    private func page(_ items: [String], next: String? = nil) -> BrainMessagePage {
        let n = next.map { #""\#($0)""# } ?? "null"
        let data = Data(#"{"items":[\#(items.joined(separator: ","))],"nextCursor":\#(n)}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithMillis
        return try! decoder.decode(BrainMessagePage.self, from: data)
    }

    // MARK: Models

    func testDecodesAllKindsAndUnknownValues() throws {
        let json = "[" + [
            message(kind: "text"), message(kind: "voice_in", text: nil, attachment: UUID()),
            message(kind: "voice_out", author: "agent", attachment: UUID()), message(kind: "status", author: "agent"),
            message(kind: "future_kind", author: "robot"),
        ].joined(separator: ",") + "]"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithMillis
        let items = try decoder.decode([BrainMessage].self, from: Data(json.utf8))
        XCTAssertEqual(items.map(\.kind), [.text, .voiceIn, .voiceOut, .status, BrainMessageKind(rawValue: "future_kind")])
        XCTAssertTrue(items[0].isMine)
        XCTAssertTrue(items[1].hasAudio)
        XCTAssertNil(items[1].text)
        XCTAssertFalse(items[4].isMine, "unknown author never counts as the person")
    }

    func testThreadMergesNewestFirstAndDeduplicates() {
        var thread = BrainThread()
        let a = UUID(), b = UUID(), c = UUID()
        thread.merge(firstPage: page([message(b, at: "2026-11-13T10:02:00.000Z"), message(a, at: "2026-11-13T10:01:00.000Z")], next: "cur1"))
        XCTAssertEqual(thread.messages.map(\.id), [b, a])
        XCTAssertEqual(thread.olderCursor, "cur1")
        // A refetch with a new message and a changed transcript of the oldest: merged, cursor kept.
        thread.merge(firstPage: page([message(c, at: "2026-11-13T10:03:00.000Z"), message(a, text: "neu", at: "2026-11-13T10:01:00.000Z")], next: "other"))
        XCTAssertEqual(thread.messages.map(\.id), [c, b, a])
        XCTAssertEqual(thread.messages.last?.text, "neu")
        XCTAssertEqual(thread.olderCursor, "cur1")
        XCTAssertEqual(thread.chronological.map(\.id), [a, b, c])
        // Older page: appended, cursor replaced; the last page has none.
        let old = UUID()
        thread.append(olderPage: page([message(old, at: "2026-11-13T09:00:00.000Z")]))
        XCTAssertEqual(thread.messages.last?.id, old)
        XCTAssertNil(thread.olderCursor)
        XCTAssertEqual(thread.newest, thread.messages.first?.createdAt)
    }

    func testProcessingIsVoiceInWithoutLaterAgentMessage() {
        var thread = BrainThread()
        let v1 = UUID(), v2 = UUID()
        thread.merge(firstPage: page([
            message(v2, kind: "voice_in", text: nil, at: "2026-11-13T10:05:00.000Z", attachment: UUID()),
            message(kind: "voice_out", author: "agent", at: "2026-11-13T10:03:00.000Z", attachment: UUID()),
            message(v1, kind: "voice_in", text: "hallo", at: "2026-11-13T10:01:00.000Z", attachment: UUID()),
        ]))
        XCTAssertEqual(thread.processingIDs, [v2], "the answered recording is done, the newer one waits")
        thread.add(try! decode(message(kind: "status", author: "agent", text: "Brain gerade nur per Text erreichbar.", at: "2026-11-13T10:05:01.000Z")))
        XCTAssertTrue(thread.processingIDs.isEmpty, "a status line of the brain ends the wait")
    }

    private func decode(_ json: String) throws -> BrainMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithMillis
        return try decoder.decode(BrainMessage.self, from: Data(json.utf8))
    }

    // MARK: Requests

    func testListSendsLimitCursorAndSince() async throws {
        MockURLProtocol.handler = { _ in (200, Data(#"{"items":[],"nextCursor":null}"#.utf8)) }
        let since = Date(timeIntervalSince1970: 1_800_000_000.123)
        _ = try await client.brainMessages(limit: 20, cursor: "abc", since: since)
        let url = try XCTUnwrap(MockURLProtocol.seen.first?.url)
        XCTAssertEqual(url.path, "/v1/channels/brain/messages")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "20")
        XCTAssertEqual(items.first { $0.name == "cursor" }?.value, "abc")
        XCTAssertEqual(items.first { $0.name == "since" }?.value, "2027-01-15T08:00:00.123Z")
        XCTAssertEqual(MockURLProtocol.seen.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testPostTextAndVoiceShapesAndCreatedFlag() async throws {
        let id = UUID(), clientID = UUID()
        MockURLProtocol.handler = { r in
            let body = (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any]
            return (body?["kind"] as? String == "voice_in" ? 200 : 201, Data(self.message(id, kind: body?["kind"] as? String ?? "text").utf8))
        }
        let text = try await client.postBrainText("  Hallo Brain  ", clientUUID: clientID)
        XCTAssertTrue(text.created)
        let voice = try await client.postBrainVoice(attachmentID: aid, clientUUID: clientID)
        XCTAssertFalse(voice.created, "200 = idempotent repeat")
        func body(_ i: Int) -> [String: Any] { (try? JSONSerialization.jsonObject(with: MockURLProtocol.seen[i].httpBody ?? Data())) as? [String: Any] ?? [:] }
        XCTAssertEqual(body(0)["kind"] as? String, "text")
        XCTAssertEqual(body(0)["text"] as? String, "Hallo Brain")
        XCTAssertNil(body(0)["attachmentID"])
        XCTAssertEqual(body(0)["clientUUID"] as? String, clientID.uuidString)
        XCTAssertEqual(body(1)["kind"] as? String, "voice_in")
        XCTAssertEqual(body(1)["attachmentID"] as? String, aid.uuidString)
        XCTAssertNil(body(1)["text"])
    }

    func testPostTextRejectsLocally() async {
        for bad in ["   ", String(repeating: "x", count: BrainRules.maxTextLength + 1)] {
            do { _ = try await client.postBrainText(bad); XCTFail() }
            catch { XCTAssertEqual(error as? APIError, .invalidInput(reason: "invalid_text")) }
        }
        XCTAssertTrue(MockURLProtocol.seen.isEmpty)
    }

    func testServerErrorsMap() async {
        for (status, reason, expected): (Int, String, APIError) in [
            (429, "voice_rate_limited", .server(status: 429, reason: "voice_rate_limited")),
            (409, "attachment_in_use", .conflict(reason: "attachment_in_use")),
            (422, "invalid_attachment", .invalidInput(reason: "invalid_attachment")),
            (404, "x", .notFound),
        ] {
            MockURLProtocol.handler = { _ in (status, Data(#"{"reason":"\#(reason)"}"#.utf8)) }
            do { _ = try await client.postBrainVoice(attachmentID: aid); XCTFail() }
            catch { XCTAssertEqual(error as? APIError, expected) }
        }
    }

    // MARK: Voice attachment without a task

    private var capabilityJSON: String {
        #"{"attachmentID":"\#(aid)","uploadURL":"/v1/attachments/\#(aid)/upload","token":"cap-token","expiresAt":"2026-10-27T10:15:00Z"}"#
    }

    func testVoiceUploadHasNoTaskIDAndRoleVoice() async throws {
        MockURLProtocol.handler = { r in
            switch (r.httpMethod, r.url?.path) {
            case ("POST", "/v1/attachments/begin"): return (200, Data(self.capabilityJSON.utf8))
            case ("PUT", _): return (204, Data())
            default:
                return (200, Data(#"{"id":"\#(self.aid)","filename":"voice.m4a","role":"voice","mediaType":"audio/mp4","size":16,"checksum":"\#(AttachmentRules.sha256Hex(self.m4a))","status":"complete"}"#.utf8))
            }
        }
        let result = try await client.uploadVoiceRecording(data: m4a)
        XCTAssertEqual(result.id, aid)
        XCTAssertEqual(result.role, "voice")
        let seen = MockURLProtocol.seen
        XCTAssertEqual(seen.map(\.httpMethod), ["POST", "PUT", "POST"])
        let body = (try? JSONSerialization.jsonObject(with: seen[0].httpBody ?? Data())) as? [String: Any] ?? [:]
        XCTAssertNil(body["taskID"], "a voice memo belongs to no task")
        XCTAssertEqual(body["role"] as? String, "voice")
        XCTAssertEqual(body["mediaType"] as? String, "audio/mp4")
        XCTAssertEqual(body["size"] as? Int, m4a.count)
        XCTAssertEqual(body["checksum"] as? String, AttachmentRules.sha256Hex(m4a))
        XCTAssertEqual(seen[1].value(forHTTPHeaderField: "Authorization"), "Bearer cap-token")
        XCTAssertEqual(seen[1].httpBody, m4a)
    }

    func testVoiceUploadRejectsLocallyAndAbortsOnFailure() async {
        do { _ = try await client.uploadVoiceRecording(data: Data()); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .invalidInput(reason: "voice_too_large")) }
        do { _ = try await client.uploadVoiceRecording(data: Data(count: VoiceRules.maxBytes + 1)); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .invalidInput(reason: "voice_too_large")) }
        do { _ = try await client.uploadVoiceRecording(mediaType: "audio/mpeg", data: m4a); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .invalidInput(reason: "unsupported_audio_type")) }
        XCTAssertTrue(MockURLProtocol.seen.isEmpty)

        MockURLProtocol.handler = { r in
            switch r.httpMethod {
            case "POST": return (200, Data(self.capabilityJSON.utf8))
            case "PUT": return (422, Data(#"{"reason":"voice_too_long"}"#.utf8))
            default: return (204, Data())
            }
        }
        do { _ = try await client.uploadVoiceRecording(data: m4a); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .invalidInput(reason: "voice_too_long")) }
        XCTAssertEqual(MockURLProtocol.seen.map(\.httpMethod), ["POST", "PUT", "DELETE"])
    }

    func testDownloadVoiceFileWritesAndReuses() async throws {
        MockURLProtocol.handler = { _ in (200, self.m4a) }
        let dir = FileManager.default.temporaryDirectory.appending(path: "voice-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try await client.downloadVoiceFile(aid, into: dir)
        XCTAssertEqual(url.lastPathComponent, "\(aid.uuidString.lowercased()).m4a")
        XCTAssertEqual(try Data(contentsOf: url), m4a)
        _ = try await client.downloadVoiceFile(aid, into: dir)
        XCTAssertEqual(MockURLProtocol.seen.count, 1, "second call reuses the file")
    }

    // MARK: Consent

    func testConsentIsPerAccountAndServerAndRevocable() {
        let defaults = UserDefaults(suiteName: "voice-consent-\(UUID().uuidString)")!
        let store = UserDefaultsVoiceConsentStore(defaults: defaults)
        let alice = UUID(), bob = UUID()
        XCTAssertFalse(store.isGranted(account: alice, server: "https://a"))
        store.save(VoiceConsentRecord(version: VoiceConsent.currentVersion, acceptedAt: Date(timeIntervalSince1970: 1_800_000_000)), account: alice, server: "https://a")
        XCTAssertTrue(store.isGranted(account: alice, server: "https://a"))
        XCTAssertFalse(store.isGranted(account: bob, server: "https://a"), "another account asks again")
        XCTAssertFalse(store.isGranted(account: alice, server: "https://b"), "another server asks again")
        XCTAssertEqual(store.record(account: alice, server: "https://a")?.acceptedAt, Date(timeIntervalSince1970: 1_800_000_000))
        store.revoke(account: alice, server: "https://a")
        XCTAssertFalse(store.isGranted(account: alice, server: "https://a"))
    }

    func testOlderConsentVersionAsksAgain() {
        let defaults = UserDefaults(suiteName: "voice-consent-\(UUID().uuidString)")!
        let store = UserDefaultsVoiceConsentStore(defaults: defaults)
        let id = UUID()
        store.save(VoiceConsentRecord(version: VoiceConsent.currentVersion - 1, acceptedAt: Date()), account: id, server: "s")
        XCTAssertFalse(store.isGranted(account: id, server: "s"))
    }
}

extension JSONDecoder.DateDecodingStrategy {
    /// Server dates with fractional seconds (test helper; the client's own decoder accepts both forms).
    static let iso8601WithMillis = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let raw = try decoder.singleValueContainer().decode(String.self)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: raw) else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: raw)) }
        return date
    }
}
