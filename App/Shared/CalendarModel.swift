import SwiftUI
import TodoCore

/// State of the calendar screen (card 8CECAD24, phase 1: read-only). The rules (windows, layout, marks) come from
/// TodoCore (`CalendarWindow`, `CalendarLayout`, `CalendarConflicts`); this type only holds what is shown.
/// Phase 2 adds dragging and writing (`CalendarDrop`, `ScheduleWriteRoute`).
@MainActor @Observable
final class CalendarModel {
    enum LoadState: Equatable { case idle, loading, loaded, failed }

    private(set) var entries: [ScheduleEntry]
    private(set) var unscheduled: [ScheduleEntry]
    private(set) var state: LoadState
    var selectedDay: Date
    /// Project names and colors by id (live: from `AppModel`, sample: from the seed).
    private(set) var projectNames: [UUID: String]
    var projectColor: (UUID) -> Color = { Color.project($0) }
    /// Sample data (previews, screenshots): never loads and never writes.
    let isSample: Bool
    let calendar: Calendar

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

    func projectName(_ id: UUID) -> String? { projectNames[id] }

    // MARK: Navigation

    func select(_ day: Date) { selectedDay = calendar.startOfDay(for: day) }

    func shiftWeek(by weeks: Int) {
        if let day = calendar.date(byAdding: .weekOfYear, value: weeks, to: selectedDay) { selectedDay = calendar.startOfDay(for: day) }
    }

    func goToToday() { selectedDay = today }

    // MARK: Loading (read-only)

    /// Fetches the window of the selected week and the sidebar list. Sample models keep their data.
    func load(_ app: AppModel) async {
        guard !isSample, let client = app.client else { return }
        state = .loading
        let window = self.window
        do {
            let response = try await client.schedule(from: window.from, to: window.to)
            guard !Task.isCancelled else { return }
            // The planning list carries no role; until phase 2 writes, nothing in the sidebar is draggable.
            let open = try await client.unscheduled()
            guard !Task.isCancelled else { return }
            entries = response.items
            unscheduled = open.map { ScheduleEntry(unscheduled: $0, canEdit: false) }
            projectNames = Dictionary(app.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            projectColor = { app.projectColor($0) }
            state = .loaded
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            if let api = (error as? ScheduleError)?.apiError ?? (error as? APIError), case .unauthorized = api { await app.handle(api) }
            state = .failed
        }
    }
}
