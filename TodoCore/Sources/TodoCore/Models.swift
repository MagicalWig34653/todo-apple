import Foundation

// MARK: Auth DTOs (wire format of /v1, see the main repository's AuthController)

public struct Capabilities: Codable, Sendable, Equatable {
    public let passkey: Bool
    public let password: Bool
    public let bootstrapOpen: Bool
    /// Live refresh hints of newer servers (ADR 0022); nil on older servers or when disabled.
    public let liveRefresh: LiveRefreshCapability?

    public init(passkey: Bool, password: Bool, bootstrapOpen: Bool, liveRefresh: LiveRefreshCapability? = nil) {
        self.passkey = passkey
        self.password = password
        self.bootstrapOpen = bootstrapOpen
        self.liveRefresh = liveRefresh
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
    public var id: UUID
    public var parentID: UUID?
    public var name: String
    public var version: Int
    /// Shared project description (nil = none).
    public var description: String?
    /// `#RRGGBB` or nil (no colour chosen).
    public var color: String?
    public var createdAt: Date?
    /// The viewer's own sibling order (dense 0..n-1, ADR 0012); nil for projects that were never positioned.
    public var position: Int?
    /// The viewer's favourite flag and its order among the favourites.
    public var isFavorite: Bool
    public var favoritePosition: Int?

    public init(
        id: UUID, parentID: UUID?, name: String, version: Int, description: String? = nil, color: String? = nil,
        createdAt: Date? = nil, position: Int? = nil, isFavorite: Bool = false, favoritePosition: Int? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.version = version
        self.description = description
        self.color = color
        self.createdAt = createdAt
        self.position = position
        self.isFavorite = isFavorite
        self.favoritePosition = favoritePosition
    }

    private enum CodingKeys: String, CodingKey {
        case id, parentID, name, version, description, color, createdAt, position, isFavorite, favoritePosition
    }

    /// Older servers omit the ADR 0012 fields.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(Int.self, forKey: .version)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        position = try c.decodeIfPresent(Int.self, forKey: .position)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        favoritePosition = try c.decodeIfPresent(Int.self, forKey: .favoritePosition)
    }
}

public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case open
    case inProgress = "in_progress"
    case inReview = "in_review"
    case done
}

public struct TodoTask: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public let title: String
    public let description: String
    /// Raw server value; unknown values from newer servers stay readable.
    public let status: String
    public let version: Int
    /// Board column of the project (nil = "Ohne Spalte" or a project without own columns) and the position in it.
    public var columnID: UUID?
    public var boardPosition: Int

    public init(
        id: UUID, projectID: UUID, title: String, description: String = "", status: String = "open", version: Int = 1,
        columnID: UUID? = nil, boardPosition: Int = 0
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.description = description
        self.status = status
        self.version = version
        self.columnID = columnID
        self.boardPosition = boardPosition
    }

    private enum CodingKeys: String, CodingKey { case id, projectID, title, description, status, version, columnID, boardPosition }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decode(String.self, forKey: .description)
        status = try c.decode(String.self, forKey: .status)
        version = try c.decode(Int.self, forKey: .version)
        columnID = try c.decodeIfPresent(UUID.self, forKey: .columnID)
        boardPosition = try c.decodeIfPresent(Int.self, forKey: .boardPosition) ?? 0
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
    /// nil = unchanged, "" = clear.
    public var description: String?
    /// nil = unchanged, "" = clear, otherwise `#RRGGBB`.
    public var color: String?

    public init(
        name: String? = nil, parentID: UUID? = nil, moveToRoot: Bool? = nil, description: String? = nil, color: String? = nil
    ) {
        self.name = name
        self.parentID = parentID
        self.moveToRoot = moveToRoot
        self.description = description
        self.color = color
    }
}

// MARK: Request bodies

struct PasswordLoginBody: Encodable { let username: String; let password: String }
struct RegisterBeginBody: Encodable { let token: String; let displayName: String }
struct CreateProjectBody: Encodable { let name: String; let parentID: UUID?; let description: String?; let color: String? }
struct UpdateProjectBody: Encodable {
    let version: Int
    let name: String?
    let parentID: UUID?
    let moveToRoot: Bool?
    let description: String?
    let color: String?
}
struct CreateTaskBody: Encodable { let projectID: UUID; let title: String; let description: String? }
struct UpdateTaskBody: Encodable {
    let version: Int
    let title: String?
    let description: String?
    let status: String?
    let projectID: UUID?
}
