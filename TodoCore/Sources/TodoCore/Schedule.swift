import Foundation

// MARK: Calendar schedule (contracts/planning-ext.yaml 1.2.0, ADR 0033)
//
// `GET /v1/planning/schedule` (window), `GET /v1/planning/unscheduled` (sidebar "Ohne Termin") and
// `PATCH /v1/tasks/{id}/schedule` (the only partial write for calendar moves). Pure rules live in `CalendarPlanning.swift`.

/// Hints the server computes for an entry. They are shown, never prevent a move. Unknown codes of newer servers are dropped.
public enum ScheduleConflict: String, Codable, Sendable, CaseIterable {
    case afterDue = "after_due"
    case prerequisiteLater = "prerequisite_later"
    case prerequisiteOpen = "prerequisite_open"
    case repositoryOverlap = "repository_overlap"
}

/// One card in the calendar window (`ScheduleEntry`).
public struct ScheduleEntry: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var taskID: UUID
    public var projectID: UUID
    public var title: String
    /// Raw server value (`open`, `in_progress`, `in_review`, `done`); unknown values stay readable.
    public var status: String
    /// Task version for the next `PATCH`.
    public var version: Int
    public var plannedAt: Date?
    public var plannedMinutes: Int?
    public var plannedAllDay: Bool
    public var dueAt: Date?
    /// An open prerequisite exists.
    public var blocked: Bool
    /// Role `edit`; read-only cards are not draggable. Missing key = false (safe default).
    public var canEdit: Bool
    public var autoStart: Bool
    public var autoStartedAt: Date?
    /// State of the newest agent job of the card, else nil.
    public var jobState: String?
    /// Binding of the newest agent job (cards with the same key share one runner slot), else nil.
    public var repositoryKey: String?
    public var conflicts: [ScheduleConflict]
    public var id: UUID { taskID }

    public init(
        taskID: UUID, projectID: UUID, title: String, status: String = "open", version: Int = 1, plannedAt: Date? = nil,
        plannedMinutes: Int? = nil, plannedAllDay: Bool = false, dueAt: Date? = nil, blocked: Bool = false, canEdit: Bool = true,
        autoStart: Bool = false, autoStartedAt: Date? = nil, jobState: String? = nil, repositoryKey: String? = nil,
        conflicts: [ScheduleConflict] = []
    ) {
        self.taskID = taskID; self.projectID = projectID; self.title = title; self.status = status; self.version = version
        self.plannedAt = plannedAt; self.plannedMinutes = plannedMinutes; self.plannedAllDay = plannedAllDay; self.dueAt = dueAt
        self.blocked = blocked; self.canEdit = canEdit; self.autoStart = autoStart; self.autoStartedAt = autoStartedAt
        self.jobState = jobState; self.repositoryKey = repositoryKey; self.conflicts = conflicts
    }

    /// A card of the sidebar "Ohne Termin". The planning list carries no role, so the caller says whether the user may edit.
    public init(unscheduled planningTask: PlanningTask, canEdit: Bool) {
        self.init(
            taskID: planningTask.task.id, projectID: planningTask.task.projectID, title: planningTask.task.title,
            status: planningTask.task.status, version: planningTask.task.version, plannedAt: nil, plannedMinutes: nil, plannedAllDay: false,
            dueAt: planningTask.planning.dueAt, canEdit: canEdit, autoStart: false)
    }

    private enum CodingKeys: String, CodingKey {
        case taskID, projectID, title, status, version, plannedAt, plannedMinutes, plannedAllDay, dueAt, blocked, canEdit
        case autoStart, autoStartedAt, jobState, repositoryKey, conflicts
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try c.decode(UUID.self, forKey: .taskID)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(String.self, forKey: .status)
        version = try c.decode(Int.self, forKey: .version)
        plannedAt = try c.decodeIfPresent(Date.self, forKey: .plannedAt)
        plannedMinutes = try c.decodeIfPresent(Int.self, forKey: .plannedMinutes)
        plannedAllDay = try c.decodeIfPresent(Bool.self, forKey: .plannedAllDay) ?? false
        dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
        canEdit = try c.decodeIfPresent(Bool.self, forKey: .canEdit) ?? false
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        autoStartedAt = try c.decodeIfPresent(Date.self, forKey: .autoStartedAt)
        jobState = try c.decodeIfPresent(String.self, forKey: .jobState)
        repositoryKey = try c.decodeIfPresent(String.self, forKey: .repositoryKey)
        let raw = try c.decodeIfPresent([String].self, forKey: .conflicts) ?? []
        conflicts = raw.compactMap(ScheduleConflict.init(rawValue:))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(taskID, forKey: .taskID)
        try c.encode(projectID, forKey: .projectID)
        try c.encode(title, forKey: .title)
        try c.encode(status, forKey: .status)
        try c.encode(version, forKey: .version)
        try c.encode(plannedAt, forKey: .plannedAt)
        try c.encode(plannedMinutes, forKey: .plannedMinutes)
        try c.encode(plannedAllDay, forKey: .plannedAllDay)
        try c.encode(dueAt, forKey: .dueAt)
        try c.encode(blocked, forKey: .blocked)
        try c.encode(canEdit, forKey: .canEdit)
        try c.encode(autoStart, forKey: .autoStart)
        try c.encode(autoStartedAt, forKey: .autoStartedAt)
        try c.encode(jobState, forKey: .jobState)
        try c.encode(repositoryKey, forKey: .repositoryKey)
        try c.encode(conflicts, forKey: .conflicts)
    }
}

public struct ScheduleResponse: Codable, Sendable, Equatable {
    public var from: Date
    public var to: Date
    /// The limit was reached; more cards exist in the window.
    public var truncated: Bool
    public var items: [ScheduleEntry]

    public init(from: Date, to: Date, truncated: Bool = false, items: [ScheduleEntry] = []) {
        self.from = from; self.to = to; self.truncated = truncated; self.items = items
    }

    private enum CodingKeys: String, CodingKey { case from, to, truncated, items }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(Date.self, forKey: .from)
        to = try c.decode(Date.self, forKey: .to)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        items = try c.decode([ScheduleEntry].self, forKey: .items)
    }
}

// MARK: Partial write

/// One field of a partial write: untouched (key absent), set, or cleared (`null`).
public enum FieldChange<Value: Sendable & Equatable>: Sendable, Equatable {
    case keep, set(Value), clear
}

/// What a calendar move changes. `dueAt`, priority, recurrence and reminders are not part of it by design.
public struct SchedulePatch: Sendable, Equatable {
    public var plannedAt: FieldChange<Date>
    public var plannedMinutes: FieldChange<Int>
    /// nil = key absent (unchanged); `false` is a real value.
    public var plannedAllDay: Bool?

    public init(plannedAt: FieldChange<Date> = .keep, plannedMinutes: FieldChange<Int> = .keep, plannedAllDay: Bool? = nil) {
        self.plannedAt = plannedAt; self.plannedMinutes = plannedMinutes; self.plannedAllDay = plannedAllDay
    }

    public var isEmpty: Bool { plannedAt == .keep && plannedMinutes == .keep && plannedAllDay == nil }
}

/// Body of `PATCH /v1/tasks/{id}/schedule`: the expected task version plus only the keys that change.
public struct ScheduleUpdate: Encodable, Sendable, Equatable {
    public var version: Int
    public var patch: SchedulePatch

    public init(version: Int, _ patch: SchedulePatch) { self.version = version; self.patch = patch }

    private enum CodingKeys: String, CodingKey { case version, plannedAt, plannedMinutes, plannedAllDay }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        switch patch.plannedAt {
        case .keep: break
        case .set(let date): try c.encode(date, forKey: .plannedAt)
        case .clear: try c.encodeNil(forKey: .plannedAt)
        }
        switch patch.plannedMinutes {
        case .keep: break
        case .set(let minutes): try c.encode(minutes, forKey: .plannedMinutes)
        case .clear: try c.encodeNil(forKey: .plannedMinutes)
        }
        if let allDay = patch.plannedAllDay { try c.encode(allDay, forKey: .plannedAllDay) }
    }
}

// MARK: Errors

/// Failures of the schedule calls with the server's documented reasons as cases; everything else (401, transport, ...)
/// stays an `APIError` inside `.other`.
public enum ScheduleError: Error, Equatable, Sendable {
    /// 409 `version_conflict`: someone else changed the card; reload.
    case versionConflict
    /// 409 `task_done`: finished cards are not moved.
    case taskDone
    /// 400 `invalid_planned_minutes`: duration outside 5 to 1440.
    case invalidPlannedMinutes
    /// 400 `all_day_requires_planned_at`.
    case allDayRequiresPlannedAt
    /// 400 `recurrence_requires_date`: clearing the start of a repeating card without due date.
    case recurrenceRequiresDate
    /// 400 `invalid_schedule` (inconsistent combination of keys).
    case invalidSchedule
    /// 403: read-only role.
    case readOnly
    /// 404: missing, hidden or foreign card or project.
    case notFound
    /// 400 `invalid_window` (`to` not after `from`, or unreadable dates).
    case invalidWindow
    /// 400 `window_too_large` (more than 62 days).
    case windowTooLarge
    /// 400 `invalid_limit`.
    case invalidLimit
    /// 429 `rate_limited`.
    case rateLimited
    case other(APIError)

    public init(_ error: APIError) {
        switch error {
        case .versionConflict: self = .versionConflict
        case .conflict(let reason) where reason == "task_done": self = .taskDone
        case .invalidInput(let reason):
            switch reason {
            case "invalid_planned_minutes": self = .invalidPlannedMinutes
            case "all_day_requires_planned_at": self = .allDayRequiresPlannedAt
            case "recurrence_requires_date": self = .recurrenceRequiresDate
            case "invalid_schedule": self = .invalidSchedule
            case "invalid_window": self = .invalidWindow
            case "window_too_large": self = .windowTooLarge
            case "invalid_limit": self = .invalidLimit
            default: self = .other(error)
            }
        case .forbidden: self = .readOnly
        case .notFound: self = .notFound
        case .server(let status, _) where status == 429: self = .rateLimited
        default: self = .other(error)
        }
    }

    /// The underlying error when it is not one of the typed cases (for the app's general error handling: 401, offline, ...).
    public var apiError: APIError? {
        if case .other(let error) = self { return error }
        return nil
    }
}

// MARK: Client

extension APIClient {
    /// Cards with a start, due date or all-day assignment in `[from, to)` (at most 62 days), visible projects only.
    /// Done cards are included. `limit` 1 to 500 (server default 500); `ScheduleResponse.truncated` says if it was reached.
    public func schedule(from: Date, to: Date, projectID: UUID? = nil, limit: Int? = nil) async throws -> ScheduleResponse {
        var query = [URLQueryItem(name: "from", value: Self.queryDate(from)), URLQueryItem(name: "to", value: Self.queryDate(to))]
        if let projectID { query.append(.init(name: "projectID", value: projectID.uuidString)) }
        if let limit { query.append(.init(name: "limit", value: String(limit))) }
        do { return try await send("GET", "v1/planning/schedule", query: query) }
        catch let error as APIError { throw ScheduleError(error) }
    }

    /// Open cards without a planned start for the sidebar "Ohne Termin" (priority, then due date). `limit` 1 to 500 (server default 200).
    public func unscheduled(projectID: UUID? = nil, limit: Int? = nil) async throws -> [PlanningTask] {
        var query: [URLQueryItem] = []
        if let projectID { query.append(.init(name: "projectID", value: projectID.uuidString)) }
        if let limit { query.append(.init(name: "limit", value: String(limit))) }
        return try await send("GET", "v1/planning/unscheduled", query: query)
    }

    /// Changes start, duration and all-day of one card; only the keys in `patch` are sent, `version` is the card's current
    /// version (`409 version_conflict` otherwise). The answer carries the card's new version.
    public func updateSchedule(taskID: UUID, version: Int, _ patch: SchedulePatch) async throws -> PlanningTask {
        do { return try await send("PATCH", "v1/tasks/\(taskID.uuidString)/schedule", body: ScheduleUpdate(version: version, patch)) }
        catch let error as APIError { throw ScheduleError(error) }
    }

    private static func queryDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
