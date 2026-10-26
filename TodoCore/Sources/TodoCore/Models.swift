import Foundation

// MARK: Auth DTOs (wire format of /v1, see the main repository's AuthController)

public struct Capabilities: Codable, Sendable, Equatable {
    public let passkey: Bool
    public let password: Bool
    public let bootstrapOpen: Bool

    public init(passkey: Bool, password: Bool, bootstrapOpen: Bool) {
        self.passkey = passkey
        self.password = password
        self.bootstrapOpen = bootstrapOpen
    }
}

public struct User: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let isAdmin: Bool
    public let username: String?

    public init(id: UUID, displayName: String, isAdmin: Bool, username: String?) {
        self.id = id
        self.displayName = displayName
        self.isAdmin = isAdmin
        self.username = username
    }
}

public struct SessionResponse: Codable, Sendable, Equatable {
    public let token: String
    public let expiresAt: Date
    public let user: User
}

public struct InvitationResponse: Codable, Sendable, Equatable {
    public let token: String
    public let expiresAt: Date
}

// MARK: Projects and tasks

public struct Project: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let parentID: UUID?
    public let name: String
    public let version: Int

    public init(id: UUID, parentID: UUID?, name: String, version: Int) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.version = version
    }
}

public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case open
    case inProgress = "in_progress"
    case inReview = "in_review"
    case done
}

public struct TodoTask: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public let title: String
    public let description: String
    /// Raw server value; unknown values from newer servers stay readable.
    public let status: String
    public let version: Int

    public init(id: UUID, projectID: UUID, title: String, description: String = "", status: String = "open", version: Int = 1) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.description = description
        self.status = status
        self.version = version
    }

    public var isDone: Bool { status == TaskStatus.done.rawValue }
}

/// Partial update; `version` must be the version the caller last saw.
public struct TaskUpdate: Sendable, Equatable {
    public var title: String?
    public var description: String?
    public var status: TaskStatus?
    public var projectID: UUID?

    public init(title: String? = nil, description: String? = nil, status: TaskStatus? = nil, projectID: UUID? = nil) {
        self.title = title
        self.description = description
        self.status = status
        self.projectID = projectID
    }
}

/// Partial project update. Use `moveToRoot` (not a nil parent) to detach from the parent.
public struct ProjectUpdate: Sendable, Equatable {
    public var name: String?
    public var parentID: UUID?
    public var moveToRoot: Bool?

    public init(name: String? = nil, parentID: UUID? = nil, moveToRoot: Bool? = nil) {
        self.name = name
        self.parentID = parentID
        self.moveToRoot = moveToRoot
    }
}

// MARK: Request bodies

struct PasswordLoginBody: Encodable { let username: String; let password: String }
struct RegisterBeginBody: Encodable { let token: String; let displayName: String }
struct CreateProjectBody: Encodable { let name: String; let parentID: UUID? }
struct UpdateProjectBody: Encodable {
    let version: Int
    let name: String?
    let parentID: UUID?
    let moveToRoot: Bool?
}
struct CreateTaskBody: Encodable { let projectID: UUID; let title: String; let description: String? }
struct UpdateTaskBody: Encodable {
    let version: Int
    let title: String?
    let description: String?
    let status: String?
    let projectID: UUID?
}
