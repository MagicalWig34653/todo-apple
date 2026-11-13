import Foundation

// MARK: Consent for voice messages (ADR 0030, "Datenschutz")
//
// The server has no consent endpoint yet (ADR 0030 step 7); until it does, the consent is kept on the device, per
// server and account. It records the moment and the text version, so a changed text can ask again.

public struct VoiceConsentRecord: Codable, Sendable, Equatable {
    public let version: Int
    public let acceptedAt: Date
    public init(version: Int, acceptedAt: Date) { self.version = version; self.acceptedAt = acceptedAt }
}

public enum VoiceConsent {
    /// Version of the consent text shown by the app. Raise it when the text changes materially.
    public static let currentVersion = 1
}

public protocol VoiceConsentStore: Sendable {
    func record(account: UUID, server: String) -> VoiceConsentRecord?
    func save(_ record: VoiceConsentRecord, account: UUID, server: String)
    func revoke(account: UUID, server: String)
}

extension VoiceConsentStore {
    /// True when the account agreed to the current text version.
    public func isGranted(account: UUID, server: String) -> Bool {
        guard let record = record(account: account, server: server) else { return false }
        return record.version >= VoiceConsent.currentVersion
    }
}

public struct UserDefaultsVoiceConsentStore: VoiceConsentStore, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ account: UUID, _ server: String) -> String { "voiceConsent.\(server).\(account.uuidString.lowercased())" }

    public func record(account: UUID, server: String) -> VoiceConsentRecord? {
        guard let data = defaults.data(forKey: key(account, server)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VoiceConsentRecord.self, from: data)
    }

    public func save(_ record: VoiceConsentRecord, account: UUID, server: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record) { defaults.set(data, forKey: key(account, server)) }
    }

    public func revoke(account: UUID, server: String) { defaults.removeObject(forKey: key(account, server)) }
}
