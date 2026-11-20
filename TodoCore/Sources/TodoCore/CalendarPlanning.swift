import Foundation

// MARK: Calendar rules without UI (ADR 0033 section 3, reference: the PWA's `web/src/lib/calendar.ts`)
//
// Everything here is pure and takes the `Calendar` as a parameter: the app shows the device's local time (`Calendar.current`),
// the PWA Europe/Berlin. Minutes of a day are wall-clock minutes (09:00 = 540), so a daylight-saving day lines up with the
// hour labels of the grid and with drops.

public enum CalendarRules {
    /// Grid and snapping step.
    public static let stepMinutes = 15
    /// Shown duration of a card without `plannedMinutes`.
    public static let defaultMinutes = 30
    /// Smallest height of a block (also the smallest resize); the server accepts 5 to 1440.
    public static let minimumBlockMinutes = 15
    public static let maximumMinutes = 1440
    /// Window limit of `GET /v1/planning/schedule` (more answers `400 window_too_large`).
    public static let maximumWindowDays = 62

    /// Nearest 15-minute slot of a day, `0 ... 1425` (23:45): a drop never lands on the next day.
    public static func snap(minutes: Int) -> Int {
        let clamped = max(0, minutes)
        return min(1440 - stepMinutes, (clamped + stepMinutes / 2) / stepMinutes * stepMinutes)
    }
}

// MARK: Entries

extension ScheduleEntry {
    public var start: Date? { plannedAt }
    /// Duration shown for the card (30 minutes without one).
    public var minutes: Int { plannedMinutes ?? CalendarRules.defaultMinutes }
    public var end: Date? { plannedAt.map { $0.addingTimeInterval(TimeInterval(minutes * 60)) } }
    public var isDone: Bool { status == "done" }
    /// Only with role `edit` and not finished.
    public var canDrag: Bool { canEdit && !isDone }
}

// MARK: Windows

/// A visible time range in local time (`from` inclusive, `to` exclusive) with its calendar days.
public struct CalendarWindow: Equatable, Sendable {
    public var from: Date
    public var to: Date
    /// Start of each day in the window.
    public var days: [Date]

    public init(from: Date, to: Date, days: [Date]) { self.from = from; self.to = to; self.days = days }

    /// The server rejects longer windows (`window_too_large`).
    public var isWithinServerLimit: Bool { to.timeIntervalSince(from) <= TimeInterval(CalendarRules.maximumWindowDays) * 86_400 }

    public static func day(containing date: Date, calendar: Calendar = .current) -> CalendarWindow {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return CalendarWindow(from: start, to: end, days: [start])
    }

    /// The week of `date` following the calendar's first weekday (Monday in Germany).
    public static func week(containing date: Date, calendar: Calendar = .current) -> CalendarWindow {
        let interval = calendar.dateInterval(of: .weekOfYear, for: date)
        let start = interval?.start ?? calendar.startOfDay(for: date)
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86_400)
        return CalendarWindow(from: start, to: end, days: days)
    }
}

// MARK: Layout

/// A timed block of one day: minutes from the start of the day, and the side-by-side column among overlapping blocks.
public struct PlacedEntry: Equatable, Sendable, Identifiable {
    public let entry: ScheduleEntry
    public let startMinute: Int
    public let endMinute: Int
    public internal(set) var column: Int
    public internal(set) var columnCount: Int
    public var id: UUID { entry.taskID }
}

/// What one day shows: all-day cards, timed blocks and the cards whose due date falls on the day.
public struct DayContent: Equatable, Sendable {
    public var day: Date
    public var allDay: [ScheduleEntry]
    public var timed: [PlacedEntry]
    /// Cards due on this day, by due time (the mark sits at the due time even if the card is planned elsewhere).
    public var due: [ScheduleEntry]
}

public enum CalendarLayout {
    public static func contents(in window: CalendarWindow, entries: [ScheduleEntry], calendar: Calendar = .current) -> [DayContent] {
        window.days.map { content(for: $0, entries: entries, calendar: calendar) }
    }

    public static func content(for day: Date, entries: [ScheduleEntry], calendar: Calendar = .current) -> DayContent {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        var allDay: [ScheduleEntry] = [], timed: [ScheduleEntry] = [], due: [ScheduleEntry] = []
        for e in entries {
            if let start = e.start {
                if e.plannedAllDay {
                    if start >= dayStart && start < dayEnd { allDay.append(e) }
                } else if let end = e.end, start < dayEnd, end > dayStart {
                    timed.append(e)
                }
            }
            if let dueAt = e.dueAt, dueAt >= dayStart, dueAt < dayEnd { due.append(e) }
        }
        due.sort { ($0.dueAt ?? .distantFuture, $0.taskID.uuidString) < ($1.dueAt ?? .distantFuture, $1.taskID.uuidString) }
        return DayContent(day: dayStart, allDay: allDay, timed: place(timed, dayStart: dayStart, dayEnd: dayEnd, calendar: calendar), due: due)
    }

    /// Wall-clock minutes of `date` inside the day, clamped to `0 ... 1440`.
    private static func minute(of date: Date, dayStart: Date, dayEnd: Date, calendar: Calendar) -> Int {
        if date <= dayStart { return 0 }
        if date >= dayEnd { return 1440 }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Overlapping blocks get columns side by side; a cluster (blocks linked by overlap) shares its widest column count.
    private static func place(_ entries: [ScheduleEntry], dayStart: Date, dayEnd: Date, calendar: Calendar) -> [PlacedEntry] {
        var items = entries.map { e -> PlacedEntry in
            let startMinute = minute(of: e.start ?? dayStart, dayStart: dayStart, dayEnd: dayEnd, calendar: calendar)
            let rawEnd = minute(of: e.end ?? dayStart, dayStart: dayStart, dayEnd: dayEnd, calendar: calendar)
            let endMinute = min(1440, max(rawEnd, startMinute + CalendarRules.minimumBlockMinutes))
            return PlacedEntry(entry: e, startMinute: startMinute, endMinute: endMinute, column: 0, columnCount: 1)
        }
        items.sort { ($0.startMinute, $0.endMinute, $0.entry.taskID.uuidString) < ($1.startMinute, $1.endMinute, $1.entry.taskID.uuidString) }
        var clusterFirst = 0, clusterEnd = -1
        var columnEnds: [Int] = []
        for i in items.indices {
            if i > clusterFirst, items[i].startMinute >= clusterEnd {
                for k in clusterFirst..<i { items[k].columnCount = columnEnds.count }
                clusterFirst = i; clusterEnd = -1; columnEnds = []
            }
            let column = columnEnds.firstIndex { $0 <= items[i].startMinute } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(0) }
            columnEnds[column] = items[i].endMinute
            items[i].column = column
            clusterEnd = max(clusterEnd, items[i].endMinute)
        }
        for k in clusterFirst..<items.count { items[k].columnCount = columnEnds.count }
        return items
    }
}

// MARK: Conflict marks

/// Marks are shown, never prevent a move. The server computes all four; `after_due` and the repository overlap are cheap
/// to recompute, so an optimistic move shows them at once instead of waiting for the reload.
public enum CalendarConflicts {
    /// The marks of `entry` in a fixed order: after due, prerequisite later, prerequisite open, repository overlap.
    public static func conflicts(for entry: ScheduleEntry, among entries: [ScheduleEntry]) -> [ScheduleConflict] {
        var result: [ScheduleConflict] = []
        if isAfterDue(entry) { result.append(.afterDue) }
        // The prerequisite hints depend on other cards' plans and states: as the server sent them.
        if entry.conflicts.contains(.prerequisiteLater) { result.append(.prerequisiteLater) }
        if entry.conflicts.contains(.prerequisiteOpen) { result.append(.prerequisiteOpen) }
        if entry.conflicts.contains(.repositoryOverlap) || overlapsSameBinding(entry, among: entries) { result.append(.repositoryOverlap) }
        return result
    }

    /// The end of a timed card, or the start of an all-day card, lies behind the due time.
    public static func isAfterDue(_ entry: ScheduleEntry) -> Bool {
        guard let start = entry.start, let due = entry.dueAt else { return false }
        return entry.plannedAllDay ? start > due : (entry.end ?? start) > due
    }

    /// Two open, timed cards with the same binding at the same time: the runner executes one job per repository, the second waits.
    private static func overlapsSameBinding(_ entry: ScheduleEntry, among entries: [ScheduleEntry]) -> Bool {
        guard let key = entry.repositoryKey, !entry.isDone, !entry.plannedAllDay, let start = entry.start, let end = entry.end else { return false }
        return entries.contains { other in
            guard other.taskID != entry.taskID, other.repositoryKey == key, !other.isDone, !other.plannedAllDay,
                  let otherStart = other.start, let otherEnd = other.end else { return false }
            return start < otherEnd && otherStart < end
        }
    }
}

// MARK: Drop rules

public enum DropTarget: Equatable, Sendable {
    /// A grid slot: the day and minutes from its start (snapped to 15 minutes by the rules).
    case slot(day: Date, minute: Int)
    /// The day header (all-day row).
    case allDay(day: Date)
    /// Back to the sidebar "Ohne Termin".
    case unscheduled
}

public enum DropRefusal: Equatable, Sendable {
    /// Role below `edit`.
    case readOnly
    /// Finished cards stay put (`409 task_done`).
    case done
    /// A repeating card without due date needs a date (`400 recurrence_requires_date`).
    case recurrenceNeedsDate
}

public enum DropDecision: Equatable, Sendable {
    case apply(SchedulePatch)
    case noChange
    case refused(DropRefusal)
}

public enum CalendarDrop {
    /// What dropping `entry` on `target` does. `dueAt` is never part of a patch. From the sidebar into the grid sets the start,
    /// inside the grid the start moves and the duration stays, on the day header makes the card all-day at the start of the day,
    /// back to the sidebar clears the start (the server clears duration and all-day with it). `hasRecurrence`: the card repeats
    /// (the entry does not know); without due date it must keep its start.
    public static func decide(_ entry: ScheduleEntry, onto target: DropTarget, hasRecurrence: Bool = false, calendar: Calendar = .current) -> DropDecision {
        guard entry.canEdit else { return .refused(.readOnly) }
        guard !entry.isDone else { return .refused(.done) }
        switch target {
        case .unscheduled:
            guard entry.plannedAt != nil else { return .noChange }
            if hasRecurrence && entry.dueAt == nil { return .refused(.recurrenceNeedsDate) }
            return .apply(SchedulePatch(plannedAt: .clear))
        case .allDay(let day):
            let start = calendar.startOfDay(for: day)
            if entry.plannedAllDay && entry.plannedAt == start { return .noChange }
            return .apply(SchedulePatch(plannedAt: .set(start), plannedAllDay: entry.plannedAllDay ? nil : true))
        case .slot(let day, let minute):
            let snapped = CalendarRules.snap(minutes: minute)
            let dayStart = calendar.startOfDay(for: day)
            let start = calendar.date(bySettingHour: snapped / 60, minute: snapped % 60, second: 0, of: dayStart) ?? dayStart
            if !entry.plannedAllDay && entry.plannedAt == start { return .noChange }
            return .apply(SchedulePatch(plannedAt: .set(start), plannedAllDay: entry.plannedAllDay ? false : nil))
        }
    }
}

// MARK: Optimistic view and rollback

extension SchedulePatch {
    /// The entry as the server will have it after the patch (optimistic display), following the server rules: clearing
    /// the start clears duration and all-day.
    public func applied(to entry: ScheduleEntry) -> ScheduleEntry {
        var e = entry
        switch plannedAt {
        case .keep: break
        case .set(let date): e.plannedAt = date
        case .clear: e.plannedAt = nil; e.plannedAllDay = false; e.plannedMinutes = nil
        }
        switch plannedMinutes {
        case .keep: break
        case .set(let minutes): e.plannedMinutes = minutes
        case .clear: e.plannedMinutes = nil
        }
        if let allDay = plannedAllDay { e.plannedAllDay = allDay }
        return e
    }

    /// The patch that restores `entry` (rollback after a failed write, undo).
    public static func inverse(of entry: ScheduleEntry) -> SchedulePatch {
        SchedulePatch(
            plannedAt: entry.plannedAt.map { .set($0) } ?? .clear,
            plannedMinutes: entry.plannedMinutes.map { .set($0) } ?? .clear,
            plannedAllDay: entry.plannedAllDay)
    }
}

// MARK: Online PATCH or sync queue

/// Which way a calendar write takes. Decision (docs/CALENDAR.md): online always `PATCH /v1/tasks/{id}/schedule` (partial,
/// with the task version, precise errors, as sync 1.5.0 says: "Das Verschieben im Kalender läuft online über PATCH"). The
/// sync queue (`task.planning`, a full replacement) is the offline fallback, only for what it carries: today a plain move or
/// clearing the start, because the Swift `SyncMutation` has no `plannedMinutes`/`plannedAllDay` yet.
public enum ScheduleWriteRoute: Equatable, Sendable {
    case patch
    case queue
    /// Needs the server (all-day, duration) and the app is offline: the move is refused with a hint, nothing is lost.
    case unavailableOffline

    public static func choose(_ patch: SchedulePatch, isOnline: Bool, queueCarriesScheduleFields: Bool = false) -> ScheduleWriteRoute {
        if isOnline { return .patch }
        let expressible = patch.plannedAllDay == nil && patch.plannedMinutes == .keep
        return expressible || queueCarriesScheduleFields ? .queue : .unavailableOffline
    }
}

// MARK: Editor "Start und Dauer"

public enum ScheduleEditResult: Equatable, Sendable {
    case patch(SchedulePatch)
    case noChange
    /// Duration outside 5 to 1440 minutes (`invalid_planned_minutes` on the server).
    case invalidMinutes
}

/// The form of the editor (iPhone sheet, detail on iPad and Mac, an alternative to dragging) as a patch. Same rules as a
/// drop: start snaps to 15 minutes, all-day is the start of the day without duration, only changed fields are sent, the due
/// date is never part of it. A duration equal to the default (30 minutes) on a card without one is not sent.
public enum ScheduleEditing {
    public static func patch(for entry: ScheduleEntry, start: Date, minutes: Int?, allDay: Bool, calendar: Calendar = .current) -> ScheduleEditResult {
        let dayStart = calendar.startOfDay(for: start)
        if allDay {
            if entry.plannedAllDay && entry.plannedAt == dayStart { return .noChange }
            return .patch(SchedulePatch(plannedAt: .set(dayStart), plannedAllDay: true))
        }
        if let minutes, !(5...CalendarRules.maximumMinutes).contains(minutes) { return .invalidMinutes }
        let c = calendar.dateComponents([.hour, .minute], from: start)
        let snapped = CalendarRules.snap(minutes: (c.hour ?? 0) * 60 + (c.minute ?? 0))
        let newStart = calendar.date(bySettingHour: snapped / 60, minute: snapped % 60, second: 0, of: dayStart) ?? start
        var patch = SchedulePatch()
        if entry.plannedAllDay || entry.plannedAt != newStart { patch.plannedAt = .set(newStart) }
        if entry.plannedAllDay { patch.plannedAllDay = false }
        if let minutes, minutes != entry.minutes { patch.plannedMinutes = .set(minutes) }
        return patch.isEmpty ? .noChange : .patch(patch)
    }
}

/// Cards whose schedule write waits in the sync queue (offline). The calendar shows a clock on them; once the queue has been
/// sent (the replay is done, the server has the plan) everything is settled at once.
public struct PendingScheduleWrites: Equatable, Sendable {
    public private(set) var ids: Set<UUID> = []

    public init() {}

    public func contains(_ id: UUID) -> Bool { ids.contains(id) }
    public mutating func add(_ id: UUID) { ids.insert(id) }
    public mutating func remove(_ id: UUID) { ids.remove(id) }

    /// The queue is empty again. Returns whether anything was waiting.
    @discardableResult
    public mutating func queueSent() -> Bool {
        defer { ids.removeAll() }
        return !ids.isEmpty
    }
}
