import Foundation

// MARK: Command center (ADR 0014, contracts/command-center.yaml in the main repository)
// Aggregated kanban/list overview of agent work, questions, reviews, progress and build screenshots.
// The server computes everything at request time; there is no sync feed, clients refetch on foreground / pull-to-refresh.

/// Fixed lane keys in display order.
public enum CommandLane: String, Codable, Sendable, CaseIterable {
    case running, question, review, ready, blocked, done
}

public struct CommandProgress: Codable, Sendable, Equatable {
    /// 0...100
    public let percent: Int
    /// `status` | `subtasks` | `criteria` | `agent` | `none`
    public let source: String
    public let subtasksDone: Int
    public let subtasksTotal: Int
    public let criteriaDone: Int
    public let criteriaTotal: Int

    public init(percent: Int = 0, source: String = "none", subtasksDone: Int = 0, subtasksTotal: Int = 0, criteriaDone: Int = 0, criteriaTotal: Int = 0) {
        self.percent = percent; self.source = source
        self.subtasksDone = subtasksDone; self.subtasksTotal = subtasksTotal
        self.criteriaDone = criteriaDone; self.criteriaTotal = criteriaTotal
    }
}

public struct CommandCardTask: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let status: String
    public let version: Int
    public let columnID: UUID?
    public let columnName: String?
    public let createdAt: Date?
    public let updatedAt: Date?
}

public struct CommandCardProject: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let color: String?
    public let parentID: UUID?
}

public struct CommandCardAgent: Codable, Sendable, Equatable {
    public let claimedLabel: String?
    public let claimedAt: Date?
    public let jobID: UUID?
    /// Runner job state; only present for the project owner.
    public let jobState: String?
    public let jobProgress: String?
    public let runID: UUID?
    public let checkpointNextStep: String?
}

public struct CommandCardUpdate: Codable, Sendable, Equatable {
    /// `note` | `checkpoint` | `job_progress`
    public let kind: String
    public let text: String
    public let at: Date?
    public let actorLabel: String?
}

public struct QuestionBrief: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public let prompt: String
    public let options: [String]
    public let blocking: Bool
    public let askedByType: String
    public let askedByLabel: String?
    public let createdAt: Date?
}

public struct ReviewBrief: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public let summary: String
    public let requestedByType: String
    public let requestedByLabel: String?
    public let reviewerID: UUID?
    public let agentJobID: UUID?
    public let createdAt: Date?
}

public struct SubtaskBrief: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public let title: String
    public let status: String
    public let lane: String
    public let progressPercent: Int
}

/// Build screenshot / artifact (attachment role `result` + build metadata).
public struct BuildArtifact: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public let attachmentID: UUID
    public let taskID: UUID
    public let buildID: String
    public let label: String?
    public let platform: String?
    public let filename: String
    public let mediaType: String
    public let size: Int
    /// Server-relative path of the authenticated preview route (for example `/v1/attachments/{id}/preview`).
    public let previewURL: String
    public let createdAt: Date?
}

public struct CommandCard: Codable, Sendable, Equatable, Identifiable {
    public let task: CommandCardTask
    public let project: CommandCardProject
    public let kind: String
    public let isFeature: Bool
    public let parentTaskID: UUID?
    /// Raw lane key; unknown keys from newer servers stay readable.
    public let lane: String
    public let progress: CommandProgress
    public let agent: CommandCardAgent?
    public let openQuestionCount: Int
    public let questions: [QuestionBrief]
    public let pendingReview: ReviewBrief?
    public let blockedReason: String?
    public let blockedBy: [UUID]
    public let latestUpdate: CommandCardUpdate?
    public let builds: [BuildArtifact]
    public let buildCount: Int
    public let nextDue: Date?
    public let priority: Int
    public let subtasks: [SubtaskBrief]

    public var id: UUID { task.id }
}

public struct CommandLaneColumn: Codable, Sendable, Equatable, Identifiable {
    public let key: String
    public let title: String
    public let count: Int
    public let truncated: Bool
    public let cards: [CommandCard]

    public var id: String { key }
    public var lane: CommandLane? { CommandLane(rawValue: key) }
}

public struct CommandSummary: Codable, Sendable, Equatable {
    public let running: Int
    public let question: Int
    public let review: Int
    public let ready: Int
    public let blocked: Int
    public let done: Int
    public let backlog: Int
    public let openQuestions: Int
    public let pendingReviews: Int
    public let features: Int
    public let activeAgents: Int

    public init(running: Int = 0, question: Int = 0, review: Int = 0, ready: Int = 0, blocked: Int = 0, done: Int = 0, backlog: Int = 0,
                openQuestions: Int = 0, pendingReviews: Int = 0, features: Int = 0, activeAgents: Int = 0) {
        self.running = running; self.question = question; self.review = review; self.ready = ready; self.blocked = blocked
        self.done = done; self.backlog = backlog; self.openQuestions = openQuestions; self.pendingReviews = pendingReviews
        self.features = features; self.activeAgents = activeAgents
    }

    public func count(for lane: CommandLane) -> Int {
        switch lane {
        case .running: running
        case .question: question
        case .review: review
        case .ready: ready
        case .blocked: blocked
        case .done: done
        }
    }
}

public struct CommandUpdate: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let taskID: UUID
    public let taskTitle: String
    public let projectID: UUID
    public let projectName: String
    /// For example `progress.posted`, `question.asked`, `question.answered`, `review.requested`; unknown kinds stay displayable.
    public let kind: String
    public let actorType: String
    public let actorID: UUID
    public let actorName: String?
    public let subjectID: UUID?
    public let text: String?
    public let createdAt: Date?
}

public struct BuildGroup: Codable, Sendable, Equatable, Identifiable {
    public let buildID: String
    public let label: String?
    public let platform: String?
    public let taskIDs: [UUID]
    public let createdAt: Date?
    public let items: [BuildArtifact]

    public var id: String { buildID }
}

public struct CommandCenter: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let scope: String
    public let projectID: UUID?
    public let view: String
    public let summary: CommandSummary
    /// Kanban view only.
    public let lanes: [CommandLaneColumn]?
    /// List view only.
    public let items: [CommandCard]?
    public let total: Int?
    public let updates: [CommandUpdate]
    public let builds: [BuildGroup]
}

/// Options for `GET /v1/command-center`. `projectID == nil` means account scope.
public struct CommandCenterOptions: Sendable, Equatable {
    public enum View: String, Sendable { case kanban, list }
    public enum Sort: String, Sendable, CaseIterable { case attention, updated, due, progress, title }

    public var projectID: UUID?
    public var includeSubprojects = true
    public var view: View = .kanban
    public var lanes: [CommandLane]? = nil
    /// `task` or `feature`.
    public var kind: String? = nil
    public var hasQuestion: Bool? = nil
    public var includeSubtasks = false
    public var sort: Sort = .attention
    public var doneWithinDays: Int? = nil
    public var laneLimit: Int? = nil
    public var updatesLimit: Int? = nil
    public var limit: Int? = nil
    public var offset: Int? = nil

    public init(projectID: UUID? = nil, view: View = .kanban) {
        self.projectID = projectID; self.view = view
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        items.append(.init(name: "scope", value: projectID == nil ? "account" : "project"))
        if let projectID {
            items.append(.init(name: "projectID", value: projectID.uuidString.lowercased()))
            if !includeSubprojects { items.append(.init(name: "includeSubprojects", value: "false")) }
        }
        items.append(.init(name: "view", value: view.rawValue))
        if let lanes, !lanes.isEmpty { items.append(.init(name: "lane", value: lanes.map(\.rawValue).joined(separator: ","))) }
        if let kind { items.append(.init(name: "kind", value: kind)) }
        if let hasQuestion { items.append(.init(name: "hasQuestion", value: hasQuestion ? "true" : "false")) }
        if includeSubtasks { items.append(.init(name: "includeSubtasks", value: "true")) }
        if sort != .attention { items.append(.init(name: "sort", value: sort.rawValue)) }
        if let doneWithinDays { items.append(.init(name: "doneWithinDays", value: String(doneWithinDays))) }
        if let laneLimit { items.append(.init(name: "laneLimit", value: String(laneLimit))) }
        if let updatesLimit { items.append(.init(name: "updatesLimit", value: String(updatesLimit))) }
        if let limit { items.append(.init(name: "limit", value: String(limit))) }
        if let offset { items.append(.init(name: "offset", value: String(offset))) }
        return items
    }
}

// MARK: Questions, reviews, context, brief

public struct Question: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public let taskID: UUID
    public let taskTitle: String?
    public let projectID: UUID?
    public let projectName: String?
    /// `Person`, `Integration` or `Run`.
    public let askedByType: String
    public let askedByID: UUID?
    public let askedByLabel: String?
    public let askedByName: String?
    public let prompt: String
    public let options: [String]
    public let blocking: Bool
    /// `open`, `answered` or `withdrawn`.
    public let state: String
    public let answer: String?
    public let answeredBy: UUID?
    public let answeredVia: String?
    public let answeredAt: Date?
    public let createdAt: Date?
    public let agentQuestionID: UUID?
    public let version: Int

    public var isOpen: Bool { state == "open" }
    /// Name to show for the asker: label of the agent, else the person's name.
    public var askerDisplay: String? { askedByLabel ?? askedByName }
}

public struct Review: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public let taskID: UUID
    public let taskTitle: String?
    public let projectID: UUID?
    public let projectName: String?
    /// `pending`, `accepted`, `changes_requested` or `withdrawn`.
    public let state: String
    public let requestedByType: String
    public let requestedByID: UUID?
    public let requestedByLabel: String?
    public let reviewerID: UUID?
    public let summary: String
    public let decidedBy: UUID?
    public let decidedAt: Date?
    public let decisionNote: String?
    public let agentJobID: UUID?
    public let createdAt: Date?
    public let version: Int

    public var isPending: Bool { state == "pending" }
}

public struct ProgressNote: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let taskID: UUID
    public let actorType: String
    public let actorID: UUID
    public let actorLabel: String?
    public let note: String
    public let percent: Int?
    public let createdAt: Date?
}

public struct TaskCriterion: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let taskID: UUID
    public let text: String
    public let completed: Bool
    public let version: Int
}

public struct TaskWorkflow: Codable, Sendable, Equatable {
    public let taskID: UUID
    public let kind: String
    public let isFeature: Bool
    public let parentTaskID: UUID?
    public let blockedReason: String?
    public let claimedByType: String?
    public let claimedByID: UUID?
    public let claimedLabel: String?
    public let claimedAt: Date?
}

public struct TaskContext: Codable, Sendable, Equatable {
    public let task: TodoTask
    public let projectID: UUID
    public let workflow: TaskWorkflow
    public let progress: CommandProgress
    public let progressNotes: [ProgressNote]
    public let criteria: [TaskCriterion]
    public let subtasks: [TodoTask]
    public let comments: [Comment]
    public let questions: [Question]
    public let review: Review?
    public let builds: [BuildArtifact]
}

public struct AgentBrief: Codable, Sendable, Equatable {
    public let projectID: UUID
    public let text: String
    /// 0 = never written.
    public let version: Int
    public let updatedAt: Date?
}

public enum QuestionState: String, Sendable { case open, answered, all }
public enum ReviewState: String, Sendable { case pending, accepted, changesRequested = "changes_requested", withdrawn, all }
public enum ReviewDecision: String, Sendable { case accept, requestChanges = "request_changes" }

struct AnswerBody: Encodable { let answer: String }
struct ReviewDecisionBody: Encodable { let decision: String; let note: String? }
struct AgentBriefBody: Encodable { let text: String; let version: Int }

extension APIClient {
    /// Aggregated command center. Throws `APIError.notFound` on servers without it (or for an invisible project).
    public func commandCenter(_ options: CommandCenterOptions = .init()) async throws -> CommandCenter {
        try await send("GET", "v1/command-center", query: options.queryItems)
    }

    /// Questions across the account or one project (`projectID`), newest first as the server orders them.
    public func questions(projectID: UUID? = nil, taskID: UUID? = nil, state: QuestionState = .open, includeSubprojects: Bool = true, limit: Int? = nil) async throws -> [Question] {
        var query: [URLQueryItem] = [.init(name: "state", value: state.rawValue)]
        if let projectID { query.append(.init(name: "projectID", value: projectID.uuidString.lowercased())) }
        if let taskID { query.append(.init(name: "taskID", value: taskID.uuidString.lowercased())) }
        // Sent explicitly: the server's default for an absent flag did not include sub-projects when tested live.
        query.append(.init(name: "includeSubprojects", value: includeSubprojects ? "true" : "false"))
        if let limit { query.append(.init(name: "limit", value: String(limit))) }
        return try await send("GET", "v1/questions", query: query)
    }

    /// Answers a question. 400 `invalid_answer_option` if options exist and the text is not one; 409 `question_already_answered`.
    public func answerQuestion(_ id: UUID, answer: String) async throws -> Question {
        try await send("POST", "v1/questions/\(id.uuidString.lowercased())/answer", body: AnswerBody(answer: answer))
    }

    public func reviews(projectID: UUID? = nil, state: ReviewState = .pending, includeSubprojects: Bool = true, limit: Int? = nil) async throws -> [Review] {
        var query: [URLQueryItem] = [.init(name: "state", value: state.rawValue)]
        if let projectID { query.append(.init(name: "projectID", value: projectID.uuidString.lowercased())) }
        // Sent explicitly: the server's default for an absent flag did not include sub-projects when tested live.
        query.append(.init(name: "includeSubprojects", value: includeSubprojects ? "true" : "false"))
        if let limit { query.append(.init(name: "limit", value: String(limit))) }
        return try await send("GET", "v1/reviews", query: query)
    }

    /// Accepts or sends back the pending review of a task. 409 `no_pending_review`.
    public func decideReview(taskID: UUID, decision: ReviewDecision, note: String? = nil) async throws -> Review {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await send("POST", "v1/tasks/\(taskID.uuidString.lowercased())/review/decision",
            body: ReviewDecisionBody(decision: decision.rawValue, note: (trimmed?.isEmpty ?? true) ? nil : trimmed))
    }

    public func taskContext(_ id: UUID) async throws -> TaskContext {
        try await send("GET", "v1/tasks/\(id.uuidString.lowercased())/context")
    }

    public func agentBrief(projectID: UUID) async throws -> AgentBrief {
        try await send("GET", "v1/projects/\(projectID.uuidString.lowercased())/agent-brief")
    }

    /// Writes the brief (needs `manage`). `version` is the version last read (0 = new); 409 `version_conflict` => `.versionConflict`.
    public func saveAgentBrief(projectID: UUID, text: String, version: Int) async throws -> AgentBrief {
        try await send("PUT", "v1/projects/\(projectID.uuidString.lowercased())/agent-brief", body: AgentBriefBody(text: text, version: version))
    }

    /// Creates the default agent columns (Backlog, Bereit, In Arbeit, Frage offen, Review, Erledigt).
    public func applyAgentWorkflowColumns(projectID: UUID) async throws -> [ProjectColumn] {
        try await applyColumnTemplate(projectID: projectID, source: "agent_workflow")
    }

    /// Absolute URL for a server-relative `previewURL` of a build artifact (same host as the API).
    public func resolvedURL(path: String) -> URL? {
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
}

struct RegisterBuildBody: Encodable { let attachmentID: UUID; let buildID: String; let label: String?; let platform: String? }
struct ClaimBody: Encodable { let agentName: String?; let takeOver: Bool? }
struct QuestionBody: Encodable { let prompt: String; let options: [String]?; let blocking: Bool?; let agentName: String? }
struct ProgressBody: Encodable { let note: String; let percent: Int? }
struct ReviewRequestBody: Encodable { let summary: String; let agentName: String? }

/// Agent-side calls. The apps do not need them in the UI (agents use MCP), but integration tests and demo seeding do.
extension APIClient {
    /// Registers a completed `result` attachment as a build screenshot.
    public func registerBuild(attachmentID: UUID, buildID: String, label: String? = nil, platform: String? = nil) async throws -> BuildArtifact {
        try await send("POST", "v1/builds", body: RegisterBuildBody(attachmentID: attachmentID, buildID: buildID, label: label, platform: platform))
    }

    public func claimTask(_ id: UUID, agentName: String? = nil, takeOver: Bool? = nil) async throws -> TaskContext {
        try await send("POST", "v1/tasks/\(id.uuidString.lowercased())/claim", body: ClaimBody(agentName: agentName, takeOver: takeOver))
    }

    public func askQuestion(taskID: UUID, prompt: String, options: [String]? = nil, blocking: Bool? = nil, agentName: String? = nil) async throws -> Question {
        try await send("POST", "v1/tasks/\(taskID.uuidString.lowercased())/questions", body: QuestionBody(prompt: prompt, options: options, blocking: blocking, agentName: agentName))
    }

    public func postProgressNote(taskID: UUID, note: String, percent: Int? = nil) async throws -> ProgressNote {
        try await send("POST", "v1/tasks/\(taskID.uuidString.lowercased())/progress-notes", body: ProgressBody(note: note, percent: percent))
    }

    public func requestReview(taskID: UUID, summary: String, agentName: String? = nil) async throws -> Review {
        try await send("POST", "v1/tasks/\(taskID.uuidString.lowercased())/review", body: ReviewRequestBody(summary: summary, agentName: agentName))
    }

    /// `parentTaskID`: sets the parent (subtask); `blockedReason`: sets a free blocking reason. Only provided values are sent.
    public func setTaskStructure(_ id: UUID, kind: String? = nil, parentTaskID: UUID? = nil, blockedReason: String? = nil) async throws {
        struct Body: Encodable { let kind: String?; let parentTaskID: UUID?; let blockedReason: String? }
        let _: TaskWorkflow = try await send("PUT", "v1/tasks/\(id.uuidString.lowercased())/structure", body: Body(kind: kind, parentTaskID: parentTaskID, blockedReason: blockedReason))
    }
}
