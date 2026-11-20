import SwiftUI
import TodoCore

/// iPhone (and every layout at accessibility text sizes): header with date, week strip to pick a day, the day's cards in
/// time order, "Ohne Termin" as a sheet. Static in phase 1 (no dragging, no writing).
struct CalendarDayList: View {
    @Bindable var model: CalendarModel
    @State private var showUnscheduled = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                header
                CalendarWeekStrip(model: model)
                if model.isSample { CalendarSampleNote() }
                CalendarLoadNotice(model: model)
                cards
            }
            .pageMargins().padding(.vertical, Space.s)
            .readableWidth()
        }
        .background(Color.canvas)
        .safeAreaInset(edge: .bottom, spacing: 0) { unscheduledBar }
        .sheet(isPresented: $showUnscheduled) { CalendarUnscheduledSheet(model: model) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            // At accessibility sizes the week title gives way to the controls: the cards must stay reachable above the fold.
            if typeSize.isAccessibilitySize {
                CalendarWeekControls(model: model)
            } else {
                HStack(spacing: Space.s) {
                    Text(verbatim: CalendarFormat.weekTitle(model.window, calendar: model.calendar))
                        .font(.sectionTitle).foregroundStyle(Color.textSecondary).lineLimit(1)
                    Spacer(minLength: Space.s)
                    CalendarWeekControls(model: model)
                }
            }
            Text(verbatim: CalendarFormat.dayLong(model.selectedDay))
                .font(.screenTitle).lineLimit(typeSize.isAccessibilitySize ? nil : 2).minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.7)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: summary).font(.subheadline.weight(.medium)).foregroundStyle(Color.textSecondary)
        }
    }

    private var summary: String {
        let content = model.selectedContent
        let count = content.allDay.count + content.timed.count
        let conflicts = (content.allDay + content.timed.map(\.entry)).filter { !model.marks(for: $0).isEmpty }.count
        var text = String(localized: "calendar.cardCount \(count)")
        if conflicts > 0 { text += " · " + String(localized: "calendar.conflictCount \(conflicts)") }
        return text
    }

    // MARK: Cards of the day

    private enum Row: Identifiable {
        case planned(ScheduleEntry), dueOnly(ScheduleEntry)
        var id: String {
            switch self {
            case .planned(let e): "p-\(e.id)"
            case .dueOnly(let e): "d-\(e.id)"
            }
        }
    }

    /// All-day cards first, then planned cards and plain due dates by time of day.
    private var rows: [Row] {
        let content = model.selectedContent
        let shown = Set((content.allDay + content.timed.map(\.entry)).map(\.id))
        var timed: [(minute: Int, order: Int, row: Row)] = content.timed.map { ($0.startMinute, 0, .planned($0.entry)) }
        for e in content.due where !shown.contains(e.id) {
            let c = model.calendar.dateComponents([.hour, .minute], from: e.dueAt ?? model.selectedDay)
            timed.append(((c.hour ?? 0) * 60 + (c.minute ?? 0), 1, .dueOnly(e)))
        }
        timed.sort { ($0.minute, $0.order) < ($1.minute, $1.order) }
        return content.allDay.map { .planned($0) } + timed.map(\.row)
    }

    @ViewBuilder private var cards: some View {
        let rows = rows
        if rows.isEmpty && model.state != .loading {
            EmptyState(symbol: "calendar", title: "calendar.empty", message: "calendar.emptyHint", tint: .tilePurple)
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: Space.s) {
                ForEach(rows) { row in
                    switch row {
                    case .planned(let e):
                        CalendarEntryCard(entry: e, marks: CalendarMark.marks(for: e, conflicts: model.marks(for: e), calendar: model.calendar),
                                          projectName: model.projectName(e.projectID), projectColor: model.projectColor(e.projectID))
                    case .dueOnly(let e):
                        CalendarEntryCard(entry: e, marks: CalendarMark.marks(for: e, conflicts: model.marks(for: e), calendar: model.calendar).filter { !$0.isDue },
                                          projectName: model.projectName(e.projectID), projectColor: model.projectColor(e.projectID))
                    }
                }
            }
        }
    }

    // MARK: "Ohne Termin"

    private var unscheduledBar: some View {
        Button { showUnscheduled = true } label: {
            HStack(spacing: Space.m) {
                Image(systemName: "tray.full").foregroundStyle(Color.brand)
                Text("calendar.unscheduled").font(.body.weight(.semibold))
                Spacer(minLength: Space.s)
                if !model.unscheduled.isEmpty { CountBadge(count: model.unscheduled.count, tint: .brand) }
                Image(systemName: "chevron.up").font(.caption.weight(.bold)).foregroundStyle(Color.textSecondary)
            }
            .padding(Space.m)
            .frame(minHeight: TapTarget.minimum)
            .cardSurface(radius: Radius.l)
        }
        .buttonStyle(PressableStyle())
        .pageMargins().padding(.vertical, Space.s).readableWidth()
        .background(.bar)
        .accessibilityIdentifier("calendar.unscheduledButton")
        .accessibilityValue(Text("calendar.unscheduledCount \(model.unscheduled.count)"))
    }
}

// MARK: Week strip

/// Seven days to pick from. At accessibility sizes the strip scrolls sideways instead of squeezing seven columns.
struct CalendarWeekStrip: View {
    @Bindable var model: CalendarModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s) { buttons }
                }
                .onAppear { proxy.scrollTo(model.calendar.startOfDay(for: model.selectedDay), anchor: .center) }
            }
        } else {
            HStack(spacing: Space.xs) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(model.window.days, id: \.self) { day in
            CalendarDayButton(day: day, selected: model.calendar.isDate(day, inSameDayAs: model.selectedDay),
                              isToday: model.calendar.isDate(day, inSameDayAs: model.today), count: count(day)) { model.select(day) }
                .id(day)
        }
    }

    private func count(_ day: Date) -> Int {
        let c = model.content(for: day)
        return c.allDay.count + c.timed.count
    }
}

struct CalendarDayButton: View {
    let day: Date
    let selected: Bool
    let isToday: Bool
    let count: Int
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var height = CalendarMetrics.dayButtonHeight

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.xxs) {
                Text(verbatim: CalendarFormat.weekdayShort(day)).font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? Color.onBrand : Color.textSecondary)
                Text(verbatim: CalendarFormat.dayNumber(day)).font(.title3.weight(.bold)).monospacedDigit()
                    .foregroundStyle(selected ? Color.onBrand : (isToday ? Color.brand : Color.primary))
                Circle().fill(count > 0 ? (selected ? Color.onBrand : Color.brand) : Color.clear).frame(width: Space.xs, height: Space.xs)
            }
            .frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity, minHeight: height)
            .padding(.horizontal, typeSize.isAccessibilitySize ? Space.m : 0)
            .background(selected ? Color.brand : Color.clear, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .overlay {
                if isToday && !selected {
                    RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.brand, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: CalendarFormat.dayLong(day) + (isToday ? ", " + String(localized: "calendar.today") : "")))
        .accessibilityValue(Text("calendar.cardCount \(count)"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("calendar.day.\(CalendarFormat.dayNumber(day))")
    }
}

// MARK: Sheet "Ohne Termin"

struct CalendarUnscheduledSheet: View {
    let model: CalendarModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s) {
                    if model.unscheduled.isEmpty {
                        EmptyState(symbol: "tray", title: "calendar.unscheduled.empty", message: "calendar.unscheduled.emptyHint", tint: .tileBlue)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(model.unscheduled) { e in
                        UnscheduledCard(entry: e, projectName: model.projectName(e.projectID), projectColor: model.projectColor(e.projectID))
                    }
                }
                .pageMargins().padding(.vertical, Space.s)
                .readableWidth()
            }
            .background(Color.canvas)
            .navigationTitle("calendar.unscheduled")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("ok") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 380, idealHeight: 520)
        #endif
    }
}

/// Shown while loading and after a failed load (live model only).
struct CalendarLoadNotice: View {
    let model: CalendarModel
    @Environment(AppModel.self) private var app

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity).accessibilityLabel(Text("loading"))
        case .failed:
            HStack(spacing: Space.s) {
                Image(systemName: "exclamationmark.triangle")
                Text("calendar.loadFailed").font(.footnote.weight(.medium))
                Spacer(minLength: 0)
                Button("calendar.retry") { Task { await model.load(app) } }.font(.footnote.weight(.semibold)).tapTarget()
            }
            .foregroundStyle(Color.dueOverdue)
            .padding(Space.m)
            .background(Color.dueOverdue.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        case .idle, .loaded:
            EmptyView()
        }
    }
}
