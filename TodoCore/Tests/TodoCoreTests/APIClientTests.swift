import XCTest
@testable import TodoCore

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var req = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            stream.close()
            req.httpBody = data
        }
        Self.seen.append(req)
        let (status, body) = Self.handler?(req) ?? (500, Data())
        let response = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct FakePasskey: PasskeyAuthenticator {
    func register(challenge: Data, relyingPartyID: String, userID: Data, userName: String) async throws -> PasskeyRegistrationResult {
        XCTAssertEqual(challenge, Data([1, 2, 3, 250]))
        XCTAssertEqual(relyingPartyID, "rp.test")
        return .init(credentialID: Data([9, 9]), clientDataJSON: Data("cd".utf8), attestationObject: Data("ao".utf8))
    }
    func authenticate(challenge: Data, relyingPartyID: String) async throws -> PasskeyAssertionResult {
        .init(credentialID: Data([9, 9]), clientDataJSON: Data("cd".utf8), authenticatorData: Data("ad".utf8),
              signature: Data("sg".utf8), userHandle: nil)
    }
}

final class APIClientTests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let pid = UUID()

    override func setUp() {
        MockURLProtocol.seen = []
        MockURLProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: URL(string: "http://test.invalid")!, session: URLSession(configuration: config), tokenStore: store)
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }
    private func body(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
    }
    private let userJSON = #"{"id":"00000000-0000-0000-0000-000000000001","displayName":"A","isAdmin":true}"#

    func testPasskeyRegistrationSendsWebAuthnShapeAndStoresToken() async throws {
        let cid = UUID()
        MockURLProtocol.handler = { req in
            if req.url!.path.hasSuffix("register/begin") {
                return (200, self.json(#"{"challengeID":"\#(cid)","options":{"challenge":"AQID-g","rp":{"id":"rp.test","name":"T"},"user":{"id":"AQ","name":"A","displayName":"A"},"pubKeyCredParams":[],"attestation":"none"}}"#))
            }
            return (200, self.json(#"{"token":"tok","expiresAt":"2026-11-01T10:00:00Z","user":\#(self.userJSON)}"#))
        }
        let user = try await client.registerWithPasskey(token: "boot", displayName: "A", passkeyName: "Mac", authenticator: FakePasskey())
        XCTAssertTrue(user.isAdmin)
        XCTAssertEqual(try store.load(), "tok")
        let begin = MockURLProtocol.seen[0]
        XCTAssertEqual(body(begin)["token"] as? String, "boot")
        XCTAssertNil(begin.value(forHTTPHeaderField: "Authorization"))
        let finish = body(MockURLProtocol.seen[1])
        XCTAssertEqual(finish["challengeID"] as? String, cid.uuidString)
        XCTAssertEqual(finish["passkeyName"] as? String, "Mac")
        let cred = finish["credential"] as! [String: Any]
        XCTAssertEqual(cred["type"] as? String, "public-key")
        XCTAssertEqual(cred["rawId"] as? String, "CQk")
        XCTAssertEqual((cred["response"] as! [String: Any])["attestationObject"] as? String, Data("ao".utf8).base64URLEncoded)
    }

    func testPasskeyLoginOmitsMissingUserHandle() async throws {
        let cid = UUID()
        MockURLProtocol.handler = { req in
            if req.url!.path.hasSuffix("login/begin") {
                return (200, self.json(#"{"challengeID":"\#(cid)","options":{"challenge":"AQID-g","rpId":"rp.test"}}"#))
            }
            return (200, self.json(#"{"token":"t2","expiresAt":"2026-11-01T10:00:00.123Z","user":\#(self.userJSON)}"#))
        }
        _ = try await client.loginWithPasskey(authenticator: FakePasskey())
        let resp = (body(MockURLProtocol.seen[1])["credential"] as! [String: Any])["response"] as! [String: Any]
        XCTAssertNil(resp["userHandle"])
        XCTAssertEqual(resp["signature"] as? String, Data("sg".utf8).base64URLEncoded)
        XCTAssertEqual(try store.load(), "t2")
    }

    func testPasswordLoginNotAttemptedWhenServerDisallows() async throws {
        MockURLProtocol.handler = { _ in (200, self.json(#"{"passkey":true,"password":false,"bootstrapOpen":false}"#)) }
        do { _ = try await client.passwordLogin(username: "u", password: "p"); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .passwordLoginDisabled) }
        XCTAssertEqual(MockURLProtocol.seen.count, 1)
    }

    func testAuthorizedRequestsCarryBearerAndQuery() async throws {
        try store.save("abc")
        MockURLProtocol.handler = { _ in (200, self.json("[]")) }
        _ = try await client.tasks(projectID: pid)
        let req = MockURLProtocol.seen[0]
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertEqual(req.url?.query, "projectID=\(pid.uuidString)")
    }

    func testUpdateTaskSendsVersionAndOnlyChangedFields() async throws {
        MockURLProtocol.handler = { _ in (200, self.json(#"{"id":"\#(UUID())","projectID":"\#(self.pid)","title":"t","description":"","status":"done","version":4}"#)) }
        let t = try await client.updateTask(UUID(), version: 3, TaskUpdate(status: .done))
        XCTAssertTrue(t.isDone)
        let b = body(MockURLProtocol.seen[0])
        XCTAssertEqual(MockURLProtocol.seen[0].httpMethod, "PATCH")
        XCTAssertEqual(b["version"] as? Int, 3)
        XCTAssertEqual(b["status"] as? String, "done")
        XCTAssertNil(b["title"])
    }

    func testErrorMapping() async throws {
        let cases: [(Int, String, APIError)] = [
            (409, "version_conflict", .versionConflict),
            (409, "username_taken", .conflict(reason: "username_taken")),
            (401, "login_failed", .unauthorized(reason: "login_failed")),
            (403, "invalid_token", .forbidden(reason: "invalid_token")),
            (404, "Not Found", .notFound),
            (422, "project_cycle", .invalidInput(reason: "project_cycle")),
            (500, "x", .server(status: 500, reason: "x")),
        ]
        for (status, reason, expected) in cases {
            MockURLProtocol.handler = { _ in (status, self.json(#"{"error":true,"reason":"\#(reason)"}"#)) }
            do { _ = try await client.projects(); XCTFail() } catch { XCTAssertEqual(error as? APIError, expected) }
        }
    }

    func testLogoutClearsTokenEvenWhenSessionAlreadyInvalid() async throws {
        try store.save("abc")
        MockURLProtocol.handler = { _ in (401, Data()) }
        try await client.logout()
        XCTAssertNil(try store.load())
    }

    func testMovingProjectToRootUsesMoveToRoot() async throws {
        MockURLProtocol.handler = { _ in (200, self.json(#"{"id":"\#(UUID())","name":"p","version":2}"#)) }
        _ = try await client.updateProject(UUID(), version: 1, ProjectUpdate(moveToRoot: true))
        let b = body(MockURLProtocol.seen[0])
        XCTAssertEqual(b["moveToRoot"] as? Bool, true)
        XCTAssertNil(b["parentID"])
    }

    func testProjectTreeNestsAndHandlesOrphansAndCycles() {
        let a = Project(id: UUID(), parentID: nil, name: "a", version: 1)
        let b = Project(id: UUID(), parentID: a.id, name: "b", version: 1)
        let c = Project(id: UUID(), parentID: b.id, name: "c", version: 1)
        let orphan = Project(id: UUID(), parentID: UUID(), name: "o", version: 1)
        let tree = ProjectTree.build([a, b, c, orphan])
        XCTAssertEqual(tree.map(\.project.name), ["a", "o"])
        XCTAssertEqual(tree[0].children?[0].children?[0].project.name, "c")
        XCTAssertNil(tree[1].children)
    }
}

/// Opt-in run against a real local backend: `TODO_LIVE_BASE_URL=http://127.0.0.1:28080`.
final class LiveBackendTests: XCTestCase {
    func testCapabilitiesAndUnauthenticatedAccess() async throws {
        guard let raw = ProcessInfo.processInfo.environment["TODO_LIVE_BASE_URL"], let url = URL(string: raw) else {
            throw XCTSkip("TODO_LIVE_BASE_URL not set")
        }
        let client = APIClient(baseURL: url)
        let caps = try await client.capabilities()
        XCTAssertTrue(caps.passkey)
        _ = try await client.ready()
        do { _ = try await client.me(); XCTFail() } catch { XCTAssertEqual(error as? APIError, .unauthorized(reason: "Unauthorized")) }
        do { _ = try await client.projects(); XCTFail() } catch { XCTAssertEqual(error as? APIError, .unauthorized(reason: "Unauthorized")) }
        if !caps.password {
            do { _ = try await client.passwordLogin(username: "x", password: "y"); XCTFail() }
            catch { XCTAssertEqual(error as? APIError, .passwordLoginDisabled) }
        } else {
            do { _ = try await client.passwordLogin(username: "nobody-xyz", password: "wrong"); XCTFail() }
            catch { XCTAssertEqual(error as? APIError, .unauthorized(reason: "login_failed")) }
        }
    }
}
