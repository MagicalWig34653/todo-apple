import Foundation

/// Raw result of a platform passkey registration, in WebAuthn terms.
public struct PasskeyRegistrationResult: Sendable, Equatable {
    public let credentialID: Data
    public let clientDataJSON: Data
    public let attestationObject: Data

    public init(credentialID: Data, clientDataJSON: Data, attestationObject: Data) {
        self.credentialID = credentialID
        self.clientDataJSON = clientDataJSON
        self.attestationObject = attestationObject
    }
}

/// Raw result of a platform passkey assertion (login).
public struct PasskeyAssertionResult: Sendable, Equatable {
    public let credentialID: Data
    public let clientDataJSON: Data
    public let authenticatorData: Data
    public let signature: Data
    public let userHandle: Data?

    public init(credentialID: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data, userHandle: Data?) {
        self.credentialID = credentialID
        self.clientDataJSON = clientDataJSON
        self.authenticatorData = authenticatorData
        self.signature = signature
        self.userHandle = userHandle
    }
}

/// Platform seam for passkeys. TodoCore stays free of AuthenticationServices; the app targets provide an
/// `ASAuthorization`-based implementation. Implementations throw `APIError.passkeyFailed` on cancel or failure.
public protocol PasskeyAuthenticator: Sendable {
    func register(challenge: Data, relyingPartyID: String, userID: Data, userName: String) async throws -> PasskeyRegistrationResult
    func authenticate(challenge: Data, relyingPartyID: String) async throws -> PasskeyAssertionResult
}

/// Why a platform passkey ceremony failed, derived from `ASAuthorizationError` codes by the app target.
public struct PasskeyFailure: Error, Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// 1001: dismissed. Also what the system reports when no passkey for the domain exists and the user closes the sheet.
        case cancelled
        /// 1004 without a domain hint: typically no usable passkey / iCloud Keychain unavailable.
        case failed
        /// 1004 whose system text names the Associated Domains link between app and domain.
        case notAssociated
        /// 1002
        case invalidResponse
        /// 1003
        case notHandled
        /// 1005
        case notInteractive
        /// 1010: passkey creation not possible on this device (no iCloud Keychain / passcode).
        case notConfigured
        case unknown
    }

    public let kind: Kind
    public let code: Int
    public let detail: String

    public init(kind: Kind, code: Int, detail: String) {
        self.kind = kind
        self.code = code
        self.detail = detail
    }

    /// Pure mapping so it is testable without AuthenticationServices.
    public static func classify(code: Int, description: String) -> PasskeyFailure {
        let kind: Kind
        switch code {
        case 1001: kind = .cancelled
        case 1002: kind = .invalidResponse
        case 1003: kind = .notHandled
        case 1004:
            let text = description.lowercased()
            kind = ["association", "webcredentials", "associated", "verify"].contains { text.contains($0) } ? .notAssociated : .failed
        case 1005: kind = .notInteractive
        case 1010: kind = .notConfigured
        default: kind = .unknown
        }
        return PasskeyFailure(kind: kind, code: code, detail: description)
    }
}

// MARK: Server option shapes (WebAuthn JSON as produced by the backend)

struct RegisterBeginResponse: Decodable {
    struct Options: Decodable {
        struct User: Decodable { let id: String; let name: String; let displayName: String }
        struct RelyingParty: Decodable { let id: String; let name: String }
        let challenge: String
        let user: User
        let rp: RelyingParty
    }
    let challengeID: UUID
    let options: Options
}

struct LoginBeginResponse: Decodable {
    struct Options: Decodable {
        let challenge: String
        let rpId: String
    }
    let challengeID: UUID
    let options: Options
}

struct RegisterFinishBody: Encodable {
    struct Credential: Encodable {
        struct Response: Encodable { let clientDataJSON: String; let attestationObject: String }
        let id: String
        let rawId: String
        let type = "public-key"
        let response: Response
    }
    let challengeID: UUID
    let credential: Credential
    let passkeyName: String?
}

struct LoginFinishBody: Encodable {
    struct Credential: Encodable {
        struct Response: Encodable {
            let clientDataJSON: String
            let authenticatorData: String
            let signature: String
            let userHandle: String?
        }
        let id: String
        let rawId: String
        let type = "public-key"
        let response: Response
    }
    let challengeID: UUID
    let credential: Credential
}
