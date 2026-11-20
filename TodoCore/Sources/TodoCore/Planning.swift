import Foundation

// MARK: Planning (contracts/planning-ext.yaml)

public struct RecurrenceRule: Codable, Sendable, Equatable {
    public enum Frequency: String, Codable, Sendable, CaseIterable { case daily, weekly, monthly }
    public var frequency: Frequency
    public var interval: Int
    public var timeZone: String
    public var until: Date?

    public init(frequency: Frequency, interval: Int = 1, timeZone: String = TimeZone.current.identifier, until: Date? = nil) {
        self.frequency = frequency
        self.interval = interval
        self.timeZone = timeZone
        self.until = until
    }
}

/// Planning data of a task. `PUT` replaces all of it, so omitted optionals are cleared on the server, with two
/// exceptions since contracts planning-ext 1.1.0 / sync 1.5.0: `plannedMinutes` and `plannedAllDay` are adopted only if
/// the key is in the body (absent keeps the stored value). The calendar fields are additive and tolerant: an older server
/// sends none of them, the defaults apply, and an edit that carries them back (loaded planning edited in place) never
/// loses them.
public struct PlanningData: Codable, Sendable, Equatable {
    public var dueAt: Date?
    /// Planned start (ADR 0033); for an all-day card the start of the day.
    public var plannedAt: Date?
    /// 0 (none) to 3 (high).
    public var priority: Int
    public var recurrence: RecurrenceRule?
    public var reminders: [Date]
    /// Duration in minutes (5 to 1440); nil = none, shown as 30 minutes. Calendar, contract 1.1.0.
    public var plannedMinutes: Int?
    /// All day, no time of day. Calendar, contract 1.1.0.
    public var plannedAllDay: Bool
    /// The guard may hand the card to the runner at the planned start (one-time permission, ADR 0033 stage C). Read-only
    /// here: it is only writable through `PUT /v1/tasks/{id}/auto-start`, so it is never part of a planning body.
    public var autoStart: Bool
    /// When the guard handed the card over (server clock), else nil. Read-only.
    public var autoStartedAt: Date?

    public init(
        dueAt: Date? = nil, plannedAt: Date? = nil, priority: Int = 0, recurrence: RecurrenceRule? = nil, reminders: [Date] = [],
        plannedMinutes: Int? = nil, plannedAllDay: Bool = false, autoStart: Bool = false, autoStartedAt: Date? = nil
    ) {
        self.dueAt = dueAt
        self.plannedAt = plannedAt
        self.priority = priority
        self.recurrence = recurrence
        self.reminders = reminders
        self.plannedMinutes = plannedMinutes
        self.plannedAllDay = plannedAllDay
        self.autoStart = autoStart
        self.autoStartedAt = autoStartedAt
    }

    // Explicit keys so that `null` is sent for cleared dates (PUT semantics: absent also clears, null is explicit).
    enum CodingKeys: String, CodingKey { case dueAt, plannedAt, priority, recurrence, reminders, plannedMinutes, plannedAllDay, autoStart, autoStartedAt }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dueAt, forKey: .dueAt)
        try c.encode(plannedAt, forKey: .plannedAt)
        try c.encode(priority, forKey: .priority)
        try c.encode(recurrence, forKey: .recurrence)
        try c.encode(reminders, forKey: .reminders)
        // Absent = the server keeps its value. Never `null` from here: that would clear a duration set elsewhere.
        try c.encodeIfPresent(plannedMinutes, forKey: .plannedMinutes)
        try c.encode(plannedAllDay, forKey: .plannedAllDay)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        plannedAt = try c.decodeIfPresent(Date.self, forKey: .plannedAt)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        recurrence = try c.decodeIfPresent(RecurrenceRule.self, forKey: .recurrence)
        reminders = try c.decodeIfPresent([Date].self, forKey: .reminders) ?? []
        plannedMinutes = try c.decodeIfPresent(Int.self, forKey: .plannedMinutes)
        plannedAllDay = try c.decodeIfPresent(Bool.self, forKey: .plannedAllDay) ?? false
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        autoStartedAt = try c.decodeIfPresent(Date.self, forKey: .autoStartedAt)
    }
}

/// A task together with its planning data (wire: planning data fields next to `task` and `position`).
public struct PlanningTask: Codable, Sendable, Equatable, Identifiable {
    public let task: TodoTask
    public let position: Int
    public let planning: PlanningData
    public var id: UUID { task.id }

    public init(task: TodoTask, position: Int = 0, planning: PlanningData = PlanningData()) {
        self.task = task
        self.position = position
        self.planning = planning
    }

    private enum CodingKeys: String, CodingKey { case task, position }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        task = try c.decode(TodoTask.self, forKey: .task)
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        planning = try PlanningData(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(task, forKey: .task)
        try c.encode(position, forKey: .position)
        try planning.encode(to: encoder)
        // The task shape (a server answer) also carries the read-only auto-start state, unlike a planning request body.
        var extra = encoder.container(keyedBy: PlanningData.CodingKeys.self)
        try extra.encode(planning.autoStart, forKey: .autoStart)
        try extra.encodeIfPresent(planning.autoStartedAt, forKey: .autoStartedAt)
    }
}

extension APIClient {
    public func planning(taskID: UUID) async throws -> PlanningTask {
        try await send("GET", "v1/planning/tasks/\(taskID.uuidString)")
    }

    /// Replaces all planning data of the task.
    public func setPlanning(taskID: UUID, _ data: PlanningData) async throws -> PlanningTask {
        try await send("PUT", "v1/planning/tasks/\(taskID.uuidString)", body: data)
    }

    /// Open tasks due in the current calendar day of `timeZone`.
    public func today(timeZone: TimeZone = .current) async throws -> [PlanningTask] {
        try await send("GET", "v1/planning/today", query: [.init(name: "timeZone", value: timeZone.identifier)])
    }

    /// Tasks due from the next calendar day on.
    public func upcoming(timeZone: TimeZone = .current) async throws -> [PlanningTask] {
        try await send("GET", "v1/planning/upcoming", query: [.init(name: "timeZone", value: timeZone.identifier)])
    }

    /// Unfinished, unblocked tasks by priority then due date.
    public func upNext(timeZone: TimeZone = .current) async throws -> [PlanningTask] {
        try await send("GET", "v1/planning/up-next", query: [.init(name: "timeZone", value: timeZone.identifier)])
    }
}
