import Foundation

/// Deployment configuration with placeholders. No real domain exists yet.
enum AppConfig {
    /// Default server shown on the login screen; the user can change it (persisted in UserDefaults).
    static let defaultBaseURL = "http://127.0.0.1:28080"

    /// TODO(deployment): the relying party ID is dictated by the server (`rp.id` in the registration options and
    /// `rpId` in login options), so the app needs no copy of it. What the app does need is the matching
    /// Associated Domains entry `webcredentials:<RP-ID>` (see App/Config/Todo.entitlements.example) and an
    /// apple-app-site-association file on that domain. Both wait for the real domain.
    static let associatedDomainPlaceholder = "webcredentials:todo.example.invalid"

    private static let key = "serverBaseURL"
    static var savedBaseURL: String {
        get { UserDefaults.standard.string(forKey: key) ?? defaultBaseURL }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
