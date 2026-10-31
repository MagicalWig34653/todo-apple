import Foundation

/// Errors surfaced by `APIClient`. `reason` carries the server's machine-readable code when present
/// (for example `invalid_token`, `login_failed`, `password_login_disabled`).
public enum APIError: Error, Equatable, Sendable {
    /// 401: missing, expired or revoked session, or failed login.
    case unauthorized(reason: String?)
    /// 403: for example an invalid bootstrap/invitation token or disabled password login.
    case forbidden(reason: String?)
    /// 404: missing or foreign object (the server does not distinguish).
    case notFound
    /// 409 `version_conflict`: the object changed since the caller read it. Reload and retry.
    case versionConflict
    /// Other 409 (for example `username_taken`, `bootstrap_closed`).
    case conflict(reason: String?)
    /// 410 `cursor_expired`: the feed cursor is below the server's retention floor (ADR 0019). The client drops its
    /// confirmed cache for the account and reloads from `c0`; `c0` itself and cursors at or above the floor stay valid.
    case cursorExpired
    /// 400/422: rejected input (for example `invalid_name`, `project_cycle`).
    case invalidInput(reason: String?)
    /// Any other non-2xx status.
    case server(status: Int, reason: String?)
    /// Password login was not attempted because the server does not offer it.
    case passwordLoginDisabled
    /// The passkey ceremony was cancelled or failed on the device.
    case passkeyFailed(String)
    /// Classified platform passkey failure (`code` is the raw `ASAuthorizationError` code, `detail` the system text).
    case passkey(PasskeyFailure)
    /// Network or transport failure (offline, TLS, timeout).
    case transport(String)
    /// The response could not be decoded.
    case decoding(String)
    case invalidResponse

    /// Maps a failed HTTP response to an error.
    static func from(status: Int, reason: String?) -> APIError {
        switch status {
        case 401: return .unauthorized(reason: reason)
        case 403: return reason == "password_login_disabled" ? .passwordLoginDisabled : .forbidden(reason: reason)
        case 404: return .notFound
        case 409: return reason == "version_conflict" ? .versionConflict : .conflict(reason: reason)
        case 410 where reason == "cursor_expired": return .cursorExpired
        case 400, 422: return .invalidInput(reason: reason)
        default: return .server(status: status, reason: reason)
        }
    }
}
