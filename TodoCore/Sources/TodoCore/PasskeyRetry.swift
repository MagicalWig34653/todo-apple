import Foundation

/// Stub (red phase): passes everything through without retrying.
public struct RetryingPasskey: PasskeyAuthenticator {
    let inner: any PasskeyAuthenticator
    let sleep: @Sendable (Duration) async throws -> Void

    public init(_ inner: any PasskeyAuthenticator, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.inner = inner
        self.sleep = sleep
    }

    public func register(challenge: Data, relyingPartyID: String, userID: Data, userName: String) async throws -> PasskeyRegistrationResult {
        try await inner.register(challenge: challenge, relyingPartyID: relyingPartyID, userID: userID, userName: userName)
    }

    public func authenticate(challenge: Data, relyingPartyID: String) async throws -> PasskeyAssertionResult {
        try await inner.authenticate(challenge: challenge, relyingPartyID: relyingPartyID)
    }
}
