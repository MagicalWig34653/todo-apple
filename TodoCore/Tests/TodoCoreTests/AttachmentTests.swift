import XCTest
@testable import TodoCore

final class AttachmentTests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let tid = UUID(), aid = UUID()
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])

    override func setUp() {
        MockURLProtocol.seen = []
        MockURLProtocol.handler = nil
        try? store.save("tok")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: URL(string: "http://test.invalid")!, session: URLSession(configuration: config), tokenStore: store)
    }

    private var attachmentJSON: String {
        #"{"id":"\#(aid)","taskID":"\#(tid)","filename":"a.png","role":"reference","mediaType":"image/png","size":12,"checksum":"\#(AttachmentRules.sha256Hex(png))","status":"complete"}"#
    }
    private var capabilityJSON: String {
        #"{"attachmentID":"\#(aid)","uploadURL":"/v1/attachments/\#(aid)/upload","token":"cap-token","expiresAt":"2026-10-27T10:15:00Z"}"#
    }
    private func json(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    func testRulesSniffAndHash() {
        XCTAssertEqual(AttachmentRules.sniffMediaType(png), "image/png")
        XCTAssertEqual(AttachmentRules.sniffMediaType(Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(AttachmentRules.sniffMediaType(Data("%PDF-1.7".utf8)), "application/pdf")
        XCTAssertEqual(AttachmentRules.sniffMediaType(Data("RIFF\0\0\0\0WEBP".utf8)), "image/webp")
        XCTAssertNil(AttachmentRules.sniffMediaType(Data("hello".utf8)))
        XCTAssertEqual(AttachmentRules.mediaType(forPathExtension: "JPG"), "image/jpeg")
        XCTAssertNil(AttachmentRules.mediaType(forPathExtension: "heic"))
        XCTAssertEqual(AttachmentRules.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testUploadFlowBeginPutComplete() async throws {
        MockURLProtocol.handler = { r in
            switch (r.httpMethod, r.url?.path) {
            case ("POST", "/v1/attachments/begin"): return (200, Data(self.capabilityJSON.utf8))
            case ("PUT", _): return (204, Data())
            default: return (200, Data(self.attachmentJSON.utf8))
            }
        }
        let result = try await client.uploadAttachment(taskID: tid, filename: "a.png", mediaType: "image/png", data: png)
        XCTAssertEqual(result.id, aid)
        let seen = MockURLProtocol.seen
        XCTAssertEqual(seen.count, 3)
        let begin = seen[0]
        XCTAssertEqual(begin.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let body = json(begin)
        XCTAssertEqual(body["taskID"] as? String, tid.uuidString)
        XCTAssertEqual(body["filename"] as? String, "a.png")
        XCTAssertEqual(body["role"] as? String, "reference")
        XCTAssertEqual(body["mediaType"] as? String, "image/png")
        XCTAssertEqual(body["size"] as? Int, 12)
        XCTAssertEqual(body["checksum"] as? String, AttachmentRules.sha256Hex(png))
        let put = seen[1]
        XCTAssertEqual(put.url?.path, "/v1/attachments/\(aid)/upload")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Authorization"), "Bearer cap-token")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(put.httpBody, png)
        XCTAssertEqual(seen[2].httpMethod, "POST")
        XCTAssertEqual(seen[2].url?.path, "/v1/attachments/\(aid)/complete")
        XCTAssertEqual(seen[2].value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testUploadRejectsLocallyBeforeAnyRequest() async {
        do { _ = try await client.uploadAttachment(taskID: tid, filename: "a.txt", mediaType: "text/plain", data: png); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .invalidInput(reason: "invalid_media_type")) }
        do { _ = try await client.uploadAttachment(taskID: tid, filename: "a.png", mediaType: "image/png", data: Data()); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .invalidInput(reason: "invalid_size")) }
        XCTAssertTrue(MockURLProtocol.seen.isEmpty)
    }

    func testPutFailureAbortsPendingUpload() async {
        MockURLProtocol.handler = { r in
            switch r.httpMethod {
            case "POST": return (200, Data(self.capabilityJSON.utf8))
            case "PUT": return (422, Data(#"{"reason":"checksum_mismatch"}"#.utf8))
            default: return (204, Data())
            }
        }
        do { _ = try await client.uploadAttachment(taskID: tid, filename: "a.png", mediaType: "image/png", data: png); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .invalidInput(reason: "checksum_mismatch")) }
        XCTAssertEqual(MockURLProtocol.seen.map(\.httpMethod), ["POST", "PUT", "DELETE"])
        XCTAssertEqual(MockURLProtocol.seen.last?.url?.path, "/v1/attachments/\(aid)")
    }

    func testPut502IsRetriedOnce() async throws {
        var puts = 0
        MockURLProtocol.handler = { r in
            switch r.httpMethod {
            case "POST" where r.url?.path.hasSuffix("begin") == true: return (200, Data(self.capabilityJSON.utf8))
            case "PUT": puts += 1; return puts == 1 ? (502, Data()) : (204, Data())
            default: return (200, Data(self.attachmentJSON.utf8))
            }
        }
        _ = try await client.uploadAttachment(taskID: tid, filename: "a.png", mediaType: "image/png", data: png)
        XCTAssertEqual(puts, 2)
    }

    func testForeignUploadURLIsRefusedAndTokenNotSent() async {
        let cap = try! JSONDecoder.iso.decode(AttachmentUploadCapability.self, from: Data(
            #"{"attachmentID":"\#(aid)","uploadURL":"https://evil.invalid/x","token":"cap-token","expiresAt":"2026-10-27T10:15:00Z"}"#.utf8))
        do { try await client.putAttachmentData(png, capability: cap); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .invalidResponse) }
        XCTAssertTrue(MockURLProtocol.seen.isEmpty)
    }

    func testDownloadAndPreviewAreRawAuthenticatedGets() async throws {
        MockURLProtocol.handler = { _ in (200, self.png) }
        let d = try await client.downloadAttachment(aid)
        XCTAssertEqual(d, png)
        XCTAssertEqual(MockURLProtocol.seen.last?.url?.path, "/v1/attachments/\(aid)/download")
        XCTAssertEqual(MockURLProtocol.seen.last?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        _ = try await client.previewAttachment(aid)
        XCTAssertEqual(MockURLProtocol.seen.last?.url?.path, "/v1/attachments/\(aid)/preview")
    }

    func testPreviewOfPdfMapsTo415() async {
        MockURLProtocol.handler = { _ in (415, Data()) }
        do { _ = try await client.previewAttachment(aid); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .server(status: 415, reason: nil)) }
    }

    func testDownloadFileVerifiesChecksumAndSanitizesName() async throws {
        let att = try JSONDecoder.iso.decode(TaskAttachment.self, from: Data(attachmentJSON.utf8))
        let dir = FileManager.default.temporaryDirectory.appending(path: "att-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        MockURLProtocol.handler = { _ in (200, self.png) }
        let url = try await client.downloadAttachmentFile(att, into: dir)
        XCTAssertEqual(url.lastPathComponent, "a.png")
        XCTAssertEqual(try Data(contentsOf: url), png)
        MockURLProtocol.handler = { _ in (200, Data([9, 9, 9])) }
        do { _ = try await client.downloadAttachmentFile(att, into: dir); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .decoding("attachment checksum mismatch")) }
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
