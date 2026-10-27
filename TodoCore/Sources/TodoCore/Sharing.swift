import Foundation

// MARK: Teams, shares, user directory (contracts/sharing.yaml)

public enum ShareRole: String, Codable, Sendable, CaseIterable, Comparable {
    case read, comment, edit, manage
    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public enum PrincipalType: String, Codable, Sendable { case person, team }

public struct Team: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let founderID: UUID
}

public struct TeamMembership: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let teamID: UUID
    public let userID: UUID
    public let isAdmin: Bool
    public let accepted: Bool
    /// Only set by `teamInvitations()`.
    public let teamName: String?
    /// Only set by `members(teamID:)`.
    public let displayName: String?
}

public struct DirectoryUser: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
}

public struct ProjectGrant: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public let principalType: PrincipalType
    public let principalID: UUID
    public let role: ShareRole
}

public struct EffectiveVisibility: Codable, Sendable, Equatable {
    public let projectID: UUID
    /// Absent if the caller has no role (for example after transferring ownership).
    public let role: ShareRole?
    public let canTransferOwnership: Bool
    public let canDelete: Bool
    public let canManageTeam: Bool
    public let canStartAgent: Bool
    public let inherits: Bool
    public let userID: UUID
}

struct TeamBody: Encodable { let name: String }
struct MemberBody: Encodable { let userID: UUID; let isAdmin: Bool }
struct GrantBody: Encodable { let principalType: PrincipalType; let principalID: UUID; let role: ShareRole }
struct InheritanceBody: Encodable { let version: Int; let inherits: Bool }

extension APIClient {
    public func teams() async throws -> [Team] { try await send("GET", "v1/teams") }

    public func createTeam(name: String) async throws -> Team {
        try await send("POST", "v1/teams", body: TeamBody(name: name))
    }

    public func members(teamID: UUID) async throws -> [TeamMembership] {
        try await send("GET", "v1/teams/\(teamID.uuidString)/members")
    }

    /// Invites (or updates) a member; the invitee must accept.
    public func inviteMember(teamID: UUID, userID: UUID, isAdmin: Bool = false) async throws -> TeamMembership {
        try await send("PUT", "v1/teams/\(teamID.uuidString)/members", body: MemberBody(userID: userID, isAdmin: isAdmin))
    }

    public func removeMember(teamID: UUID, userID: UUID) async throws {
        try await sendNoContent("DELETE", "v1/teams/\(teamID.uuidString)/members/\(userID.uuidString)")
    }

    public func teamInvitations() async throws -> [TeamMembership] { try await send("GET", "v1/team-invitations") }

    public func acceptTeamInvitation(teamID: UUID) async throws {
        try await sendNoContent("POST", "v1/teams/\(teamID.uuidString)/accept")
    }

    /// Directory lookup by display name; `q` must be 2 to 100 characters, limit at most 20.
    public func searchUsers(_ q: String, limit: Int? = nil) async throws -> [DirectoryUser] {
        var query = [URLQueryItem(name: "q", value: q)]
        if let limit { query.append(.init(name: "limit", value: String(limit))) }
        return try await send("GET", "v1/users/search", query: query)
    }

    public func grants(projectID: UUID) async throws -> [ProjectGrant] {
        try await send("GET", "v1/projects/\(projectID.uuidString)/grants")
    }

    /// Idempotent per principal; the last role written wins.
    public func setGrant(projectID: UUID, principalType: PrincipalType, principalID: UUID, role: ShareRole) async throws -> ProjectGrant {
        try await send(
            "PUT", "v1/projects/\(projectID.uuidString)/grants",
            body: GrantBody(principalType: principalType, principalID: principalID, role: role))
    }

    public func removeGrant(projectID: UUID, grantID: UUID) async throws {
        try await sendNoContent("DELETE", "v1/projects/\(projectID.uuidString)/grants/\(grantID.uuidString)")
    }

    public func setInheritance(projectID: UUID, version: Int, inherits: Bool) async throws -> EffectiveVisibility {
        try await send("PUT", "v1/projects/\(projectID.uuidString)/inheritance", body: InheritanceBody(version: version, inherits: inherits))
    }

    public func visibility(projectID: UUID) async throws -> EffectiveVisibility {
        try await send("GET", "v1/projects/\(projectID.uuidString)/visibility")
    }
}
