import Foundation

/// Wraps a passkey authenticator and retries a ceremony exactly once, silently, when the system reports
/// 1004 with the Associated Domains hint (`PasskeyFailure.Kind.notAssociated`). Right after an install,
/// swcd has often not confirmed the AASA yet and the system itself says "try again in a few seconds".
/// Every other failure, including cancel (1001), is passed through immediately without a retry.
public struct RetryingPasskey: PasskeyAuthenticator {
    public static let defaultDelay: Duration = .seconds(3)

    private let inner: any PasskeyAuthenticator
    private let delay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        _ inner: any PasskeyAuthenticator,
        delay: Duration = RetryingPasskey.defaultDelay,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.inner = inner
        self.delay = delay
        self.sleep = sleep
    }

    public func register(challenge: Data, relyingPartyID: String, userID: Data, userName: String) async throws -> PasskeyRegistrationResult {
        try await retryingOnce {
            try await inner.register(challenge: challenge, relyingPartyID: relyingPartyID, userID: userID, userName: userName)
        }
    }

    public func authenticate(challenge: Data, relyingPartyID: String) async throws -> PasskeyAssertionResult {
        try await retryingOnce { try await inner.authenticate(challenge: challenge, relyingPartyID: relyingPartyID) }
    }

    private func retryingOnce<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as APIError {
            guard case .passkey(let failure) = error, failure.kind == .notAssociated else { throw error }
            try await sleep(delay)
            return try await operation()
        }
    }
}
