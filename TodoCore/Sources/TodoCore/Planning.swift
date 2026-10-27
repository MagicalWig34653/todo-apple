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

/// Planning data of a task. `PUT` replaces all of it, so omitted optionals are cleared on the server.
public struct PlanningData: Codable, Sendable, Equatable {
    public var dueAt: Date?
    public var plannedAt: Date?
    /// 0 (none) to 3 (high).
    public var priority: Int
    public var recurrence: RecurrenceRule?
    public var reminders: [Date]

    public init(dueAt: Date? = nil, plannedAt: Date? = nil, priority: Int = 0, recurrence: RecurrenceRule? = nil, reminders: [Date] = []) {
        self.dueAt = dueAt
        self.plannedAt = plannedAt
        self.priority = priority
        self.recurrence = recurrence
        self.reminders = reminders
    }

    // Explicit keys so that `null` is sent for cleared dates (PUT semantics: absent also clears, null is explicit).
    enum CodingKeys: String, CodingKey { case dueAt, plannedAt, priority, recurrence, reminders }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dueAt, forKey: .dueAt)
        try c.encode(plannedAt, forKey: .plannedAt)
        try c.encode(priority, forKey: .priority)
        try c.encode(recurrence, forKey: .recurrence)
        try c.encode(reminders, forKey: .reminders)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        plannedAt = try c.decodeIfPresent(Date.self, forKey: .plannedAt)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        recurrence = try c.decodeIfPresent(RecurrenceRule.self, forKey: .recurrence)
        reminders = try c.decodeIfPresent([Date].self, forKey: .reminders) ?? []
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
