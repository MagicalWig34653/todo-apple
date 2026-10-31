import Foundation

// MARK: APNs push (ADR 0021, contracts/push.yaml in the main repository)
// Device registration and per-account preferences. Delivery itself is server-side; the client only registers the
// APNs token, mirrors the preferences and maps incoming notification payloads to in-app destinations.

public enum PushPlatform: String, Codable, Sendable { case ios, macos }
public enum PushEnvironment: String, Codable, Sendable { case sandbox, production }

/// Helpers for the APNs device token.
public enum PushToken {
    /// Lowercase hex of the raw token bytes (what `POST /v1/push/devices` expects; 32 to 200 characters).
    public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    public static func isValid(_ hex: String) -> Bool {
        (32...200).contains(hex.count) && hex.allSatisfy(\.isHexDigit)
    }
}

public struct PushRegistration: Codable, Sendable, Equatable {
    public var token: String
    public var platform: PushPlatform
    public var environment: PushEnvironment
    public var bundleId: String
    public var appVersion: String?
    public var locale: String?

    public init(token: String, platform: PushPlatform, environment: PushEnvironment, bundleId: String, appVersion: String? = nil, locale: String? = nil) {
        self.token = token; self.platform = platform; self.environment = environment
        self.bundleId = bundleId; self.appVersion = appVersion; self.locale = locale
    }
}

/// A registered device as returned by the server (never contains the token).
public struct PushDevice: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let platform: PushPlatform
    public let environment: PushEnvironment
    public let bundleId: String
    public let appVersion: String?
    public let locale: String?
    public let createdAt: Date?
    public let lastSeenAt: Date
}

/// Notification categories the server knows (`categories` keys of the preferences).
public enum PushCategory: String, Codable, Sendable, CaseIterable {
    case reminders
    case agentQuestions = "agent_questions"
    case agentReviews = "agent_reviews"
    case assignments
    case comments
}

public struct PushCategories: Codable, Sendable, Equatable {
    public var reminders: Bool
    public var agentQuestions: Bool
    public var agentReviews: Bool
    public var assignments: Bool
    public var comments: Bool

    enum CodingKeys: String, CodingKey {
        case reminders, assignments, comments
        case agentQuestions = "agent_questions"
        case agentReviews = "agent_reviews"
    }

    /// Server defaults (ADR 0021).
    public init(reminders: Bool = true, agentQuestions: Bool = true, agentReviews: Bool = true, assignments: Bool = false, comments: Bool = false) {
        self.reminders = reminders; self.agentQuestions = agentQuestions; self.agentReviews = agentReviews
        self.assignments = assignments; self.comments = comments
    }

    public subscript(category: PushCategory) -> Bool {
        get {
            switch category {
            case .reminders: reminders
            case .agentQuestions: agentQuestions
            case .agentReviews: agentReviews
            case .assignments: assignments
            case .comments: comments
            }
        }
        set {
            switch category {
            case .reminders: reminders = newValue
            case .agentQuestions: agentQuestions = newValue
            case .agentReviews: agentReviews = newValue
            case .assignments: assignments = newValue
            case .comments: comments = newValue
            }
        }
    }
}

public struct PushPrefs: Codable, Sendable, Equatable {
    public var categories: PushCategories
    /// false (server default): generic texts without task titles on the lock screen.
    public var showContent: Bool
    public var badge: Bool

    public init(categories: PushCategories = .init(), showContent: Bool = false, badge: Bool = true) {
        self.categories = categories; self.showContent = showContent; self.badge = badge
    }
}

/// Partial update; only set fields are sent.
public struct PushPrefsUpdate: Encodable, Sendable, Equatable {
    public var categories: [String: Bool]?
    public var showContent: Bool?
    public var badge: Bool?

    public init(categories: [PushCategory: Bool]? = nil, showContent: Bool? = nil, badge: Bool? = nil) {
        self.categories = categories.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
        self.showContent = showContent; self.badge = badge
    }
}

extension APIClient {
    /// Idempotent per token. Older servers without push answer 404 (`isPushUnavailable`).
    public func registerPushDevice(_ registration: PushRegistration) async throws -> PushDevice {
        try await send("POST", "v1/push/devices", body: registration)
    }

    public func pushDevices() async throws -> [PushDevice] {
        try await send("GET", "v1/push/devices")
    }

    /// 404 for an unknown, foreign or already revoked device.
    public func revokePushDevice(_ id: UUID) async throws {
        try await sendNoContent("DELETE", "v1/push/devices/\(id.uuidString.lowercased())")
    }

    public func pushPrefs() async throws -> PushPrefs {
        try await send("GET", "v1/me/push-prefs")
    }

    public func updatePushPrefs(_ update: PushPrefsUpdate) async throws -> PushPrefs {
        try await send("POST", "v1/me/push-prefs", body: update)
    }

    /// True if the error means the server has no push endpoints (older server): push features then stay hidden.
    public static func isPushUnavailable(_ error: Error) -> Bool {
        if case .notFound = error as? APIError { return true }
        return false
    }
}

// MARK: Incoming notifications

/// What a notification wants to open. Pure value so payload mapping is testable without UserNotifications.
public enum PushLink: Equatable, Sendable {
    case task(taskID: UUID, projectID: UUID?)
    /// Question or review: the command center with that task's card.
    case commandCenter(taskID: UUID?, projectID: UUID?)
    case project(UUID)
}

/// The top-level `userInfo` fields the server sends plus `aps.category`, `aps.badge`, `aps.thread-id`.
public struct PushPayload: Equatable, Sendable {
    public enum Kind: String, Sendable { case reminder, question, review, comment, test }

    public let kind: Kind?
    public let taskID: UUID?
    public let projectID: UUID?
    public let subjectID: UUID?
    public let category: String?
    public let badge: Int?

    public init(kind: Kind?, taskID: UUID? = nil, projectID: UUID? = nil, subjectID: UUID? = nil, category: String? = nil, badge: Int? = nil) {
        self.kind = kind; self.taskID = taskID; self.projectID = projectID; self.subjectID = subjectID
        self.category = category; self.badge = badge
    }

    /// Tolerant parsing: unknown or malformed fields become nil, a payload is never rejected as a whole.
    public init(userInfo: [AnyHashable: Any]) {
        func id(_ key: String) -> UUID? { (userInfo[key] as? String).flatMap { UUID(uuidString: $0) } }
        let aps = userInfo["aps"] as? [String: Any]
        kind = (userInfo["kind"] as? String).flatMap(Kind.init(rawValue:))
        taskID = id("taskID"); projectID = id("projectID"); subjectID = id("subjectID")
        category = aps?["category"] as? String
        badge = (aps?["badge"] as? NSNumber)?.intValue
    }

    /// Default tap destination. `test` and unknown kinds open nothing.
    public var link: PushLink? {
        switch kind {
        case .reminder, .comment:
            if let taskID { return .task(taskID: taskID, projectID: projectID) }
            return projectID.map(PushLink.project)
        case .question, .review:
            if taskID != nil || projectID != nil { return .commandCenter(taskID: taskID, projectID: projectID) }
            return .commandCenter(taskID: nil, projectID: nil)
        case .test, nil:
            return nil
        }
    }
}

/// Category and action identifiers shared by the app (registration) and the mapping below.
public enum PushIdentifiers {
    public static let reminder = "TODO_REMINDER"
    public static let question = "TODO_QUESTION"
    public static let review = "TODO_REVIEW"
    public static let comment = "TODO_COMMENT"
    public static let actionDone = "TODO_DONE"
    public static let actionSnooze = "TODO_SNOOZE"
    public static let actionAnswer = "TODO_ANSWER"
    public static let actionOpen = "TODO_OPEN"
    /// `UNNotificationDefaultActionIdentifier` / `UNNotificationDismissActionIdentifier` raw values.
    public static let systemDefault = "com.apple.UNNotificationDefaultActionIdentifier"
    public static let systemDismiss = "com.apple.UNNotificationDismissActionIdentifier"
}

/// What the app does with a user's response to a notification.
public enum PushResponseAction: Equatable, Sendable {
    case open(PushLink)
    case markDone(taskID: UUID, projectID: UUID?)
    case snooze(taskID: UUID)
    case none

    public static func resolve(actionIdentifier: String, payload: PushPayload) -> PushResponseAction {
        switch actionIdentifier {
        case PushIdentifiers.actionDone:
            guard payload.kind == .reminder, let taskID = payload.taskID else { return .none }
            return .markDone(taskID: taskID, projectID: payload.projectID)
        case PushIdentifiers.actionSnooze:
            guard payload.kind == .reminder, let taskID = payload.taskID else { return .none }
            return .snooze(taskID: taskID)
        case PushIdentifiers.systemDismiss:
            return .none
        default:
            // Default tap, "answer" and "open" all open the destination.
            return payload.link.map(PushResponseAction.open) ?? .none
        }
    }
}
