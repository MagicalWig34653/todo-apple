import XCTest
@testable import TodoCore

/// Scripted authenticator: pops one outcome per call and counts calls.
private final class ScriptedPasskey: PasskeyAuthenticator, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Result<Void, any Error>]
    private(set) var calls = 0

    init(_ outcomes: [Result<Void, any Error>]) { self.outcomes = outcomes }

    private func next() throws {
        lock.lock(); calls += 1
        let outcome = outcomes.isEmpty ? .success(()) : outcomes.removeFirst()
        lock.unlock()
        try outcome.get()
    }

    func register(challenge: Data, relyingPartyID: String, userID: Data, userName: String) async throws -> PasskeyRegistrationResult {
        try next()
        return .init(credentialID: Data([1]), clientDataJSON: Data([2]), attestationObject: Data([3]))
    }

    func authenticate(challenge: Data, relyingPartyID: String) async throws -> PasskeyAssertionResult {
        try next()
        return .init(credentialID: Data([1]), clientDataJSON: Data([2]), authenticatorData: Data([3]), signature: Data([4]), userHandle: nil)
    }
}

private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    var delays: [Duration] { lock.withLock { recorded } }
    private func record(_ d: Duration) { lock.withLock { recorded.append(d) } }
    func sleep(_ d: Duration) async throws { record(d) }
}

final class PasskeyRetryTests: XCTestCase {
    static let swcdText = "Unable to verify webcredentials association of J2DU2P47XW.de.linolaske.todo with domain todo.linolaske.de. Please try again in a few seconds."

    private func failure(_ code: Int, _ text: String = "") -> Result<Void, any Error> {
        .failure(APIError.passkey(PasskeyFailure.classify(code: code, description: text)))
    }

    private func wrap(_ inner: ScriptedPasskey, _ rec: SleepRecorder) -> RetryingPasskey {
        RetryingPasskey(inner, sleep: { try await rec.sleep($0) })
    }

    func testNotAssociatedRetriesOnceAfterThreeSecondsAndSucceeds() async throws {
        let inner = ScriptedPasskey([failure(1004, Self.swcdText)])
        let rec = SleepRecorder()
        _ = try await wrap(inner, rec).authenticate(challenge: Data(), relyingPartyID: "d")
        XCTAssertEqual(inner.calls, 2)
        XCTAssertEqual(rec.delays, [.seconds(3)])
    }

    func testNotAssociatedTwiceSurfacesTheErrorAfterExactlyOneRetry() async {
        let inner = ScriptedPasskey([failure(1004, Self.swcdText), failure(1004, Self.swcdText)])
        let rec = SleepRecorder()
        do { _ = try await wrap(inner, rec).authenticate(challenge: Data(), relyingPartyID: "d"); XCTFail("expected throw") }
        catch { XCTAssertEqual((error as? APIError), .passkey(.classify(code: 1004, description: Self.swcdText))) }
        XCTAssertEqual(inner.calls, 2)
        XCTAssertEqual(rec.delays.count, 1)
    }

    func testRegistrationAlsoRetriesOnce() async throws {
        let inner = ScriptedPasskey([failure(1004, Self.swcdText)])
        let rec = SleepRecorder()
        _ = try await wrap(inner, rec).register(challenge: Data(), relyingPartyID: "d", userID: Data(), userName: "u")
        XCTAssertEqual(inner.calls, 2)
    }

    func testOtherFailuresAndCancelNeverRetry() async {
        let cases: [(String, Result<Void, any Error>)] = [
            ("cancel 1001", failure(1001)),
            ("1004 without domain hint", failure(1004, "The operation couldn’t be completed.")),
            ("1010", failure(1010)),
            ("1003", failure(1003)),
            ("unknown", failure(1000)),
            ("non-passkey error", .failure(APIError.passkeyFailed("unexpected credential"))),
            ("task cancelled", .failure(CancellationError())),
        ]
        for (label, outcome) in cases {
            let inner = ScriptedPasskey([outcome])
            let rec = SleepRecorder()
            do { _ = try await wrap(inner, rec).authenticate(challenge: Data(), relyingPartyID: "d"); XCTFail("\(label): expected throw") }
            catch {}
            XCTAssertEqual(inner.calls, 1, label)
            XCTAssertTrue(rec.delays.isEmpty, label)
        }
    }

    func testSuccessDoesNotSleepOrRetry() async throws {
        let inner = ScriptedPasskey([])
        let rec = SleepRecorder()
        _ = try await wrap(inner, rec).authenticate(challenge: Data(), relyingPartyID: "d")
        XCTAssertEqual(inner.calls, 1)
        XCTAssertTrue(rec.delays.isEmpty)
    }
}
