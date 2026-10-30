import Foundation

private struct RedeemBody: Encodable { let code: String }

/// Result of `POST /v1/identity/recovery/redeem` (`contracts/identity.yaml`): a restricted bearer, valid for minutes.
public struct RecoveryToken: Decodable, Sendable, Equatable {
    public let token: String
    public let expiresAt: Date
}

private struct RecoveryFinishBody: Encodable {
    let challengeID: UUID
    let credential: RegisterFinishBody.Credential
    let passkeyName: String?
}

extension APIClient {
    /// Exchanges a one-time recovery code (issued by an admin) for a restricted recovery bearer. The code is spent
    /// by this call; the bearer allows only the two recovery passkey routes. Keep it in memory only.
    public func redeemRecovery(code: String) async throws -> RecoveryToken {
        try await send(
            "POST", "v1/identity/recovery/redeem", body: RedeemBody(code: code.trimmingCharacters(in: .whitespacesAndNewlines)),
            auth: false)
    }

    /// Registers a new passkey for the recovered account. Success revokes all normal sessions of the account on the
    /// server; the caller then signs in with `loginWithPasskey`. The bearer stays valid for retries until it expires.
    public func registerRecoveryPasskey(
        bearer: String, passkeyName: String? = nil, authenticator: any PasskeyAuthenticator
    ) async throws {
        let auth = ["Authorization": "Bearer \(bearer)"]
        let begin: RegisterBeginResponse = try await send(
            "POST", "v1/identity/recovery/passkeys/begin", auth: false, headers: auth)
        guard let challenge = Data(base64URLEncoded: begin.options.challenge),
            let userID = Data(base64URLEncoded: begin.options.user.id)
        else { throw APIError.decoding("invalid registration options") }
        let result = try await authenticator.register(
            challenge: challenge, relyingPartyID: begin.options.rp.id, userID: userID, userName: begin.options.user.name)
        let id = result.credentialID.base64URLEncoded
        let body = RecoveryFinishBody(
            challengeID: begin.challengeID,
            credential: .init(
                id: id, rawId: id,
                response: .init(
                    clientDataJSON: result.clientDataJSON.base64URLEncoded,
                    attestationObject: result.attestationObject.base64URLEncoded)),
            passkeyName: passkeyName)
        let request = try makeRequest("POST", "v1/identity/recovery/passkeys/finish", query: [], body: body, auth: false, headers: auth)
        _ = try await performWithStatus(request)
    }

    /// Whole flow for non-interactive callers (tests): redeem, register, then sign in with the new passkey.
    public func recoverAccount(code: String, passkeyName: String? = nil, authenticator: any PasskeyAuthenticator) async throws -> User {
        let token = try await redeemRecovery(code: code)
        try await registerRecoveryPasskey(bearer: token.token, passkeyName: passkeyName, authenticator: authenticator)
        return try await loginWithPasskey(authenticator: authenticator)
    }
}
