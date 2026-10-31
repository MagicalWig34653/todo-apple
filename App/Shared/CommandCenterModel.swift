import SwiftUI
import TodoCore

/// State of one command-center screen: the whole account (`projectID == nil`) or one project including sub-projects.
/// The aggregate is computed by the server at request time (no sync feed), so the screen refetches on appear,
/// when the app returns to the foreground and on pull-to-refresh.
@MainActor @Observable
final class CommandCenterModel {
    enum Mode: String { case kanban, list }
    enum Section: String, CaseIterable { case overview, updates, questions }

    let projectID: UUID?
    private(set) var data: CommandCenter?
    private(set) var questions: [Question] = []
    private(set) var loading = false
    /// True when the server has no command-center endpoint (404): old backend.
    private(set) var unsupported = false
    private(set) var loadFailed = false
    /// Localization key of a transient problem, shown as an alert by the screen.
    var errorKey: String?
    /// Questions / tasks with a request in flight (disables their buttons).
    private(set) var busy: Set<UUID> = []

    var section: Section = .overview
    var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }
    var sort: CommandCenterOptions.Sort = .attention
    private var loadedMode: Mode?

    static let modeKey = "pref.commandCenter.mode"

    init(projectID: UUID?) {
        self.projectID = projectID
        var initial = Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .kanban
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment["TODO_DEBUG_CC_MODE"], let m = Mode(rawValue: forced) { initial = m }
        #endif
        mode = initial
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment["TODO_DEBUG_CC_SECTION"], let sec = Section(rawValue: forced) { section = sec }
        #endif
    }

    var summary: CommandSummary { data?.summary ?? CommandSummary() }
    var lanes: [CommandLaneColumn] { data?.lanes ?? [] }
    var items: [CommandCard] { data?.items ?? [] }
    var updates: [CommandUpdate] { data?.updates ?? [] }
    var builds: [BuildGroup] { data?.builds ?? [] }
    var hasContent: Bool {
        guard let data else { return false }
        return !(data.lanes ?? []).allSatisfy { $0.cards.isEmpty } || !(data.items ?? []).isEmpty
    }

    private var options: CommandCenterOptions {
        var o = CommandCenterOptions(projectID: projectID, view: mode == .kanban ? .kanban : .list)
        o.sort = sort
        if mode == .list { o.includeSubtasks = true; o.limit = 100 }
        o.updatesLimit = 30
        return o
    }

    // MARK: Loading

    func refresh(_ app: AppModel) async {
        guard let client = app.client, !loading else { return }
        LiveHub.shared.subscribe(self) { [weak self] in
            // Not while a question is being answered; live refresh must not disturb input.
            if let self, self.busy.isEmpty { await self.refresh(app) }
        }
        loading = true
        defer { loading = false }
        do {
            async let center = client.commandCenter(options)
            async let open = client.questions(projectID: projectID, state: .open, limit: 200)
            let (c, q) = try await (center, open)
            if data != c { data = c }
            if questions != q { questions = q }
            if projectID == nil { app.commandSummary = c.summary }
            unsupported = false; loadFailed = false
            loadedMode = mode
        } catch APIError.notFound {
            // Either an old server or a project that is no longer visible.
            unsupported = true
        } catch APIError.unauthorized {
            await app.handle(APIError.unauthorized(reason: nil))
        } catch {
            loadFailed = true
            if data == nil { errorKey = AppModel.key(for: error) }
        }
    }

    /// Reloads when the layout (kanban/list) changed since the last fetch.
    func refreshIfModeChanged(_ app: AppModel) async {
        if loadedMode != nil, loadedMode != mode { await refresh(app) }
    }

    // MARK: Actions

    func answer(questionID: UUID, with text: String, _ app: AppModel) async {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = app.client, !value.isEmpty, !busy.contains(questionID) else { return }
        busy.insert(questionID); defer { busy.remove(questionID) }
        do {
            _ = try await client.answerQuestion(questionID, answer: value)
            Haptics.success()
        } catch APIError.conflict(let reason) where reason == "question_already_answered" {
            errorKey = "cc.error.alreadyAnswered"
        } catch APIError.invalidInput(let reason) where reason == "invalid_answer_option" {
            errorKey = "cc.error.invalidOption"
        } catch APIError.forbidden {
            errorKey = "cc.error.forbiddenAnswer"
        } catch {
            errorKey = AppModel.key(for: error)
        }
        await refresh(app)
    }

    func decide(taskID: UUID, _ decision: ReviewDecision, note: String?, _ app: AppModel) async {
        guard let client = app.client, !busy.contains(taskID) else { return }
        busy.insert(taskID); defer { busy.remove(taskID) }
        do {
            _ = try await client.decideReview(taskID: taskID, decision: decision, note: note)
            Haptics.success()
        } catch APIError.conflict(let reason) where reason == "no_pending_review" {
            errorKey = "cc.error.noPendingReview"
        } catch APIError.forbidden {
            errorKey = "cc.error.forbiddenReview"
        } catch {
            errorKey = AppModel.key(for: error)
        }
        await refresh(app)
        await app.reload()
    }

    /// Creates the default agent columns; returns true on success.
    func applyAgentColumns(_ app: AppModel) async -> Bool {
        guard let client = app.client, let projectID else { return false }
        do {
            _ = try await client.applyAgentWorkflowColumns(projectID: projectID)
            await refresh(app)
            return true
        } catch APIError.conflict(let reason) where reason == "columns_exist" {
            errorKey = "cc.error.columnsExist"
        } catch APIError.forbidden {
            errorKey = "error.forbidden"
        } catch {
            errorKey = AppModel.key(for: error)
        }
        return false
    }
}
