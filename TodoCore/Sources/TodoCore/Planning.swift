import Foundation

// MARK: Planning (contracts/planning-ext.yaml)

/// `PUT` replaces the whole rule, so everything the server sent goes back to it: fields this build does not know are kept
/// in `unknownFields` (contract planning-ext 1.3.0, card A18F3FF7). nil fields are not sent.
public struct RecurrenceRule: Codable, Sendable, Equatable {
    public enum Frequency: String, Codable, Sendable, CaseIterable { case daily, weekly, monthly }

    /// What the next date counts from. Not an enum: a value from a newer server must survive a round trip.
    public struct Basis: RawRepresentable, Codable, Sendable, Hashable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let due = Basis(rawValue: "due")
        public static let completion = Basis(rawValue: "completion")
    }

    public var frequency: Frequency
    public var interval: Int
    public var timeZone: String
    public var until: Date?
    /// ISO weekdays, 1 = Monday ... 7 = Sunday; weekly rules only.
    public var weekdays: [Int]?
    /// nil = `due`.
    public var basis: Basis?
    /// 1 ... 31, short months take their last day; monthly rules only.
    public var monthDay: Int?
    public var unknownFields: [String: JSONValue]

    public init(
        frequency: Frequency, interval: Int = 1, timeZone: String = TimeZone.current.identifier, until: Date? = nil,
        weekdays: [Int]? = nil, basis: Basis? = nil, monthDay: Int? = nil, unknownFields: [String: JSONValue] = [:]
    ) {
        self.frequency = frequency
        self.interval = interval
        self.timeZone = timeZone
        self.until = until
        self.weekdays = weekdays
        self.basis = basis
        self.monthDay = monthDay
        self.unknownFields = unknownFields
    }

    /// The rule after another frequency was picked: what still fits stays. The interval counted the old unit and resets.
    public func changing(frequency new: Frequency) -> RecurrenceRule {
        guard new != frequency else { return self }
        var rule = self
        rule.frequency = new
        rule.interval = 1
        if new != .weekly { rule.weekdays = nil }
        if new != .monthly { rule.monthDay = nil }
        return rule
    }

    /// Switches one weekday of a weekly rule; the list stays sorted and is never empty.
    public mutating func toggle(weekday: Int) {
        guard frequency == .weekly, (1...7).contains(weekday) else { return }
        var days = Set(weekdays ?? [])
        if days.remove(weekday) == nil { days.insert(weekday) }
        weekdays = days.isEmpty ? nil : days.sorted()
    }

    /// `due` is the default and is not sent, so plain rules stay as they were.
    public mutating func set(basis new: Basis) { basis = new == .due ? nil : new }

    /// nil = the day follows the due date. Values outside 1 ... 31 are ignored.
    public mutating func set(monthDay new: Int?) {
        guard frequency == .monthly else { return }
        if let new, !(1...31).contains(new) { return }
        monthDay = new
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case frequency, interval, timeZone, until, weekdays, basis, monthDay }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try c.decode(Frequency.self, forKey: .frequency)
        interval = try c.decode(Int.self, forKey: .interval)
        timeZone = try c.decode(String.self, forKey: .timeZone)
        until = try c.decodeIfPresent(Date.self, forKey: .until)
        weekdays = try c.decodeIfPresent([Int].self, forKey: .weekdays)
        basis = try c.decodeIfPresent(Basis.self, forKey: .basis)
        monthDay = try c.decodeIfPresent(Int.self, forKey: .monthDay)
        let all = try decoder.container(keyedBy: AnyKey.self)
        var unknown: [String: JSONValue] = [:]
        for key in all.allKeys where CodingKeys(stringValue: key.stringValue) == nil {
            unknown[key.stringValue] = try all.decode(JSONValue.self, forKey: key)
        }
        unknownFields = unknown
    }

    public func encode(to encoder: any Encoder) throws {
        var extra = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in unknownFields where CodingKeys(stringValue: key) == nil {
            try extra.encode(value, forKey: AnyKey(stringValue: key))
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(frequency, forKey: .frequency)
        try c.encode(interval, forKey: .interval)
        try c.encode(timeZone, forKey: .timeZone)
        try c.encodeIfPresent(until, forKey: .until)
        try c.encodeIfPresent(weekdays, forKey: .weekdays)
        try c.encodeIfPresent(basis, forKey: .basis)
        try c.encodeIfPresent(monthDay, forKey: .monthDay)
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
