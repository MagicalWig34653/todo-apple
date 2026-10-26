import Foundation

// DTOs mirror contracts/agents.yaml (main repository), section /v1/runner.

public enum JobState: String, Codable, Sendable {
    case queued, claimed, running
    case waitingForAnswer = "waiting_for_answer"
    case awaitingReview = "awaiting_review"
    case succeeded, failed, cancelled
}

public enum JobMode: String, Codable, Sendable { case clarify, implement }

public struct Checkpoint: Codable, Sendable, Equatable {
    public var contextRevision: Int
    public var sessionReference: String
    public var nextStep: String
    public init(contextRevision: Int, sessionReference: String, nextStep: String) {
        self.contextRevision = contextRevision
        self.sessionReference = sessionReference
        self.nextStep = String(nextStep.prefix(4000))
    }
}

public struct RunResult: Codable, Sendable, Equatable {
    public var summary: String
    public var references: [String]
    public var checks: [String]
    public var limitations: [String]
    public init(summary: String, references: [String] = [], checks: [String] = [], limitations: [String] = []) {
        self.summary = summary; self.references = references; self.checks = checks; self.limitations = limitations
    }
}

public struct Job: Codable, Sendable, Equatable {
    public var id: UUID
    public var taskID: UUID
    public var projectID: UUID
    public var bindingID: UUID
    public var requestedBy: UUID
    public var previousJobID: UUID?
    public var taskRevision: Int
    public var mode: JobMode
    public var scope: String
    public var state: JobState
    public var progress: String
    public var result: RunResult?
    public init(id: UUID = UUID(), taskID: UUID = UUID(), projectID: UUID = UUID(), bindingID: UUID,
                requestedBy: UUID = UUID(), previousJobID: UUID? = nil, taskRevision: Int = 1,
                mode: JobMode = .implement, scope: String, state: JobState = .queued,
                progress: String = "", result: RunResult? = nil) {
        self.id = id; self.taskID = taskID; self.projectID = projectID; self.bindingID = bindingID
        self.requestedBy = requestedBy; self.previousJobID = previousJobID; self.taskRevision = taskRevision
        self.mode = mode; self.scope = scope; self.state = state; self.progress = progress; self.result = result
    }
}

public struct Run: Codable, Sendable, Equatable {
    public var id: UUID
    public var job: Job
    public var generation: Int
    public var leaseUntil: Date
    public var endedAt: Date?
    public var checkpoint: Checkpoint?
    public init(id: UUID = UUID(), job: Job, generation: Int = 1, leaseUntil: Date,
                endedAt: Date? = nil, checkpoint: Checkpoint? = nil) {
        self.id = id; self.job = job; self.generation = generation; self.leaseUntil = leaseUntil
        self.endedAt = endedAt; self.checkpoint = checkpoint
    }
}

public struct Binding: Codable, Sendable, Equatable {
    public var id: UUID
    public var projectID: UUID
    public var deviceID: UUID
    public var repositoryKey: UUID
    public var label: String
    public init(id: UUID = UUID(), projectID: UUID = UUID(), deviceID: UUID = UUID(), repositoryKey: UUID, label: String) {
        self.id = id; self.projectID = projectID; self.deviceID = deviceID
        self.repositoryKey = repositoryKey; self.label = label
    }
}

public struct Question: Codable, Sendable, Equatable {
    public var id: UUID
    public var taskID: UUID
    public var prompt: String
    public var options: [String]
    public var answer: String?
    public var authorID: UUID?
    public init(id: UUID = UUID(), taskID: UUID = UUID(), prompt: String, options: [String] = [],
                answer: String? = nil, authorID: UUID? = nil) {
        self.id = id; self.taskID = taskID; self.prompt = prompt; self.options = options
        self.answer = answer; self.authorID = authorID
    }
}

public struct TaskInfo: Codable, Sendable, Equatable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var description: String
    public var status: String
    public var version: Int
    public init(id: UUID = UUID(), projectID: UUID = UUID(), title: String, description: String = "",
                status: String = "open", version: Int = 1) {
        self.id = id; self.projectID = projectID; self.title = title; self.description = description
        self.status = status; self.version = version
    }
}

public struct JobEvent: Codable, Sendable, Equatable {
    public var id: UUID
    public var runID: UUID?
    public var kind: String
    public var detail: String
    public var createdAt: Date
}

public struct JobDetail: Codable, Sendable, Equatable {
    public var job: Job
    public var task: TaskInfo
    public var questions: [Question]
    public var events: [JobEvent]
    public init(job: Job, task: TaskInfo, questions: [Question] = [], events: [JobEvent] = []) {
        self.job = job; self.task = task; self.questions = questions; self.events = events
    }
}

public struct DeviceToken: Codable, Sendable, Equatable {
    public var deviceID: UUID
    public var token: String
}

public enum ReconcileObservation: String, Codable, Sendable { case alive, paused, stopped }
