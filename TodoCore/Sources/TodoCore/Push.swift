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
    /// Agent confirmation requests (`action_request`); additive in contract 1.1.0, default on.
    case confirmations
    /// Opt-in daily brief (`daily_brief`); additive in contract 1.1.0, default off.
    case dailyBrief = "daily_brief"
}

public struct PushCategories: Codable, Sendable, Equatable {
    public var reminders: Bool
    public var agentQuestions: Bool
    public var agentReviews: Bool
    public var assignments: Bool
    public var comments: Bool
    public var confirmations: Bool
    public var dailyBrief: Bool

    enum CodingKeys: String, CodingKey {
        case reminders, assignments, comments, confirmations
        case agentQuestions = "agent_questions"
        case agentReviews = "agent_reviews"
        case dailyBrief = "daily_brief"
    }

    /// Server defaults (ADR 0021, contract 1.1.0).
    public init(reminders: Bool = true, agentQuestions: Bool = true, agentReviews: Bool = true, assignments: Bool = false, comments: Bool = false,
                confirmations: Bool = true, dailyBrief: Bool = false) {
        self.reminders = reminders; self.agentQuestions = agentQuestions; self.agentReviews = agentReviews
        self.assignments = assignments; self.comments = comments
        self.confirmations = confirmations; self.dailyBrief = dailyBrief
    }

    /// Servers before contract 1.1.0 do not send `confirmations` and `daily_brief`; those keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reminders = try c.decode(Bool.self, forKey: .reminders)
        agentQuestions = try c.decode(Bool.self, forKey: .agentQuestions)
        agentReviews = try c.decode(Bool.self, forKey: .agentReviews)
        assignments = try c.decode(Bool.self, forKey: .assignments)
        comments = try c.decode(Bool.self, forKey: .comments)
        confirmations = try c.decodeIfPresent(Bool.self, forKey: .confirmations) ?? true
        dailyBrief = try c.decodeIfPresent(Bool.self, forKey: .dailyBrief) ?? false
    }

    public subscript(category: PushCategory) -> Bool {
        get {
            switch category {
            case .reminders: reminders
            case .agentQuestions: agentQuestions
            case .agentReviews: agentReviews
            case .assignments: assignments
            case .comments: comments
            case .confirmations: confirmations
            case .dailyBrief: dailyBrief
            }
        }
        set {
            switch category {
            case .reminders: reminders = newValue
            case .agentQuestions: agentQuestions = newValue
            case .agentReviews: agentReviews = newValue
            case .assignments: assignments = newValue
            case .comments: comments = newValue
            case .confirmations: confirmations = newValue
            case .dailyBrief: dailyBrief = newValue
            }
        }
    }
}

public struct PushPrefs: Codable, Sendable, Equatable {
    public var categories: PushCategories
    /// false (server default): generic texts without task titles on the lock screen.
    public var showContent: Bool
    public var badge: Bool
    /// UTC hour (0...23) from which the daily brief is sent. nil: the server did not report one (older server);
    /// the server then uses 8.
    public var dailyBriefHour: Int?

    /// True if the server reported the confirmation/daily-brief settings (contract 1.1.0 or newer). Older servers
    /// answer without them; the UI then hides the two switches instead of showing ones that do nothing.
    public var supportsBriefSettings: Bool

    public init(categories: PushCategories = .init(), showContent: Bool = false, badge: Bool = true, dailyBriefHour: Int? = nil,
                supportsBriefSettings: Bool = false) {
        self.categories = categories; self.showContent = showContent; self.badge = badge; self.dailyBriefHour = dailyBriefHour
        self.supportsBriefSettings = supportsBriefSettings
    }

    enum CodingKeys: String, CodingKey { case categories, showContent, badge, dailyBriefHour }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categories = try c.decode(PushCategories.self, forKey: .categories)
        showContent = try c.decode(Bool.self, forKey: .showContent)
        badge = try c.decode(Bool.self, forKey: .badge)
        dailyBriefHour = try c.decodeIfPresent(Int.self, forKey: .dailyBriefHour)
        let raw = try c.decodeIfPresent([String: Bool].self, forKey: .categories)
        supportsBriefSettings = c.contains(.dailyBriefHour) || raw?["daily_brief"] != nil || raw?["confirmations"] != nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(categories, forKey: .categories); try c.encode(showContent, forKey: .showContent)
        try c.encode(badge, forKey: .badge); try c.encodeIfPresent(dailyBriefHour, forKey: .dailyBriefHour)
    }
}

/// The daily brief hour is a UTC hour on the server; people pick a local time.
public enum DailyBriefHour {
    public static let defaultUTCHour = 8

    /// Server value, or the default if it is missing or outside 0...23.
    public static func effective(_ utcHour: Int?) -> Int {
        guard let utcHour, (0...23).contains(utcHour) else { return defaultUTCHour }
        return utcHour
    }

    public struct Option: Equatable, Sendable, Identifiable {
        public let utcHour: Int
        /// Local time of day in minutes (whole hours of UTC can land on :30 or :45 in some zones).
        public let localMinutes: Int
        public var id: Int { utcHour }
    }

    /// Minutes since local midnight at which `utcHour` falls (today's offset, so daylight saving is respected).
    public static func localMinutes(utcHour: Int, now: Date, timeZone: TimeZone) -> Int {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = utc.date(bySettingHour: utcHour, minute: 0, second: 0, of: now) ?? now
        var local = Calendar(identifier: .gregorian); local.timeZone = timeZone
        let parts = local.dateComponents([.hour, .minute], from: instant)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// The UTC hour that falls on `localMinutes` (minutes since local midnight), nil if no whole UTC hour does
    /// (e.g. 07:30 in Berlin). This is what the picker stores when somebody chooses a local time.
    public static func utcHour(localMinutes: Int, now: Date = Date(), timeZone: TimeZone = .current) -> Int? {
        (0...23).first { Self.localMinutes(utcHour: $0, now: now, timeZone: timeZone) == localMinutes }
    }

    /// All 24 UTC hours, ordered by local time of day.
    public static func options(now: Date = Date(), timeZone: TimeZone = .current) -> [Option] {
        (0...23).map { Option(utcHour: $0, localMinutes: localMinutes(utcHour: $0, now: now, timeZone: timeZone)) }
            .sorted { $0.localMinutes < $1.localMinutes }
    }
}

/// Partial update; only set fields are sent.
public struct PushPrefsUpdate: Encodable, Sendable, Equatable {
    public var categories: [String: Bool]?
    public var showContent: Bool?
    public var badge: Bool?
    /// UTC hour 0...23; the server rejects other values with `invalid_daily_brief_hour`.
    public var dailyBriefHour: Int?

    public init(categories: [PushCategory: Bool]? = nil, showContent: Bool? = nil, badge: Bool? = nil, dailyBriefHour: Int? = nil) {
        self.categories = categories.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
        self.showContent = showContent; self.badge = badge; self.dailyBriefHour = dailyBriefHour
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
    /// Question, review or daily brief: the command center, with that task's card if there is one.
    case commandCenter(taskID: UUID?, projectID: UUID?)
    case project(UUID)
    /// "Für dich" (the feed with the confirmation cards). `requestID` is the confirmation request to bring up; nil or an
    /// id the feed does not list any more shows just "Für dich".
    case forYou(requestID: UUID?)
}

/// The top-level `userInfo` fields the server sends plus `aps.category`, `aps.badge`, `aps.thread-id`.
/// What to do with a tapped link right now (stub).
public enum PushLinkReadiness: Equatable, Sendable { case now, wait, refresh }

extension PushLink {
    public func readiness(knownProjects: Set<UUID>, initialDataLoaded: Bool) -> PushLinkReadiness { .now }
}

public struct PushPayload: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case reminder, question, review, comment, test
        /// Agent confirmation request: `subjectID` is the request, no task or project.
        case actionRequest = "action_request"
        /// Daily brief: no identifiers.
        case dailyBrief = "daily_brief"
    }

    public let kind: Kind?
    public let taskID: UUID?
    public let projectID: UUID?
    public let subjectID: UUID?
    public let category: String?
    public let badge: Int?
    /// `aps.thread-id` (the server sends the project id); nil if missing or empty.
    public let threadID: String?

    public init(kind: Kind?, taskID: UUID? = nil, projectID: UUID? = nil, subjectID: UUID? = nil, category: String? = nil,
                badge: Int? = nil, threadID: String? = nil) {
        self.kind = kind; self.taskID = taskID; self.projectID = projectID; self.subjectID = subjectID
        self.category = category; self.badge = badge; self.threadID = threadID
    }

    /// Tolerant parsing: unknown or malformed fields become nil, a payload is never rejected as a whole.
    public init(userInfo: [AnyHashable: Any]) {
        func id(_ key: String) -> UUID? { (userInfo[key] as? String).flatMap { UUID(uuidString: $0) } }
        let aps = userInfo["aps"] as? [String: Any]
        kind = (userInfo["kind"] as? String).flatMap(Kind.init(rawValue:))
        taskID = id("taskID"); projectID = id("projectID"); subjectID = id("subjectID")
        category = aps?["category"] as? String
        badge = (aps?["badge"] as? NSNumber)?.intValue
        threadID = (aps?["thread-id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Default tap destination. `test` and unknown kinds open nothing.
    public var link: PushLink? {
        switch kind {
        case .reminder, .comment:
            if let taskID { return .task(taskID: taskID, projectID: projectID) }
            return projectID.map(PushLink.project)
        case .actionRequest:
            return .forYou(requestID: subjectID)
        case .question, .review, .dailyBrief:
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
    public static let confirmation = "TODO_CONFIRMATION"
    public static let dailyBrief = "TODO_DAILY_BRIEF"
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

/// Grouping of notifications on the lock screen and in Notification Center: one stack per project, with a summary line
/// per category ("3 weitere Rückfragen"). Remote pushes get their stack from the server's `aps.thread-id`; this decides it
/// for local copies ("Später") and names the summary strings the categories register.
public enum PushGrouping {
    /// Server thread first, then the project (same value the server uses, uppercase UUID), then the kind for pushes
    /// without a project (confirmations, daily brief), else nil (no stack of its own).
    public static func threadIdentifier(for payload: PushPayload) -> String? {
        if let threadID = payload.threadID { return threadID }
        if let projectID = payload.projectID { return projectID.uuidString }
        return payload.kind.map { "todolino.\($0.rawValue)" }
    }

    /// Localization key of the summary format (`%u` = number of hidden notifications) of a category; nil for unknown ones.
    public static func summaryFormatKey(category: String) -> String? {
        switch category {
        case PushIdentifiers.reminder: "push.summary.reminders"
        case PushIdentifiers.question: "push.summary.questions"
        case PushIdentifiers.review: "push.summary.reviews"
        case PushIdentifiers.comment: "push.summary.comments"
        case PushIdentifiers.confirmation: "push.summary.confirmations"
        case PushIdentifiers.dailyBrief: "push.summary.dailyBrief"
        default: nil
        }
    }
}
