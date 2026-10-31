import Foundation
import Security

/// Storage for the device token. The token is never written to config.json, logs or prompts.
public protocol SecretStore: Sendable {
    func read(account: String) throws -> String?
    func write(_ secret: String, account: String) throws
    func delete(account: String) throws
}

public enum SecretStoreError: Error, Equatable { case keychain(Int32) }

/// macOS Keychain (generic password, this device only, available after first unlock so a
/// launchd agent can read it while the screen is locked).
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public init(service: String = "de.todo.runner") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read(account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw SecretStoreError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError.keychain(update) }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }
}

/// 0600 files in the state directory. Only for tests and headless setups without a login keychain
/// (selected explicitly with TODO_RUNNER_SECRETS=file); the default is the Keychain.
public struct FileSecretStore: SecretStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private func file(_ account: String) -> URL { directory.appendingPathComponent("secret-\(account)") }

    public func read(account: String) throws -> String? {
        guard let data = try? Data(contentsOf: file(account)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public func write(_ secret: String, account: String) throws {
        try LocalStateStore.write(Data(secret.utf8), to: file(account))
    }
    public func delete(account: String) throws { try? FileManager.default.removeItem(at: file(account)) }
}

/// Test double.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func read(account: String) throws -> String? { lock.withLock { values[account] } }
    public func write(_ secret: String, account: String) throws { lock.withLock { values[account] = secret } }
    public func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

/// Removes anything that looks like a credential before text reaches a log file or the terminal.
public struct Redactor: Sendable {
    private let secrets: [String]
    public init(secrets: [String] = []) { self.secrets = secrets.filter { $0.count >= 6 } }

    public func redact(_ text: String) -> String {
        var result = text
        for secret in secrets { result = result.replacingOccurrences(of: secret, with: "[geheim]") }
        // Bearer headers and long opaque tokens that were not registered.
        result = result.replacingOccurrences(of: #"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#, with: "Bearer [geheim]", options: .regularExpression)
        return result
    }
}
