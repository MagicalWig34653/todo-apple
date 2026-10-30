import XCTest

@testable import TodoCore

final class RecoveryTests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let userJSON = #"{"id":"00000000-0000-0000-0000-000000000001","displayName":"A","isAdmin":true}"#

    override func setUp() {
        MockURLProtocol.seen = []
        MockURLProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: URL(string: "http://test.invalid")!, session: URLSession(configuration: config), tokenStore: store)
    }

    private func body(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    func testRecoveryFlowRedeemsRegistersAndSignsIn() async throws {
        let cid = UUID()
        let lcid = UUID()
        MockURLProtocol.handler = { req in
            let path = req.url!.path
            if path.hasSuffix("recovery/redeem") { return (200, Data(#"{"token":"rec-bearer","expiresAt":"2026-11-01T10:05:00Z"}"#.utf8)) }
            if path.hasSuffix("recovery/passkeys/begin") {
                return (200, Data(#"{"challengeID":"\#(cid)","options":{"challenge":"AQID-g","rp":{"id":"rp.test","name":"T"},"user":{"id":"AQ","name":"A","displayName":"A"}}}"#.utf8))
            }
            if path.hasSuffix("recovery/passkeys/finish") { return (204, Data()) }
            if path.hasSuffix("login/begin") { return (200, Data(#"{"challengeID":"\#(lcid)","options":{"challenge":"AQID-g","rpId":"rp.test"}}"#.utf8)) }
            return (200, Data(#"{"token":"normal","expiresAt":"2026-11-01T10:00:00Z","user":\#(self.userJSON)}"#.utf8))
        }
        let user = try await client.recoverAccount(code: "  CODE123\n", passkeyName: "iPhone", authenticator: FakePasskey())
        XCTAssertTrue(user.isAdmin)
        XCTAssertEqual(try store.load(), "normal")
        let seen = MockURLProtocol.seen
        XCTAssertEqual(seen.map { $0.url!.path }, [
            "/v1/identity/recovery/redeem", "/v1/identity/recovery/passkeys/begin",
            "/v1/identity/recovery/passkeys/finish", "/v1/auth/login/begin", "/v1/auth/login/finish",
        ])
        XCTAssertEqual(body(seen[0])["code"] as? String, "CODE123")
        XCTAssertNil(seen[0].value(forHTTPHeaderField: "Authorization"))
        // Recovery routes carry the restricted bearer only; nothing else is sent with it.
        XCTAssertEqual(seen[1].value(forHTTPHeaderField: "Authorization"), "Bearer rec-bearer")
        XCTAssertEqual(seen[2].value(forHTTPHeaderField: "Authorization"), "Bearer rec-bearer")
        XCTAssertNil(seen[3].value(forHTTPHeaderField: "Authorization"))
        let finish = body(seen[2])
        XCTAssertEqual(finish["challengeID"] as? String, cid.uuidString)
        XCTAssertEqual(finish["passkeyName"] as? String, "iPhone")
        XCTAssertEqual((finish["credential"] as! [String: Any])["type"] as? String, "public-key")
    }

    func testRedeemRejectionIsSurfaced() async {
        MockURLProtocol.handler = { _ in (401, Data(#"{"reason":"invalid_recovery"}"#.utf8)) }
        do { _ = try await client.redeemRecovery(code: "x"); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .unauthorized(reason: "invalid_recovery")) }
        XCTAssertNil(try? store.load())
    }

    func testPasskeyFailureClassification() {
        XCTAssertEqual(PasskeyFailure.classify(code: 1001, description: "x").kind, .cancelled)
        XCTAssertEqual(PasskeyFailure.classify(code: 1004, description: "The operation couldn’t be completed.").kind, .failed)
        XCTAssertEqual(
            PasskeyFailure.classify(code: 1004, description: "Application with identifier A is not associated with domain d").kind,
            .notAssociated)
        let real = "Unable to verify webcredentials association of J2DU2P47XW.de.linolaske.todo with domain todo.linolaske.de. Please try again in a few seconds."
        XCTAssertEqual(PasskeyFailure.classify(code: 1004, description: real).kind, .notAssociated)
        XCTAssertEqual(PasskeyFailure.classify(code: 1004, description: real).detail, real)
        XCTAssertEqual(PasskeyFailure.classify(code: 1003, description: "").kind, .notHandled)
        XCTAssertEqual(PasskeyFailure.classify(code: 1005, description: "").kind, .notInteractive)
        XCTAssertEqual(PasskeyFailure.classify(code: 1002, description: "").kind, .invalidResponse)
        XCTAssertEqual(PasskeyFailure.classify(code: 1010, description: "").kind, .notConfigured)
        XCTAssertEqual(PasskeyFailure.classify(code: 1000, description: "").kind, .unknown)
        XCTAssertEqual(PasskeyFailure.classify(code: 1004, description: "d").code, 1004)
    }
}
