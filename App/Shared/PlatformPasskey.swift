import AuthenticationServices
import TodoCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// `ASAuthorization`-based passkey implementation for iOS and macOS.
/// Not verified on a real device yet: needs a real domain with Associated Domains.
@MainActor
final class PlatformPasskey: NSObject, PasskeyAuthenticator, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    private var continuation: CheckedContinuation<ASAuthorization, any Error>?

    func register(challenge: Data, relyingPartyID: String, userID: Data, userName: String) async throws -> PasskeyRegistrationResult {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyID)
        let request = provider.createCredentialRegistrationRequest(challenge: challenge, name: userName, userID: userID)
        let auth = try await run([request])
        guard let cred = auth.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
            let attestation = cred.rawAttestationObject
        else { throw APIError.passkeyFailed("unexpected credential") }
        return .init(credentialID: cred.credentialID, clientDataJSON: cred.rawClientDataJSON, attestationObject: attestation)
    }

    func authenticate(challenge: Data, relyingPartyID: String) async throws -> PasskeyAssertionResult {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyID)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        let auth = try await run([request])
        guard let cred = auth.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion
        else { throw APIError.passkeyFailed("unexpected credential") }
        return .init(
            credentialID: cred.credentialID, clientDataJSON: cred.rawClientDataJSON,
            authenticatorData: cred.rawAuthenticatorData, signature: cred.signature, userHandle: cred.userID)
    }

    private func run(_ requests: [ASAuthorizationRequest]) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let controller = ASAuthorizationController(authorizationRequests: requests)
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated { continuation?.resume(returning: authorization); continuation = nil }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        MainActor.assumeIsolated {
            continuation?.resume(throwing: Self.failure(from: error)); continuation = nil
        }
    }

    /// Keeps the raw `ASAuthorizationError` code and system text so the UI can explain the actual cause.
    nonisolated static func failure(from error: any Error) -> APIError {
        let ns = error as NSError
        let text = ns.localizedDescription + (ns.localizedFailureReason.map { " " + $0 } ?? "")
        if ns.domain == ASAuthorizationError.errorDomain {
            return .passkey(PasskeyFailure.classify(code: ns.code, description: text))
        }
        return .passkey(PasskeyFailure(kind: .unknown, code: ns.code, detail: "\(ns.domain): \(text)"))
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
            #else
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}
