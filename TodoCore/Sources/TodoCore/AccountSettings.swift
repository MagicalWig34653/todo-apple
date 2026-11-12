import Foundation

// MARK: Settings hub: appearance, passkeys, sessions, connections, runner pairing
// (contracts/identity.yaml, oauth-mcp.yaml /oauth/grants, agents.yaml POST /v1/agents/devices)

// MARK: Appearance

public enum ColorSchemeChoice: String, Codable, Sendable, CaseIterable { case system, light, dark }

public struct Appearance: Codable, Sendable, Equatable {
    public var colorScheme: String
    public var accent: String
    public var accentCustomHex: String?
    public var glow: String

    public init(colorScheme: String = "system", accent: String = "blue", accentCustomHex: String? = nil, glow: String = "subtle") {
        self.colorScheme = colorScheme; self.accent = accent; self.accentCustomHex = accentCustomHex; self.glow = glow
    }

    public var scheme: ColorSchemeChoice { ColorSchemeChoice(rawValue: colorScheme) ?? .system }

    private enum CodingKeys: String, CodingKey { case colorScheme, accent, accentCustomHex, glow }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(colorScheme, forKey: .colorScheme)
        try c.encode(accent, forKey: .accent)
        // Strict server: the hex only together with accent=custom.
        if accent == "custom" { try c.encodeIfPresent(accentCustomHex, forKey: .accentCustomHex) }
        try c.encode(glow, forKey: .glow)
    }
}

/// `GET /v1/me/preferences`. The PWA owns accent and glow; the app only changes the colour scheme and sends the rest
/// back unchanged (PUT replaces the whole document).
public struct AccountPreferences: Codable, Sendable, Equatable {
    public var version: Int
    public var appearance: Appearance
    public var revision: Int
    public var updatedAt: Date?

    public init(version: Int = 1, appearance: Appearance = Appearance(), revision: Int = 0, updatedAt: Date? = nil) {
        self.version = version; self.appearance = appearance; self.revision = revision; self.updatedAt = updatedAt
    }

    public func withColorScheme(_ scheme: ColorSchemeChoice) -> AccountPreferences {
        var copy = self
        copy.appearance.colorScheme = scheme.rawValue
        return copy
    }
}

private struct PreferencesDocument: Encodable {
    let version: Int
    let appearance: Appearance
}

// MARK: Passkeys and sessions

public struct PasskeyInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let createdAt: Date?
    public let revokedAt: Date?
    public var isActive: Bool { revokedAt == nil }

    public init(id: UUID, name: String, createdAt: Date? = nil, revokedAt: Date? = nil) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.revokedAt = revokedAt
    }
}

public struct AccountSession: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let createdAt: Date?
    public let expiresAt: Date
    /// The session of this device.
    public let current: Bool

    public init(id: UUID, createdAt: Date? = nil, expiresAt: Date, current: Bool) {
        self.id = id; self.createdAt = createdAt; self.expiresAt = expiresAt; self.current = current
    }
}

extension Array where Element == AccountSession {
    /// This device first, then the newest.
    public var sortedCurrentFirst: [AccountSession] {
        sorted { a, b in
            if a.current != b.current { return a.current }
            return (a.createdAt ?? .distantPast) > (b.createdAt ?? .distantPast)
        }
    }
}

private struct PasskeyNameBody: Encodable { let name: String }
private struct AddPasskeyFinishBody: Encodable {
    let challengeID: UUID
    let credential: RegisterFinishBody.Credential
    let passkeyName: String?
}

// MARK: Connections (OAuth grants of MCP clients)

public struct Connection: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let clientID: UUID?
    public let clientName: String?
    public let name: String?
    public let scopes: [String]
    public let projectIDs: [UUID]
    public let revoked: Bool
    public let lastUsedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, scopes, revoked, name
        case clientID = "client_id", clientName = "client_name", projectIDs = "project_ids", lastUsedAt = "last_used_at"
    }

    public init(id: UUID, clientID: UUID? = nil, clientName: String? = nil, name: String? = nil, scopes: [String] = [],
                projectIDs: [UUID] = [], revoked: Bool = false, lastUsedAt: Date? = nil) {
        self.id = id; self.clientID = clientID; self.clientName = clientName; self.name = name; self.scopes = scopes
        self.projectIDs = projectIDs; self.revoked = revoked; self.lastUsedAt = lastUsedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        clientID = try c.decodeIfPresent(UUID.self, forKey: .clientID)
        clientName = try c.decodeIfPresent(String.self, forKey: .clientName)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        projectIDs = try c.decodeIfPresent([UUID].self, forKey: .projectIDs) ?? []
        revoked = try c.decodeIfPresent(Bool.self, forKey: .revoked) ?? false
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }

    /// Name of the connection, else the client's name; empty when neither is known.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return clientName ?? ""
    }
}

extension Array where Element == Connection {
    public var active: [Connection] { filter { !$0.revoked } }
}

// MARK: Runner pairing

/// One-time code to pair a Mac runner (valid ten minutes, shown only once).
public struct RunnerPairing: Codable, Sendable, Equatable {
    public let deviceID: UUID
    public let code: String
    public let expiresAt: Date

    public init(deviceID: UUID, code: String, expiresAt: Date) { self.deviceID = deviceID; self.code = code; self.expiresAt = expiresAt }
}

private struct PairBody: Encodable { let label: String }

extension APIClient {
    // MARK: Appearance

    public func preferences() async throws -> AccountPreferences {
        try await send("GET", "v1/me/preferences")
    }

    /// Replaces the document (version and appearance only; the server counts the revision).
    public func savePreferences(_ prefs: AccountPreferences) async throws -> AccountPreferences {
        try await send("PUT", "v1/me/preferences", body: PreferencesDocument(version: prefs.version, appearance: prefs.appearance))
    }

    // MARK: Passkeys

    /// Own passkeys including revoked ones.
    public func passkeys() async throws -> [PasskeyInfo] {
        try await send("GET", "v1/me/passkeys")
    }

    public func renamePasskey(_ id: UUID, name: String) async throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw APIError.invalidInput(reason: "name_required") }
        try await sendNoContent("PATCH", "v1/me/passkeys/\(id.uuidString)", body: PasskeyNameBody(name: n))
    }

    /// 409 when it is the last usable passkey without a replacement.
    public func revokePasskey(_ id: UUID) async throws {
        try await sendNoContent("DELETE", "v1/me/passkeys/\(id.uuidString)")
    }

    /// Registers another passkey for the signed-in account (begin, platform ceremony, finish).
    public func addPasskey(name: String? = nil, authenticator: any PasskeyAuthenticator) async throws {
        let begin: RegisterBeginResponse = try await send("POST", "v1/me/passkeys/begin")
        guard let challenge = Data(base64URLEncoded: begin.options.challenge),
            let userID = Data(base64URLEncoded: begin.options.user.id)
        else { throw APIError.decoding("invalid registration options") }
        let result = try await authenticator.register(
            challenge: challenge, relyingPartyID: begin.options.rp.id, userID: userID, userName: begin.options.user.name)
        let id = result.credentialID.base64URLEncoded
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = AddPasskeyFinishBody(
            challengeID: begin.challengeID,
            credential: .init(
                id: id, rawId: id,
                response: .init(clientDataJSON: result.clientDataJSON.base64URLEncoded, attestationObject: result.attestationObject.base64URLEncoded)),
            passkeyName: trimmed?.isEmpty == false ? trimmed : nil)
        _ = try await performWithStatus(makeRequest("POST", "v1/me/passkeys/finish", query: [], body: body, auth: true))
    }

    // MARK: Sessions

    public func sessions() async throws -> [AccountSession] {
        try await send("GET", "v1/me/sessions")
    }

    public func revokeSession(_ id: UUID) async throws {
        try await sendNoContent("DELETE", "v1/me/sessions/\(id.uuidString)")
    }

    /// Signs out every other session of the account.
    public func revokeOtherSessions() async throws {
        try await sendNoContent("POST", "v1/me/sessions/revoke-others")
    }

    // MARK: Connections

    public func connections() async throws -> [Connection] {
        try await send("GET", "oauth/grants")
    }

    /// Revokes the connection and all its tokens.
    public func revokeConnection(_ id: UUID) async throws {
        try await sendNoContent("DELETE", "oauth/grants/\(id.uuidString)")
    }

    // MARK: Runner

    /// Creates a one-time pairing code for a new Mac runner.
    public func pairRunner(label: String) async throws -> RunnerPairing {
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { throw APIError.invalidInput(reason: "label_required") }
        return try await send("POST", "v1/agents/devices", body: PairBody(label: l))
    }
}
