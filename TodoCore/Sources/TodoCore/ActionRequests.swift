import Foundation

// MARK: Confirmation requests (backend ADR 0026, contracts/action-requests.yaml)
//
// Large or irreversible MCP actions (delete_project, delete_task, transfer_project_owner, ...) are not executed but
// stored as a request. Only the account whose connection triggered it sees and decides it. The feed delivers the
// pending ones in `confirmations[]`.

/// What the action would touch. `destructive` = clients ask for a second step (type the name or tick a box).
public struct ActionImpact: Codable, Sendable, Equatable, Hashable {
    public let targetType: String
    public let targetID: UUID
    public let targetName: String
    public let subprojects: Int
    public let tasks: Int
    public let newOwnerName: String?
    public let destructive: Bool

    public init(targetType: String, targetID: UUID, targetName: String, subprojects: Int = 0, tasks: Int = 0, newOwnerName: String? = nil, destructive: Bool) {
        self.targetType = targetType; self.targetID = targetID; self.targetName = targetName
        self.subprojects = subprojects; self.tasks = tasks; self.newOwnerName = newOwnerName; self.destructive = destructive
    }

    private enum CodingKeys: String, CodingKey { case targetType, targetID, targetName, subprojects, tasks, newOwnerName, destructive }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetType = try c.decode(String.self, forKey: .targetType)
        targetID = try c.decode(UUID.self, forKey: .targetID)
        targetName = try c.decode(String.self, forKey: .targetName)
        subprojects = try c.decodeIfPresent(Int.self, forKey: .subprojects) ?? 0
        tasks = try c.decodeIfPresent(Int.self, forKey: .tasks) ?? 0
        newOwnerName = try c.decodeIfPresent(String.self, forKey: .newOwnerName)
        destructive = try c.decodeIfPresent(Bool.self, forKey: .destructive) ?? true
    }
}

/// State of a request; unknown values from newer servers stay readable.
public enum ActionRequestState: Codable, Sendable, Equatable, Hashable {
    case pending, confirmed, rejected, expired, executed, failed
    case other(String)

    public init(raw: String) {
        switch raw {
        case "pending": self = .pending
        case "confirmed": self = .confirmed
        case "rejected": self = .rejected
        case "expired": self = .expired
        case "executed": self = .executed
        case "failed": self = .failed
        default: self = .other(raw)
        }
    }

    public var raw: String {
        switch self {
        case .pending: "pending"
        case .confirmed: "confirmed"
        case .rejected: "rejected"
        case .expired: "expired"
        case .executed: "executed"
        case .failed: "failed"
        case .other(let s): s
        }
    }

    public init(from decoder: any Decoder) throws { self.init(raw: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(raw) }
}

public struct ActionResult: Codable, Sendable, Equatable, Hashable {
    public let ok: Bool
    /// `deleted`, `owner_changed`, or the error reason (`forbidden`, `not_found`, `version_conflict`, `connection_revoked`).
    public let code: String
}

public struct ActionRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let tool: String
    public let state: ActionRequestState
    /// German sentence of what would happen (written by the server).
    public let summary: String
    public let impact: ActionImpact
    public let agentLabel: String?
    public let result: ActionResult?
    public let createdAt: Date?
    public let decidedAt: Date?
    public let executedAt: Date?
    public let expiresAt: Date
}

/// A pending request as the feed lists it (same fields plus the paths the card posts to).
public struct FeedConfirmation: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let tool: String
    public let summary: String
    public let impact: ActionImpact
    public let agentLabel: String?
    public let createdAt: Date?
    public let expiresAt: Date
    public let confirmPath: String?
    public let rejectPath: String?

    public init(id: UUID, tool: String, summary: String, impact: ActionImpact, agentLabel: String? = nil, createdAt: Date? = nil,
                expiresAt: Date, confirmPath: String? = nil, rejectPath: String? = nil) {
        self.id = id; self.tool = tool; self.summary = summary; self.impact = impact; self.agentLabel = agentLabel
        self.createdAt = createdAt; self.expiresAt = expiresAt; self.confirmPath = confirmPath; self.rejectPath = rejectPath
    }
}

/// Client rules of the confirmation card, the same as the PWA (`forYou.ts`): deleting a project asks for its name,
/// everything else destructive for a tick; outcome and failure texts by state, tool and result code.
public enum ConfirmationRules {
    public enum Gate: Sendable, Equatable { case typeName, tick }

    public static func gate(tool: String) -> Gate { tool == "delete_project" ? .typeName : .tick }

    /// The typed text must equal the name (surrounding blanks ignored, case counts).
    public static func nameMatches(_ typed: String, _ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !n.isEmpty && typed.trimmingCharacters(in: .whitespacesAndNewlines) == n
    }

    /// Whether "Endgültig ausführen" may be pressed.
    public static func ready(destructive: Bool, tool: String, typed: String, ticked: Bool, name: String = "") -> Bool {
        guard destructive else { return true }
        switch gate(tool: tool) {
        case .typeName: return nameMatches(typed, name)
        case .tick: return ticked
        }
    }

    /// Localization key of the outcome line of a decided request.
    public static func outcomeKey(tool: String, state: ActionRequestState, code: String?) -> String {
        switch state {
        case .rejected: return "confirm.done.rejected"
        case .expired: return "confirm.done.expired"
        case .failed: return failureKey(code)
        case .executed:
            switch tool {
            case "delete_project": return "confirm.done.projectDeleted"
            case "delete_task": return "confirm.done.taskDeleted"
            case "transfer_project_owner": return "confirm.done.ownerChanged"
            default: return "confirm.done.executed"
            }
        default: return "confirm.done.executed"
        }
    }

    public static func failureKey(_ code: String?) -> String {
        switch code {
        case "forbidden": "confirm.fail.forbidden"
        case "not_found": "confirm.fail.notFound"
        case "version_conflict": "confirm.fail.conflict"
        case "connection_revoked": "confirm.fail.revoked"
        default: "confirm.fail.other"
        }
    }
}

public enum ActionRequestFilter: String, Sendable { case all, pending, confirmed, rejected, expired, executed, failed }

extension APIClient {
    /// Own requests, newest first (at most 100).
    public func actionRequests(state: ActionRequestFilter? = nil) async throws -> [ActionRequest] {
        try await send("GET", "v1/action-requests", query: state.map { [.init(name: "state", value: $0.rawValue)] } ?? [])
    }

    public func actionRequest(_ id: UUID) async throws -> ActionRequest {
        try await send("GET", "v1/action-requests/\(id.uuidString)")
    }

    /// Confirms and executes. Returns `executed` (result.ok) or `failed` (result.code); idempotent for decided requests.
    /// 409 `already_decided` after a rejection, 410 `request_expired`.
    public func confirmActionRequest(_ id: UUID) async throws -> ActionRequest {
        try await send("POST", "v1/action-requests/\(id.uuidString)/confirm")
    }

    /// Rejects; nothing is executed.
    public func rejectActionRequest(_ id: UUID) async throws -> ActionRequest {
        try await send("POST", "v1/action-requests/\(id.uuidString)/reject")
    }
}
