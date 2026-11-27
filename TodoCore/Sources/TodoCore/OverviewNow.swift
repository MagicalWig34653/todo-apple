import Foundation

// MARK: Übersicht "Jetzt" (contracts/session-status.yaml 1.1.0, GET /v1/overview/now in the main repository)
// What is happening right now across all readable projects. Reading is tolerant: missing or malformed fields drop out,
// a broken element never drops its siblings, and an unknown future field is ignored. Only the identity of an element
// (project id and name, task id, session name, build id) is required; an element without it is skipped.

private struct LooseKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Decodes one array element without failing the array: a bad element becomes `nil`.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

private extension KeyedDecodingContainer where K == LooseKey {
    func loose<T: Decodable>(_ name: String, as type: T.Type = T.self) -> T? { (try? decodeIfPresent(T.self, forKey: LooseKey(name))) ?? nil }
    func required<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T { try decode(T.self, forKey: LooseKey(name)) }
    /// Array that survives bad elements and a wrong type (then empty).
    func list<T: Decodable>(_ name: String, as type: T.Type = T.self) -> [T] {
        ((try? decodeIfPresent([Lossy<T>].self, forKey: LooseKey(name))) ?? nil)?.compactMap(\.value) ?? []
    }
}

public struct OverviewProgress: Decodable, Sendable, Equatable {
    public let note: String
    public let at: Date?

    public init(note: String, at: Date? = nil) { self.note = note; self.at = at }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LooseKey.self)
        note = try c.required("note")
        at = c.loose("at")
    }
}

public struct OverviewRunningTask: Decodable, Sendable, Equatable, Identifiable {
    public let taskID: UUID
    public let title: String
    public let worker: String?
    public let lastProgress: OverviewProgress?
    public let ageSeconds: Int?
    /// 0...100 or nil (missing or out of range).
    public let percent: Int?
    public var id: UUID { taskID }

    public init(taskID: UUID, title: String, worker: String? = nil, lastProgress: OverviewProgress? = nil, ageSeconds: Int? = nil, percent: Int? = nil) {
        self.taskID = taskID; self.title = title; self.worker = worker; self.lastProgress = lastProgress
        self.ageSeconds = ageSeconds; self.percent = percent.flatMap { (0...100).contains($0) ? $0 : nil }
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LooseKey.self)
        self.init(taskID: try c.required("taskID"), title: c.loose("title") ?? "", worker: c.loose("worker"),
                  lastProgress: c.loose("lastProgress"), ageSeconds: c.loose("ageSeconds"), percent: c.loose("percent"))
    }
}

public struct OverviewSession: Decodable, Sendable, Equatable, Identifiable {
    /// Silence after which a session counts as orphaned (contract: 30 minutes).
    public static let orphanedAfter: TimeInterval = 30 * 60
    /// Sessions older than this no longer count as activity (the server hides them too).
    public static let activeWithin: TimeInterval = 24 * 3600

    public let sessionName: String
    public let activity: String
    public let updatedAt: Date?
    public let ageSeconds: Int?
    public let orphaned: Bool?
    /// The server keys a session by person, project and name, so two people of a shared project can report the same name:
    /// `OverviewProject` numbers such repeats.
    public fileprivate(set) var id: String

    public init(sessionName: String, activity: String = "", updatedAt: Date? = nil, ageSeconds: Int? = nil, orphaned: Bool? = nil) {
        self.sessionName = sessionName; self.activity = activity; self.updatedAt = updatedAt; self.ageSeconds = ageSeconds; self.orphaned = orphaned
        self.id = sessionName
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LooseKey.self)
        self.init(sessionName: try c.required("sessionName"), activity: c.loose("activity") ?? "", updatedAt: c.loose("updatedAt"),
                  ageSeconds: c.loose("ageSeconds"), orphaned: c.loose("orphaned"))
    }

    /// Seconds since the last report: the server's age, else derived from `updatedAt`.
    public func age(at now: Date) -> TimeInterval? {
        if let ageSeconds { return TimeInterval(ageSeconds) }
        return updatedAt.map { max(0, now.timeIntervalSince($0)) }
    }

    /// The server flag wins; without it the age decides (more than 30 minutes without a report).
    public func isOrphaned(at now: Date) -> Bool {
        if orphaned == true { return true }
        if orphaned == false { return false }
        return (age(at: now) ?? 0) > Self.orphanedAfter
    }

    func isRecent(at now: Date) -> Bool { (age(at: now) ?? 0) < Self.activeWithin }
}

public struct OverviewJob: Decodable, Sendable, Equatable {
    public let jobID: UUID?
    public let taskID: UUID?
    public let state: String?
    public let mode: String?
    public let progress: String?

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LooseKey.self)
        jobID = c.loose("jobID"); taskID = c.loose("taskID"); state = c.loose("state"); mode = c.loose("mode"); progress = c.loose("progress")
    }
}

/// Build state (contract session-status 1.2.0). Unknown values from newer servers decode to nil, never to an error.
public enum BuildStatus: String, Codable, Sendable, Equatable, Hashable {
    case building, succeeded, failed

    /// 7 to 40 lowercase hex characters, else nil.
    static func validCommit(_ s: String?) -> String? {
        guard let s, (7...40).contains(s.count), s.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        return s
    }
}

public struct OverviewBuild: Decodable, Sendable, Equatable, Identifiable {
    /// Id of the build artifact (one screenshot), unique per entry, since session-status 1.5.0; nil from an older server.
    public let artifactID: UUID?
    public let taskID: UUID
    /// Shared by every screenshot of one build (per card and per project): never a list key, see `id`.
    public let buildID: String
    public let label: String?
    public let platform: String?
    public let createdAt: Date?
    /// 7 to 40 lowercase hex characters, else nil.
    public let commit: String?
    /// nil when absent or unknown: then no badge is shown.
    public let status: BuildStatus?
    /// List identity: the artifact id; from an old server (no `id`) the `buildID`, numbered by `OverviewProject` where it repeats.
    public fileprivate(set) var id: String

    public init(taskID: UUID, buildID: String, label: String? = nil, platform: String? = nil, createdAt: Date? = nil, commit: String? = nil,
                status: BuildStatus? = nil, artifactID: UUID? = nil) {
        self.artifactID = artifactID; self.id = artifactID?.uuidString ?? buildID
        self.taskID = taskID; self.buildID = buildID; self.label = label; self.platform = platform; self.createdAt = createdAt
        self.commit = BuildStatus.validCommit(commit)
        self.status = status
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LooseKey.self)
        self.init(taskID: try c.required("taskID"), buildID: try c.required("buildID"), label: c.loose("label"), platform: c.loose("platform"),
                  createdAt: c.loose("createdAt"), commit: c.loose("commit"), status: c.loose("status"), artifactID: c.loose("id"))
    }

    /// First 7 characters, shown monospaced.
    public var commitShort: String? { commit.map { String($0.prefix(7)) } }
}

/// An open question or a pending review.
public struct OverviewOpenItem: Decodable, Sendable, Equatable, Identifiable {
    public let id: UUID?
    public let taskID: UUID
    public let taskTitle: String
    public let text: String
    public let createdAt: Date?

    public init(id: UUID? = nil, taskID: UUID, taskTitle: String = "", text: String = "", createdAt: Date? = nil) {
        self.id = id; self.taskID = taskID; self.taskTitle = taskTitle; self.text = text; self.createdAt = createdAt
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LooseKey.self)
        self.init(id: c.loose("id"), taskID: try c.required("taskID"), taskTitle: c.loose("taskTitle") ?? "", text: c.loose("text") ?? "", createdAt: c.loose("createdAt"))
    }

    /// Stable list identity even if the server sent no item id.
    public var listID: String { id?.uuidString ?? "\(taskID.uuidString)-\(createdAt?.timeIntervalSince1970 ?? 0)" }
}

public struct OverviewEvent: Decodable, Sendable, Equatable {
    public let taskID: UUID?
    public let taskTitle: String
    public let kind: String
    public let actorType: String?
    public let createdAt: Date?

    public init(taskID: UUID? = nil, taskTitle: String = "", kind: String, actorType: String? = nil, createdAt: Date? = nil) {
        self.taskID = taskID; self.taskTitle = taskTitle; self.kind = kind; self.actorType = actorType; self.createdAt = createdAt
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LooseKey.self)
        self.init(taskID: c.loose("taskID"), taskTitle: c.loose("taskTitle") ?? "", kind: c.loose("kind") ?? "", actorType: c.loose("actorType"), createdAt: c.loose("createdAt"))
    }
}

public struct OverviewProject: Decodable, Sendable, Equatable, Identifiable {
    public let projectID: UUID
    public let projectName: String
    public let lastActivityAt: Date?
    public let runningTasks: [OverviewRunningTask]
    public let sessions: [OverviewSession]
    public let agentJobs: [OverviewJob]
    public let builds: [OverviewBuild]
    public let openQuestions: [OverviewOpenItem]
    public let pendingReviews: [OverviewOpenItem]
    public let recentActivity: [OverviewEvent]
    public var id: UUID { projectID }

    public init(projectID: UUID, projectName: String, lastActivityAt: Date? = nil, runningTasks: [OverviewRunningTask] = [], sessions: [OverviewSession] = [],
                agentJobs: [OverviewJob] = [], builds: [OverviewBuild] = [], openQuestions: [OverviewOpenItem] = [], pendingReviews: [OverviewOpenItem] = [],
                recentActivity: [OverviewEvent] = []) {
        self.projectID = projectID; self.projectName = projectName; self.lastActivityAt = lastActivityAt; self.runningTasks = runningTasks
        self.sessions = zip(uniqueKeys(sessions.map(\.id)), sessions).map { id, session in var s = session; s.id = id; return s }
        self.agentJobs = agentJobs
        self.builds = zip(uniqueKeys(builds.map(\.id)), builds).map { id, build in var b = build; b.id = id; return b }
        self.openQuestions = openQuestions
        self.pendingReviews = pendingReviews; self.recentActivity = recentActivity
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LooseKey.self)
        self.init(projectID: try c.required("projectID"), projectName: try c.required("projectName"), lastActivityAt: c.loose("lastActivityAt"),
                  runningTasks: c.list("runningTasks"), sessions: c.list("sessions"), agentJobs: c.list("agentJobs"), builds: c.list("builds"),
                  openQuestions: c.list("openQuestions"), pendingReviews: c.list("pendingReviews"), recentActivity: c.list("recentActivity"))
    }

    /// An open question or review: the project is never quiet.
    public var hasOpenItems: Bool { !openQuestions.isEmpty || !pendingReviews.isEmpty }
    public var openItemCount: Int { openQuestions.count + pendingReviews.count }
}

public struct OverviewNow: Decodable, Sendable, Equatable {
    public let serverTime: Date?
    public let projects: [OverviewProject]
    /// Block "Jetzt" (contract 1.4.0); nil for an older server, then only the project cards exist.
    public let now: NowBlock?

    public init(serverTime: Date? = nil, projects: [OverviewProject] = [], now: NowBlock? = nil) {
        self.serverTime = serverTime; self.projects = projects; self.now = now
    }
    public init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: LooseKey.self) else { self.init(); return }
        self.init(serverTime: c.loose("serverTime"), projects: c.list("projects"), now: c.loose("now"))
    }

    /// Nothing to show: no project with content and an empty (or missing) block.
    public var showsEmptyPage: Bool { projects.isEmpty && !(now?.hasContent ?? false) }
}

// MARK: Block "Jetzt" (contract session-status 1.4.0, field `now`)

public struct NowCounts: Sendable, Equatable {
    public let running: Int, waiting: Int, recentlyDone: Int, silent: Int
    public init(running: Int = 0, waiting: Int = 0, recentlyDone: Int = 0, silent: Int = 0) {
        self.running = running; self.waiting = waiting; self.recentlyDone = recentlyDone; self.silent = silent
    }
}

/// A running card or session (`running`, `silent`).
public struct NowActive: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Decodable, Sendable { case task, session }
    public let kind: Kind
    public let projectID: UUID
    public let projectName: String
    /// Only for a card.
    public let taskID: UUID?
    /// Card title or session name.
    public let title: String
    public let text: String
    public let worker: String?
    public let since: Date?
    public let lastSignAt: Date?
    public let ageSeconds: Int?
    public let dueAt: Date?
    /// 0...100 or nil (missing or out of range).
    public let percent: Int?
    /// A card is unique by its task; a session by project and name, which two people of a shared project can both use:
    /// `NowBlock` numbers such repeats.
    public fileprivate(set) var id: String

    public init(kind: Kind, projectID: UUID, projectName: String, taskID: UUID? = nil, title: String, text: String = "", worker: String? = nil,
                since: Date? = nil, lastSignAt: Date? = nil, ageSeconds: Int? = nil, dueAt: Date? = nil, percent: Int? = nil) {
        self.kind = kind; self.projectID = projectID; self.projectName = projectName; self.taskID = taskID; self.title = title; self.text = text
        self.id = "\(kind.rawValue):\(taskID?.uuidString ?? projectID.uuidString + title)"
        self.worker = worker; self.since = since; self.lastSignAt = lastSignAt; self.ageSeconds = ageSeconds; self.dueAt = dueAt
        self.percent = percent.flatMap { (0...100).contains($0) ? $0 : nil }
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LooseKey.self)
        self.init(kind: try c.required("kind"), projectID: try c.required("projectID"), projectName: try c.required("projectName"),
                  taskID: c.loose("taskID"), title: try c.required("title"), text: c.loose("text") ?? "", worker: c.loose("worker"),
                  since: c.loose("since"), lastSignAt: c.loose("lastSignAt"), ageSeconds: c.loose("ageSeconds"), dueAt: c.loose("dueAt"),
                  percent: c.loose("percent"))
    }

    /// A due date in the past (cards only).
    public func isOverdue(at now: Date) -> Bool { kind == .task && (dueAt.map { $0 < now } ?? false) }

    /// One list with every repeated id numbered (see `uniqueKeys`).
    fileprivate static func numbered(_ rows: [NowActive]) -> [NowActive] {
        zip(uniqueKeys(rows.map(\.id)), rows).map { id, row in var r = row; r.id = id; return r }
    }
}

/// An open question or a pending review (`waiting`).
public struct NowWaiting: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Decodable, Sendable { case question, review }
    public let kind: Kind
    public let id: UUID
    public let projectID: UUID
    public let projectName: String
    public let taskID: UUID
    public let taskTitle: String
    public let text: String
    public let createdAt: Date?
    public var isQuestion: Bool { kind == .question }

    public init(kind: Kind, id: UUID, projectID: UUID, projectName: String, taskID: UUID, taskTitle: String = "", text: String = "", createdAt: Date? = nil) {
        self.kind = kind; self.id = id; self.projectID = projectID; self.projectName = projectName; self.taskID = taskID
        self.taskTitle = taskTitle; self.text = text; self.createdAt = createdAt
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LooseKey.self)
        self.init(kind: try c.required("kind"), id: try c.required("id"), projectID: try c.required("projectID"), projectName: try c.required("projectName"),
                  taskID: try c.required("taskID"), taskTitle: c.loose("taskTitle") ?? "", text: c.loose("text") ?? "", createdAt: c.loose("createdAt"))
    }
}

/// A card done within the last 6 hours (`recentlyDone`).
public struct NowDone: Decodable, Sendable, Equatable, Identifiable {
    public let taskID: UUID
    public let title: String
    public let projectID: UUID
    public let projectName: String
    public let doneAt: Date?
    public var id: UUID { taskID }

    public init(taskID: UUID, title: String, projectID: UUID, projectName: String, doneAt: Date? = nil) {
        self.taskID = taskID; self.title = title; self.projectID = projectID; self.projectName = projectName; self.doneAt = doneAt
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LooseKey.self)
        self.init(taskID: try c.required("taskID"), title: c.loose("title") ?? "", projectID: try c.required("projectID"),
                  projectName: try c.required("projectName"), doneAt: c.loose("doneAt"))
    }
}

public struct NowBlock: Decodable, Sendable, Equatable {
    public let counts: NowCounts
    public let running: [NowActive]
    public let waiting: [NowWaiting]
    public let recentlyDone: [NowDone]
    /// Cards in progress and sessions without a sign of life for 30 minutes.
    public let silent: [NowActive]

    /// A count below the length of its list (lost element, older server) is raised to it, so the heading never undercounts.
    public init(counts: NowCounts? = nil, running: [NowActive] = [], waiting: [NowWaiting] = [], recentlyDone: [NowDone] = [], silent: [NowActive] = []) {
        self.running = NowActive.numbered(running); self.waiting = waiting; self.recentlyDone = recentlyDone; self.silent = NowActive.numbered(silent)
        let c = counts ?? NowCounts()
        self.counts = NowCounts(running: max(c.running, running.count), waiting: max(c.waiting, waiting.count),
                                recentlyDone: max(c.recentlyDone, recentlyDone.count), silent: max(c.silent, silent.count))
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LooseKey.self)
        var counts = NowCounts()
        if let k = try? c.nestedContainer(keyedBy: LooseKey.self, forKey: LooseKey("counts")) {
            counts = NowCounts(running: k.loose("running") ?? 0, waiting: k.loose("waiting") ?? 0,
                               recentlyDone: k.loose("recentlyDone") ?? 0, silent: k.loose("silent") ?? 0)
        }
        self.init(counts: counts, running: c.list("running"), waiting: c.list("waiting"), recentlyDone: c.list("recentlyDone"), silent: c.list("silent"))
    }

    /// Anything to show, silent entries included (they sit in the collapsed section).
    public var hasContent: Bool { counts.running + counts.waiting + counts.recentlyDone + counts.silent > 0 }
    /// Entries cut off by `limit` (compact): the server's count minus what came.
    public var hiddenRunning: Int { counts.running - running.count }
    public var hiddenWaiting: Int { counts.waiting - waiting.count }
    public var hiddenDone: Int { counts.recentlyDone - recentlyDone.count }
    public var hiddenSilent: Int { counts.silent - silent.count }
}

// MARK: Grouping

/// The projects of the overview in display order: waiting for the user (open question or review), active, quiet.
public struct OverviewGroups: Sendable, Equatable {
    /// Without a report for this long (and nothing running, nothing open) a project is quiet.
    public static let quietAfter: TimeInterval = 24 * 3600

    public let waiting: [OverviewProject]
    public let active: [OverviewProject]
    public let quiet: [OverviewProject]

    public var ordered: [OverviewProject] { waiting + active + quiet }
    public var isEmpty: Bool { waiting.isEmpty && active.isEmpty && quiet.isEmpty }

    /// Waiting and active projects start expanded, quiet ones collapsed.
    public func defaultExpanded(_ project: OverviewProject) -> Bool { !quiet.contains { $0.projectID == project.projectID } }
}

extension OverviewNow {
    /// Pure grouping and sorting. A project with an open question or review is never quiet; otherwise it is quiet only with
    /// no running card, no session younger than 24 hours and last activity more than 24 hours ago. Newest activity first.
    public func grouped(at now: Date) -> OverviewGroups {
        func newestFirst(_ a: OverviewProject, _ b: OverviewProject) -> Bool {
            switch (a.lastActivityAt, b.lastActivityAt) {
            case let (x?, y?) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.projectName.localizedCaseInsensitiveCompare(b.projectName) == .orderedAscending
            }
        }
        func isActive(_ p: OverviewProject) -> Bool {
            if !p.runningTasks.isEmpty { return true }
            if p.sessions.contains(where: { $0.isRecent(at: now) }) { return true }
            if let last = p.lastActivityAt, last >= now.addingTimeInterval(-OverviewGroups.quietAfter) { return true }
            return false
        }
        let waiting = projects.filter(\.hasOpenItems).sorted(by: newestFirst)
        let rest = projects.filter { !$0.hasOpenItems }
        return OverviewGroups(waiting: waiting, active: rest.filter(isActive).sorted(by: newestFirst),
                              quiet: rest.filter { !isActive($0) }.sorted(by: newestFirst))
    }
}

// MARK: API

public enum OverviewFetchResult: Sendable, Equatable {
    case loaded(OverviewNow)
    /// The server answered 404: an older backend without the overview.
    case unsupported
}

extension APIClient {
    /// `GET /v1/overview/now`. A 404 (old server) is an own result, not an error; other errors are thrown.
    /// `compact` (since 1.4.0) returns only `serverTime` and `now`, texts cut to 140 characters; `limit` (1...50) caps each list of `now`.
    public func fetchOverviewNow(compact: Bool = false, limit: Int? = nil) async throws -> OverviewFetchResult {
        var query: [URLQueryItem] = []
        if compact {
            query.append(URLQueryItem(name: "compact", value: "true"))
            if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        }
        do { return .loaded(try await send("GET", "v1/overview/now", query: query)) }
        catch APIError.notFound { return .unsupported }
    }
}
