import XCTest

@testable import TodoCore

/// Opt-in end-to-end run of the recovery flow against a real backend with a fresh database:
/// `TEST_RUNNER_TODO_LIVE_BASE_URL=http://127.0.0.1:28951 xcodebuild test -scheme TodoCore -destination platform=macOS -only-testing:TodoCoreTests/LiveRecoveryTests`
/// Reuses `VirtualPasskey` from `LiveEtappe2Tests`; needs the dev bootstrap token to still be open.
final class LiveRecoveryTests: XCTestCase {
    private struct Empty: Encodable {}

    func testRecoveryAddsNewPasskeyToExistingAccount() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["TODO_LIVE_BASE_URL"], let url = URL(string: raw) else { throw XCTSkip("TODO_LIVE_BASE_URL not set") }
        let origin = env["TODO_LIVE_RP_ORIGIN"] ?? "http://localhost:25173"
        let token = env["TODO_LIVE_BOOTSTRAP_TOKEN"] ?? "dev-bootstrap-only"

        // The account as created in the PWA (passkey #1 lives in another password manager).
        let browserKey = VirtualPasskey(origin: origin)
        let browser = APIClient(baseURL: url)
        guard try await browser.capabilities().bootstrapOpen else { throw XCTSkip("bootstrap already used; use a fresh database") }
        let account = try await browser.registerWithPasskey(token: token, displayName: "Recover \(UUID().uuidString.prefix(6))", authenticator: browserKey)
        XCTAssertTrue(account.isAdmin)

        // PWA: Konto > "Recovery-Code ausstellen" with the own account ID.
        let issued: RecoveryToken = try await browser.send("POST", "v1/identity/accounts/\(account.id.uuidString)/recovery", body: Empty())
        XCTAssertGreaterThan(issued.expiresAt, Date())

        // Wrong code is rejected.
        do { _ = try await APIClient(baseURL: url).redeemRecovery(code: "definitely-wrong"); XCTFail("wrong code accepted") }
        catch let e as APIError { print("wrong code ->", e) }

        // Native app: new device key (iCloud Keychain stand-in), redeem + register + sign in.
        let appKey = VirtualPasskey(origin: origin)
        let appStore = InMemoryTokenStore()
        let app = APIClient(baseURL: url, tokenStore: appStore)
        let recovered = try await app.recoverAccount(code: issued.token, passkeyName: "iPhone", authenticator: appKey)
        XCTAssertEqual(recovered.id, account.id)
        let meID = try await app.me().id
        XCTAssertEqual(meID, account.id)
        XCTAssertNotNil(try appStore.load())

        // Code is spent.
        do { _ = try await APIClient(baseURL: url).redeemRecovery(code: issued.token); XCTFail("code reusable") }
        catch let e as APIError { print("reused code ->", e) }

        // Recovery revoked the old normal session (ADR 0010) but kept the old passkey.
        do { _ = try await browser.me(); XCTFail("old session survived recovery") }
        catch APIError.unauthorized {}
        let again = try await APIClient(baseURL: url).loginWithPasskey(authenticator: browserKey)
        XCTAssertEqual(again.id, account.id)
        let again2 = try await APIClient(baseURL: url).loginWithPasskey(authenticator: appKey)
        XCTAssertEqual(again2.id, account.id)
    }
}
