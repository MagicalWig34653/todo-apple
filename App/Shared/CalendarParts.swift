import SwiftUI
import TodoCore

// MARK: Metrics and formatting

/// Calendar-only sizes (grid and side panel). Scaled with Dynamic Type at the use site; everything else comes from `Space`/`Radius`.
enum CalendarMetrics {
    /// Height of one hour in the week grid (15 minutes = a quarter of it).
    static let hourHeight: CGFloat = 52
    static let timeColumn: CGFloat = 64
    /// Narrowest day column before the grid scrolls sideways.
    static let dayColumnMin: CGFloat = 96
    static let sidePanel: CGFloat = 280
    /// Width of the project bar at the start of a block.
    static let blockBar: CGFloat = 4
    static let dayButtonHeight: CGFloat = 64
    /// First hour in view when the grid opens.
    static let firstVisibleHour = 7
    static let hoursPerDay = 24
}

enum CalendarFormat {
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    static func duration(minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// "Fr., 17:00" for a due date on another day than the card.
    static func dayAndTime(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
    static func dayLong(_ date: Date) -> String { date.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
    static func weekdayShort(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated)) }
    static func dayNumber(_ date: Date) -> String { date.formatted(.dateTime.day()) }
    static func month(_ date: Date) -> String { date.formatted(.dateTime.month(.wide).year()) }

    static func weekTitle(_ window: CalendarWindow, calendar: Calendar) -> String {
        let number = calendar.component(.weekOfYear, from: window.from)
        let last = window.days.last ?? window.from
        let range = (window.from..<last).formatted(.interval.day().month(.abbreviated).year())
        return String(localized: "calendar.week \(number) \(range)")
    }

    /// One spoken line for a card: title, time or all day, duration, marks.
    static func spoken(_ entry: ScheduleEntry, marks: [CalendarMark]) -> String {
        var parts = [entry.title]
        if let start = entry.start {
            if entry.plannedAllDay {
                parts.append(String(localized: "calendar.allDay"))
            } else if let end = entry.end {
                parts.append(String(localized: "calendar.timeRange \(time(start)) \(time(end))"))
                parts.append(duration(minutes: entry.minutes))
            }
        }
        parts += marks.map(\.text)
        return parts.joined(separator: ". ")
    }
}

// MARK: Marks (shown, never prevent a move)

/// What a card shows besides its title. State is never color alone: every mark has a symbol and a text.
enum CalendarMark: Hashable {
    /// `showsDay`: the due date is not on the card's own day, so the weekday is part of the text.
    case due(Date, showsDay: Bool), afterDue, prerequisiteLater, prerequisiteOpen, repositoryOverlap
    case autoStart, autoStarted, done, readOnly

    var symbol: String {
        switch self {
        case .due: "flag.fill"
        case .afterDue: "exclamationmark.triangle.fill"
        case .prerequisiteLater: "calendar.badge.exclamationmark"
        case .prerequisiteOpen: "hourglass"
        case .repositoryOverlap: "square.on.square"
        case .autoStart: "bolt.fill"
        case .autoStarted: "bolt.badge.checkmark.fill"
        case .done: "checkmark.circle.fill"
        case .readOnly: "lock.fill"
        }
    }

    var text: String {
        switch self {
        case .due(let date, let showsDay): String(localized: "calendar.due \(showsDay ? CalendarFormat.dayAndTime(date) : CalendarFormat.time(date))")
        case .afterDue: String(localized: "calendar.conflict.afterDue")
        case .prerequisiteLater: String(localized: "calendar.conflict.prerequisiteLater")
        case .prerequisiteOpen: String(localized: "calendar.conflict.prerequisiteOpen")
        case .repositoryOverlap: String(localized: "calendar.conflict.repositoryOverlap")
        case .autoStart: String(localized: "calendar.autoStart")
        case .autoStarted: String(localized: "calendar.autoStarted")
        case .done: String(localized: "calendar.done")
        case .readOnly: String(localized: "calendar.readOnly")
        }
    }

    var tint: Color {
        switch self {
        case .afterDue: .dueOverdue
        case .prerequisiteLater, .prerequisiteOpen, .repositoryOverlap: .dueTomorrow
        case .autoStart: .chipPurple
        case .autoStarted: .chipTeal
        case .due, .done, .readOnly: .textSecondary
        }
    }

    var isDue: Bool { if case .due = self { true } else { false } }

    var isConflict: Bool {
        switch self {
        case .afterDue, .prerequisiteLater, .prerequisiteOpen, .repositoryOverlap: true
        default: false
        }
    }

    /// The marks of a card in a fixed order: due, conflicts, auto-start, state.
    static func marks(for entry: ScheduleEntry, conflicts: [ScheduleConflict], calendar: Calendar = .current) -> [CalendarMark] {
        var marks: [CalendarMark] = []
        if let due = entry.dueAt {
            let sameDay = entry.start.map { calendar.isDate(due, inSameDayAs: $0) } ?? true
            marks.append(.due(due, showsDay: !sameDay))
        }
        for c in conflicts {
            switch c {
            case .afterDue: marks.append(.afterDue)
            case .prerequisiteLater: marks.append(.prerequisiteLater)
            case .prerequisiteOpen: marks.append(.prerequisiteOpen)
            case .repositoryOverlap: marks.append(.repositoryOverlap)
            }
        }
        // Display only: the permission is not set here (phase 2 and the PWA own that).
        if entry.autoStartedAt != nil { marks.append(.autoStarted) } else if entry.autoStart { marks.append(.autoStart) }
        if entry.isDone { marks.append(.done) }
        if !entry.canEdit && !entry.isDone { marks.append(.readOnly) }
        return marks
    }
}

struct CalendarMarkChip: View {
    let mark: CalendarMark
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: mark.symbol).imageScale(.small)
            Text(verbatim: mark.text).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(mark.tint)
        .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
        .background(mark.tint.opacity(0.12), in: Capsule())
        .accessibilityHidden(true)  // the card reads all marks in its own label
    }
}

/// Marks wrapped over as many lines as needed.
struct CalendarMarkRow: View {
    let marks: [CalendarMark]
    var body: some View {
        if !marks.isEmpty {
            FlowLayout(spacing: Space.xs) { ForEach(marks, id: \.self) { CalendarMarkChip(mark: $0) } }
        }
    }
}

// MARK: Day list card (iPhone) and side-panel card

/// A card of the day list: time column, title, duration and project, marks.
struct CalendarEntryCard: View {
    let entry: ScheduleEntry
    let marks: [CalendarMark]
    let projectName: String?
    let projectColor: Color
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var timeWidth = CalendarMetrics.timeColumn

    var body: some View {
        AdaptiveStack(spacing: Space.m, verticalAlignment: .top) {
            timeColumn
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: entry.title)
                    .font(.rowTitle.weight(.semibold))
                    .strikethrough(entry.isDone)
                    .foregroundStyle(entry.isDone ? Color.textSecondary : Color.primary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let meta = metaLine {
                    Text(verbatim: meta).font(.rowMeta).foregroundStyle(Color.textSecondary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                }
                CalendarMarkRow(marks: marks)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.m)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).fill(projectColor)
                .frame(width: CalendarMetrics.blockBar).padding(.vertical, Space.s).padding(.leading, Space.xs)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: CalendarFormat.spoken(entry, marks: marks)))
    }

    @ViewBuilder private var timeColumn: some View {
        if let start = entry.start {
            if entry.plannedAllDay {
                Text("calendar.allDay").font(.rowMeta).foregroundStyle(Color.textSecondary)
                    .frame(width: timeWidth, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(verbatim: CalendarFormat.time(start)).font(.rowTitle.weight(.semibold)).monospacedDigit()
                    if let end = entry.end { Text(verbatim: CalendarFormat.time(end)).font(.rowMeta).foregroundStyle(Color.textSecondary).monospacedDigit() }
                }
                .frame(width: timeWidth, alignment: .leading)
            }
        } else if let due = entry.dueAt {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(verbatim: CalendarFormat.time(due)).font(.rowTitle.weight(.semibold)).monospacedDigit()
                Text("calendar.dueShort").font(.rowMeta).foregroundStyle(Color.textSecondary)
            }
            .frame(width: timeWidth, alignment: .leading)
        }
    }

    private var metaLine: String? {
        var parts: [String] = []
        if entry.start != nil, !entry.plannedAllDay { parts.append(CalendarFormat.duration(minutes: entry.minutes)) }
        if let projectName { parts.append(projectName) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A card of "Ohne Termin" (sheet on iPhone, side panel on iPad and Mac). Static in phase 1.
struct UnscheduledCard: View {
    let entry: ScheduleEntry
    let projectName: String?
    let projectColor: Color
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Circle().fill(projectColor).frame(width: Space.s, height: Space.s).padding(.top, Space.s).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: entry.title).font(.rowTitle.weight(.medium)).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let projectName { Text(verbatim: projectName).font(.rowMeta).foregroundStyle(Color.textSecondary).lineLimit(typeSize.isAccessibilitySize ? nil : 1) }
                if let due = entry.dueAt { CalendarMarkRow(marks: [.due(due, showsDay: true)]) }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.m)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: unscheduledSpoken))
    }

    private var unscheduledSpoken: String {
        var parts = [entry.title]
        if let projectName { parts.append(projectName) }
        if let due = entry.dueAt { parts.append(CalendarMark.due(due, showsDay: true).text) }
        return parts.joined(separator: ". ")
    }
}

// MARK: Week header (shared by both layouts)

/// Title of the shown week with previous, today and next. Buttons keep the minimum tap target.
struct CalendarWeekControls: View {
    @Bindable var model: CalendarModel

    var body: some View {
        HStack(spacing: Space.s) {
            Button { model.shiftWeek(by: -1) } label: { Image(systemName: "chevron.left").tapTarget() }
                .accessibilityLabel(Text("calendar.previousWeek")).accessibilityIdentifier("calendar.previousWeek")
            Button { model.goToToday() } label: { Text("calendar.today").font(.subheadline.weight(.semibold)).tapTarget() }
                .accessibilityIdentifier("calendar.today")
            Button { model.shiftWeek(by: 1) } label: { Image(systemName: "chevron.right").tapTarget() }
                .accessibilityLabel(Text("calendar.nextWeek")).accessibilityIdentifier("calendar.nextWeek")
        }
        .buttonStyle(.plain).foregroundStyle(Color.brand)
    }
}

/// Banner for the sample-data previews, so screenshots are not mistaken for a real account.
struct CalendarSampleNote: View {
    var body: some View {
        Label { Text("calendar.sampleNote") } icon: { Image(systemName: "eye") }
            .font(.footnote.weight(.medium)).foregroundStyle(Color.textSecondary)
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .background(Color.hairline.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
    }
}
