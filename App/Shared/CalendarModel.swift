import SwiftUI
import TodoCore

/// What the calendar tells the user after a write (banner at the top of the screen).
struct CalendarNotice: Identifiable, Equatable {
    enum Kind: String {
        case versionConflict, taskDone, readOnly, recurrence, invalidMinutes, allDayNeedsStart, notFound, failed
        case savedOffline, offlineUnavailable, busy, unauthorized
    }
    let id = UUID()
    let kind: Kind
    /// Localization key; German text in `Localizable.xcstrings`.
    var key: String { "calendar.notice.\(kind.rawValue)" }
    var isError: Bool { kind != .savedOffline }
}

/// Drag payload of a calendar card (own keys, so it never decodes as the board's `BoardDrag`).
struct CalendarDrag: Codable, Transferable, Hashable {
    let calendarTaskID: UUID
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .json) }
}

/// State of the calendar screen (card 8CECAD24). The rules (windows, layout, marks, drop decisions, patches, write route)
/// come from TodoCore; this type holds what is shown and performs the writes: optimistic display, `PATCH .../schedule`
/// with the card's version, rollback plus reload on any failure, the sync queue when the server is not reachable.
@MainActor @Observable
final class CalendarModel {
    enum LoadState: Equatable { case idle, loading, loaded, failed }

    private(set) var entries: [ScheduleEntry]
    private(set) var unscheduled: [ScheduleEntry]
    private(set) var state: LoadState
    var selectedDay: Date
    /// Card whose detail sheet is open, and whether it opens straight in the editor ("Start und Dauer").
    var selection: UUID?
    var opensEditor = false
    private(set) var notice: CalendarNotice?
    /// Cards with a write in flight: a second write would carry a stale version.
    private(set) var busy: Set<UUID> = []
    /// Writes waiting in the sync queue (shown with a clock until the server has them).
    private(set) var queued = PendingScheduleWrites()
    /// Project names and colors by id (live: from `AppModel`, sample: from the seed).
    private(set) var projectNames: [UUID: String]
    var projectColor: (UUID) -> Color = { Color.project($0) }
    /// Whether a card repeats (`TaskMeta`); a repeating card without due date keeps its start.
    var hasRecurrence: (UUID) -> Bool = { _ in false }
    /// Sample data (previews, screenshots): never loads from a server; writes only change the local copy.
    let isSample: Bool
    let calendar: Calendar
    /// Sample models: the error the next write fails with (screenshots of the rollback hint), then nil.
    var sampleFailure: ScheduleError?

    /// Live model: starts empty and loads from the server.
    init(calendar: Calendar = .current, now: Date = AppClock.now) {
        self.calendar = calendar
        self.entries = []; self.unscheduled = []; self.projectNames = [:]
        self.state = .idle; self.isSample = false
        self.selectedDay = calendar.startOfDay(for: now)
    }

    /// Fixed data without a server.
    init(entries: [ScheduleEntry], unscheduled: [ScheduleEntry], projectNames: [UUID: String], selectedDay: Date, calendar: Calendar = .current) {
        self.calendar = calendar
        self.entries = entries; self.unscheduled = unscheduled; self.projectNames = projectNames
        self.state = .loaded; self.isSample = true
        self.selectedDay = calendar.startOfDay(for: selectedDay)
    }

    var window: CalendarWindow { CalendarWindow.week(containing: selectedDay, calendar: calendar) }
    var today: Date { calendar.startOfDay(for: AppClock.now) }
    var contents: [DayContent] { CalendarLayout.contents(in: window, entries: entries, calendar: calendar) }
    var selectedContent: DayContent { CalendarLayout.content(for: selectedDay, entries: entries, calendar: calendar) }

    func content(for day: Date) -> DayContent { contents.first { calendar.isDate($0.day, inSameDayAs: day) } ?? CalendarLayout.content(for: day, entries: entries, calendar: calendar) }

    /// Conflict marks of an entry in the context of everything loaded.
    func marks(for entry: ScheduleEntry) -> [ScheduleConflict] { CalendarConflicts.conflicts(for: entry, among: entries) }

    /// Everything a card shows besides its title (due time, conflicts, auto-start state, state, waiting in the queue).
    func cardMarks(_ entry: ScheduleEntry) -> [CalendarMark] {
        CalendarMark.marks(for: entry, conflicts: marks(for: entry), calendar: calendar, pending: queued.contains(entry.id))
    }

    func projectName(_ id: UUID) -> String? { projectNames[id] }

    func entry(_ id: UUID) -> ScheduleEntry? { entries.first { $0.id == id } ?? unscheduled.first { $0.id == id } }

    func dismissNotice() { notice = nil }

    /// The sync queue has been sent (reconnect): the clock marks and the "saved offline" hint are done. Other hints stay.
    func queueSent() {
        queued.queueSent()
        if notice?.kind == .savedOffline { notice = nil }
    }

    // MARK: Navigation

    func select(_ day: Date) { selectedDay = calendar.startOfDay(for: day) }

    func shiftWeek(by weeks: Int) {
        if let day = calendar.date(byAdding: .weekOfYear, value: weeks, to: selectedDay) { selectedDay = calendar.startOfDay(for: day) }
    }

    func goToToday() { selectedDay = today }

    func openDetail(_ id: UUID, editor: Bool = false) { opensEditor = editor; selection = id }

    // MARK: Loading

    /// Fetches the window of the selected week and the sidebar list. Sample models keep their data. `quiet`: no spinner
    /// (live refresh, reload after a write).
    func load(_ app: AppModel, quiet: Bool = false) async {
        guard !isSample, let client = app.client else { return }
        projectColor = { [weak app] in app?.projectColor($0) ?? Color.project($0) }
        LiveHub.shared.subscribe(self) { [weak self, weak app] in
            guard let self, let app else { return }
            await self.load(app, quiet: true)
        }
        if !quiet || state == .idle { state = .loading }
        let window = self.window
        do {
            let response = try await client.schedule(from: window.from, to: window.to)
            guard !Task.isCancelled else { return }
            let open = try await client.unscheduled()
            guard !Task.isCancelled else { return }
            // Keep the optimistic state of cards that still have a write in flight.
            let inFlight = busy
            let kept = entries.filter { inFlight.contains($0.id) }
            entries = response.items.filter { !inFlight.contains($0.id) } + kept
            let roles = await editableProjects(of: response.items, open: open, client: client)
            unscheduled = open.filter { !inFlight.contains($0.id) }.map { ScheduleEntry(unscheduled: $0, canEdit: roles[$0.task.projectID] ?? false) }
                + unscheduled.filter { inFlight.contains($0.id) }
            projectNames = Dictionary(app.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            state = .loaded
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            if let api = (error as? ScheduleError)?.apiError ?? (error as? APIError), case .unauthorized = api { await app.handle(api) }
            state = .failed
        }
    }

    /// The planning list carries no role: take it from the schedule entries of the same project (they carry `canEdit`) and
    /// ask `GET /v1/projects/{id}/visibility` for the rest. Unknown stays read-only (conservative; the server decides anyway).
    private func editableProjects(of items: [ScheduleEntry], open: [PlanningTask], client: APIClient) async -> [UUID: Bool] {
        var roles: [UUID: Bool] = [:]
        for e in items { roles[e.projectID] = (roles[e.projectID] ?? false) || e.canEdit }
        let unknown = Set(open.map(\.task.projectID)).subtracting(roles.keys)
        await withTaskGroup(of: (UUID, Bool).self) { group in
            for id in unknown {
                group.addTask { (id, ((try? await client.visibility(projectID: id))?.role ?? .read) >= .edit) }
            }
            for await (id, canEdit) in group { roles[id] = canEdit }
        }
        return roles
    }

    // MARK: Writing

    /// Drop of a card (grid, day header, sidebar). Decides with the TodoCore rules, then writes.
    func drop(_ id: UUID, onto target: DropTarget, app: AppModel) async {
        guard let entry = entry(id) else { return }
        switch CalendarDrop.decide(entry, onto: target, hasRecurrence: hasRecurrence(id), calendar: calendar) {
        case .noChange: return
        case .refused(.readOnly): notice = CalendarNotice(kind: .readOnly)
        case .refused(.done): notice = CalendarNotice(kind: .taskDone)
        case .refused(.recurrenceNeedsDate): notice = CalendarNotice(kind: .recurrence)
        case .apply(let patch): await submit(entry, patch, app: app)
        }
    }

    /// Writes one patch: optimistic display first; on success the card takes the server's answer (new version); on any
    /// failure the card is restored, the plan is reloaded and the notice says why.
    func submit(_ before: ScheduleEntry, _ patch: SchedulePatch, app: AppModel) async {
        guard !patch.isEmpty else { return }
        guard !busy.contains(before.id) else { notice = CalendarNotice(kind: .busy); return }
        guard before.canDrag else { notice = CalendarNotice(kind: before.isDone ? .taskDone : .readOnly); return }
        busy.insert(before.id)
        defer { busy.remove(before.id) }
        notice = nil
        place(patch.applied(to: before), replacing: before)

        if isSample {
            if let failure = sampleFailure {
                sampleFailure = nil
                rollback(before, failure)
            } else {
                var after = patch.applied(to: before)
                after.version += 1
                place(after, replacing: after)
            }
            return
        }
        guard let client = app.client else { rollback(before, .other(.invalidResponse)); return }
        do {
            let result = try await client.updateSchedule(taskID: before.id, version: before.version, patch)
            var after = patch.applied(to: before)
            after.version = result.task.version
            after.plannedAt = result.planning.plannedAt
            after.plannedMinutes = result.planning.plannedMinutes
            after.plannedAllDay = result.planning.plannedAllDay
            place(after, replacing: after)
            queued.remove(before.id)
            busy.remove(before.id)
            await load(app, quiet: true)  // server-side marks (prerequisites, bindings) follow
        } catch let error as ScheduleError {
            if case .other(let api) = error, case .transport = api { await writeOffline(before, patch, app: app, failure: error) }
            else { rollback(before, error); busy.remove(before.id); await reloadAfterFailure(app, error) }
        } catch {
            rollback(before, .other(.invalidResponse)); busy.remove(before.id); await reloadAfterFailure(app, .other(.invalidResponse))
        }
    }

    /// No connection: the sync queue takes what `task.planning` can carry (move, unschedule, all-day, duration), the card
    /// stays where the user put it and shows a clock until the server has it. Everything else is refused with a hint.
    private func writeOffline(_ before: ScheduleEntry, _ patch: SchedulePatch, app: AppModel, failure: ScheduleError) async {
        guard ScheduleWriteRoute.choose(patch, isOnline: false, queueCarriesScheduleFields: true) == .queue, patch.plannedMinutes != .clear,
              await app.queueSchedule(taskID: before.id, patch) else {
            rollback(before, .notAvailableOffline)
            return
        }
        queued.add(before.id)
        notice = CalendarNotice(kind: .savedOffline)
    }

    private func reloadAfterFailure(_ app: AppModel, _ error: ScheduleError) async {
        if case .other(let api) = error, case .unauthorized = api { await app.handle(api); return }
        await load(app, quiet: true)
    }

    private func rollback(_ before: ScheduleEntry, _ error: ScheduleError) {
        place(before, replacing: before)
        switch error {
        case .versionConflict: notice = CalendarNotice(kind: .versionConflict)
        case .taskDone: notice = CalendarNotice(kind: .taskDone)
        case .readOnly: notice = CalendarNotice(kind: .readOnly)
        case .recurrenceRequiresDate: notice = CalendarNotice(kind: .recurrence)
        case .invalidPlannedMinutes, .invalidSchedule: notice = CalendarNotice(kind: .invalidMinutes)
        case .allDayRequiresPlannedAt: notice = CalendarNotice(kind: .allDayNeedsStart)
        case .notFound: notice = CalendarNotice(kind: .notFound)
        case .notAvailableOffline: notice = CalendarNotice(kind: .offlineUnavailable)
        case .other(let api): if case .unauthorized = api { notice = CalendarNotice(kind: .unauthorized) } else { notice = CalendarNotice(kind: .failed) }
        default: notice = CalendarNotice(kind: .failed)
        }
    }

    /// Puts the card where its plan says: planned cards live in `entries`, unplanned ones in the sidebar (and stay in
    /// `entries` only while their due date is in the window).
    private func place(_ updated: ScheduleEntry, replacing old: ScheduleEntry) {
        let window = self.window
        if let i = entries.firstIndex(where: { $0.id == old.id }) { entries.remove(at: i) }
        let dueInWindow = updated.dueAt.map { $0 >= window.from && $0 < window.to } ?? false
        if updated.plannedAt != nil || dueInWindow { entries.append(updated) }
        if let i = unscheduled.firstIndex(where: { $0.id == old.id }) { unscheduled.remove(at: i) }
        if updated.plannedAt == nil { unscheduled.insert(updated, at: 0) }
    }
}
