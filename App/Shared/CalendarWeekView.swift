import SwiftUI
import TodoCore

// MARK: Layout of one day column (no GeometryReader: a Layout places blocks by minute)

/// What a child of `DayBlocksLayout` is: a timed block with its side-by-side column, a due marker, or the "now" line.
enum DaySlot {
    case block(start: Int, end: Int, column: Int, columns: Int)
    case marker(minute: Int)
    case nowLine(minute: Int)
}

private struct DaySlotKey: LayoutValueKey { static let defaultValue = DaySlot.block(start: 0, end: 0, column: 0, columns: 1) }

extension View {
    fileprivate func daySlot(_ slot: DaySlot) -> some View { layoutValue(key: DaySlotKey.self, value: slot) }
}

/// Places children by minute of the day: y = minutes / 60 * hourHeight, overlapping blocks side by side.
struct DayBlocksLayout: Layout {
    var hourHeight: CGFloat
    var gap: CGFloat = Space.xxs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: hourHeight * CGFloat(CalendarMetrics.hoursPerDay))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        func y(_ minute: Int) -> CGFloat { bounds.minY + CGFloat(minute) / 60 * hourHeight }
        for view in subviews {
            switch view[DaySlotKey.self] {
            case .block(let start, let end, let column, let columns):
                let width = bounds.width / CGFloat(max(columns, 1))
                let height = max(0, CGFloat(end - start) / 60 * hourHeight - gap)
                view.place(at: CGPoint(x: bounds.minX + width * CGFloat(column) + gap / 2, y: y(start) + gap / 2), anchor: .topLeading,
                           proposal: ProposedViewSize(width: max(0, width - gap), height: height))
            case .marker(let minute), .nowLine(let minute):
                let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                view.place(at: CGPoint(x: bounds.minX, y: y(minute) - size.height / 2), anchor: .topLeading,
                           proposal: ProposedViewSize(width: bounds.width, height: size.height))
            }
        }
    }
}

// MARK: Week grid (iPad, Mac)

/// Week grid with a 15-minute raster, overlapping blocks side by side, an all-day row and an optional side panel
/// "Ohne Termin". Static in phase 1: no dragging, no writing.
struct CalendarWeekView: View {
    @Bindable var model: CalendarModel
    /// Side panel next to the grid; without it "Ohne Termin" opens as a sheet from the header.
    var showsPanel = true
    @State private var showUnscheduled = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var hourHeight = CalendarMetrics.hourHeight
    @ScaledMetric(relativeTo: .body) private var timeColumn = CalendarMetrics.timeColumn
    @ScaledMetric(relativeTo: .body) private var panelWidth = CalendarMetrics.sidePanel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                dayHeaders
                allDayRow
                Divider()
                grid
            }
            if showsPanel {
                Divider()
                CalendarSidePanel(model: model).frame(width: panelWidth)
            }
        }
        .background(Color.canvas)
        .sheet(isPresented: $showUnscheduled) { CalendarUnscheduledSheet(model: model) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            AdaptiveStack(spacing: Space.m) {
                Text(verbatim: CalendarFormat.weekTitle(model.window, calendar: model.calendar)).font(.detailTitle).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s)
                CalendarWeekControls(model: model)
                if !showsPanel {
                    Button { showUnscheduled = true } label: {
                        Label { Text("calendar.unscheduled") } icon: { Image(systemName: "tray.full") }
                            .font(.subheadline.weight(.semibold)).tapTarget()
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.brand)
                    .accessibilityValue(Text("calendar.unscheduledCount \(model.unscheduled.count)"))
                    .accessibilityIdentifier("calendar.unscheduledButton")
                }
            }
            if model.isSample { CalendarSampleNote() }
        }
        .pageMargins().padding(.vertical, Space.s)
    }

    private var dayHeaders: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeColumn + Space.xs, height: 0)
            ForEach(model.window.days, id: \.self) { day in
                CalendarDayHeader(day: day, isToday: model.calendar.isDate(day, inSameDayAs: model.today))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, Space.xs)
    }

    private var allDayRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("calendar.allDay").font(.caption2).foregroundStyle(Color.textSecondary).multilineTextAlignment(.trailing)
                .lineLimit(2).frame(width: timeColumn, alignment: .trailing).padding(.trailing, Space.xs)
            ForEach(model.window.days, id: \.self) { day in
                VStack(spacing: Space.xxs) {
                    ForEach(model.content(for: day).allDay) { e in
                        CalendarAllDayChip(entry: e, marks: CalendarMark.marks(for: e, conflicts: model.marks(for: e), calendar: model.calendar),
                                           color: model.projectColor(e.projectID))
                    }
                }
                .padding(Space.xxs)
                .frame(maxWidth: .infinity, minHeight: Space.xl, alignment: .top)
            }
        }
        .padding(.bottom, Space.xs)
    }

    // MARK: Grid

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(0..<CalendarMetrics.hoursPerDay, id: \.self) { hour in
                            Text(verbatim: hourLabel(hour)).font(.caption2).foregroundStyle(Color.textSecondary).monospacedDigit()
                                .frame(width: timeColumn, height: hourHeight, alignment: .topTrailing).padding(.trailing, Space.xs)
                                .offset(y: hour == 0 ? 0 : -Space.s)
                                .id(hour)
                                .accessibilityHidden(true)
                        }
                    }
                    ForEach(model.contents, id: \.day) { content in
                        CalendarDayColumn(content: content, model: model, hourHeight: hourHeight,
                                          isToday: model.calendar.isDate(content.day, inSameDayAs: model.today))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .task { try? await Task.sleep(for: .milliseconds(300)); proxy.scrollTo(CalendarMetrics.firstVisibleHour, anchor: .top) }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = model.calendar.date(bySettingHour: hour, minute: 0, second: 0, of: model.today) ?? model.today
        return CalendarFormat.time(date)
    }
}

struct CalendarDayHeader: View {
    let day: Date
    let isToday: Bool

    var body: some View {
        VStack(spacing: Space.xxs) {
            Text(verbatim: CalendarFormat.weekdayShort(day)).font(.caption.weight(.semibold)).foregroundStyle(Color.textSecondary)
            Text(verbatim: CalendarFormat.dayNumber(day)).font(.title3.weight(.bold)).monospacedDigit()
                .foregroundStyle(isToday ? Color.onBrand : Color.primary)
                .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                .background(isToday ? Color.brand : Color.clear, in: Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: CalendarFormat.dayLong(day) + (isToday ? ", " + String(localized: "calendar.today") : "")))
        .accessibilityAddTraits(.isHeader)
    }
}

struct CalendarAllDayChip: View {
    let entry: ScheduleEntry
    let marks: [CalendarMark]
    let color: Color

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(marks.filter { $0.isConflict }, id: \.self) { Image(systemName: $0.symbol).font(.caption2).foregroundStyle($0.tint) }
            Text(verbatim: entry.title).font(.caption.weight(.semibold)).lineLimit(1)
                .foregroundStyle(entry.isDone ? Color.textSecondary : Color.primary).strikethrough(entry.isDone)
        }
        .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: CalendarFormat.spoken(entry, marks: marks)))
    }
}

// MARK: One day column

struct CalendarDayColumn: View {
    let content: DayContent
    let model: CalendarModel
    let hourHeight: CGFloat
    let isToday: Bool

    var body: some View {
        DayBlocksLayout(hourHeight: hourHeight) {
            ForEach(content.timed) { placed in
                CalendarBlock(placed: placed, marks: CalendarMark.marks(for: placed.entry, conflicts: model.marks(for: placed.entry), calendar: model.calendar),
                              color: model.projectColor(placed.entry.projectID))
                    .daySlot(.block(start: placed.startMinute, end: placed.endMinute, column: placed.column, columns: placed.columnCount))
            }
            ForEach(content.due) { e in
                CalendarDueMarker(entry: e).daySlot(.marker(minute: minute(of: e.dueAt)))
            }
            if isToday {
                CalendarNowLine().daySlot(.nowLine(minute: minute(of: AppClock.now)))
            }
        }
        .frame(height: hourHeight * CGFloat(CalendarMetrics.hoursPerDay))
        .background { CalendarGridLines(hourHeight: hourHeight) }
        .overlay(alignment: .leading) { Rectangle().fill(Color.hairline).frame(width: 0.5) }
    }

    private func minute(of date: Date?) -> Int {
        let c = model.calendar.dateComponents([.hour, .minute], from: date ?? content.day)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

/// The raster: a line every 15 minutes, stronger on the half hour and the hour.
struct CalendarGridLines: View {
    let hourHeight: CGFloat
    var body: some View {
        Canvas { context, size in
            for quarter in 0..<(CalendarMetrics.hoursPerDay * 4) {
                let y = CGFloat(quarter) / 4 * hourHeight
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                let strength: Double = quarter % 4 == 0 ? 1 : (quarter % 2 == 0 ? 0.55 : 0.25)
                context.stroke(path, with: .color(Color.hairline.opacity(strength)), lineWidth: 0.5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A planned card in the grid. State is shown with symbols and text for assistive technology, not by color alone.
struct CalendarBlock: View {
    let placed: PlacedEntry
    let marks: [CalendarMark]
    let color: Color

    private var entry: ScheduleEntry { placed.entry }
    private var minutes: Int { placed.endMinute - placed.startMinute }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: entry.title).font(.caption.weight(.semibold)).lineLimit(minutes >= 60 ? 3 : (minutes >= 30 ? 2 : 1))
                .strikethrough(entry.isDone).foregroundStyle(entry.isDone ? Color.textSecondary : Color.primary)
            if minutes >= 45, let start = entry.start, let end = entry.end {
                Text(verbatim: "\(CalendarFormat.time(start))–\(CalendarFormat.time(end))").font(.caption2).foregroundStyle(Color.textSecondary).monospacedDigit()
                    .lineLimit(1)
            }
            if minutes >= 45, !iconMarks.isEmpty {
                HStack(spacing: Space.xxs) { ForEach(iconMarks, id: \.self) { Image(systemName: $0.symbol).font(.caption2).foregroundStyle($0.tint) } }
                    .padding(.top, Space.xxs)
            }
        }
        .padding(.horizontal, Space.xs).padding(.vertical, Space.xxs)
        .padding(.leading, CalendarMetrics.blockBar)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: CalendarMetrics.blockBar) }
        .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: CalendarFormat.spoken(entry, marks: marks)))
    }

    /// Conflicts, auto-start and state as small symbols; the due flag has its own marker in the column.
    private var iconMarks: [CalendarMark] { marks.filter { !$0.isDue } }
}

/// A due time: flag and thin line across the column, drawn above the blocks.
struct CalendarDueMarker: View {
    let entry: ScheduleEntry
    var body: some View {
        HStack(spacing: Space.xxs) {
            Image(systemName: "flag.fill").font(.caption2).foregroundStyle(Color.dueOverdue)
            Rectangle().fill(Color.dueOverdue).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: CalendarMark.due(entry.dueAt ?? Date(), showsDay: false).text + ": " + entry.title))
    }
}

struct CalendarNowLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(Color.brand).frame(width: Space.s, height: Space.s)
            Rectangle().fill(Color.brand).frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

// MARK: Side panel "Ohne Termin"

struct CalendarSidePanel: View {
    let model: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Text("calendar.unscheduled").font(.sectionTitle).accessibilityAddTraits(.isHeader)
                if !model.unscheduled.isEmpty { CountBadge(count: model.unscheduled.count, tint: .brand) }
            }
            ScrollView {
                LazyVStack(spacing: Space.s) {
                    if model.unscheduled.isEmpty {
                        EmptyState(symbol: "tray", title: "calendar.unscheduled.empty", message: "calendar.unscheduled.emptyHint", tint: .tileBlue)
                    }
                    ForEach(model.unscheduled) { e in
                        UnscheduledCard(entry: e, projectName: model.projectName(e.projectID), projectColor: model.projectColor(e.projectID))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(Space.m)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.canvasRaised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.sidePanel")
    }
}
