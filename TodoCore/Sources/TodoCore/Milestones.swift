import Foundation

// MARK: Dependencies and milestones, read only (contracts/planning-ext.yaml)

public struct Milestone: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public let title: String
    public let dueAt: Date?

    public init(id: UUID, projectID: UUID, title: String, dueAt: Date? = nil) {
        self.id = id; self.projectID = projectID; self.title = title; self.dueAt = dueAt
    }
}

/// A milestone with its visible tasks (from the project and its sub-projects).
public struct MilestoneWithTasks: Codable, Sendable, Equatable, Identifiable {
    public let milestone: Milestone
    public let tasks: [TodoTask]
    public var id: UUID { milestone.id }
    public var doneCount: Int { tasks.filter(\.isDone).count }

    public init(milestone: Milestone, tasks: [TodoTask]) { self.milestone = milestone; self.tasks = tasks }
}

extension Array where Element == MilestoneWithTasks {
    /// The milestone the task belongs to (a task has at most one).
    public func milestone(of taskID: UUID) -> MilestoneWithTasks? {
        first { $0.tasks.contains { $0.id == taskID } }
    }
}

extension APIClient {
    /// Visible prerequisites of the task (hidden ones are left out by the server).
    public func dependencies(taskID: UUID) async throws -> [TodoTask] {
        try await send("GET", "v1/planning/tasks/\(taskID.uuidString)/dependencies")
    }

    public func milestones(projectID: UUID) async throws -> [MilestoneWithTasks] {
        try await send("GET", "v1/planning/milestones", query: [.init(name: "projectID", value: projectID.uuidString)])
    }
}
