import SwiftUI
import TodoCore

/// Large title with a secondary line, used on top of the agenda lists.
struct ScreenHeader: View {
    let title: LocalizedStringKey
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(.screenTitle).lineLimit(1).minimumScaleFactor(0.5).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(verbatim: subtitle).font(.subheadline.weight(.medium)).foregroundStyle(Color.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PageRowInsets(top: Space.s, bottom: Space.s))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.canvas)
    }
}

/// "Heute": date header, overdue section, then what is due today.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta

    /// iOS shows the large `ScreenHeader` title in the list, so the bar title stays empty (no duplicate); macOS keeps the window title.
    static var barTitle: LocalizedStringKey {
        #if os(iOS)
        ""
        #else
        "view.today"
        #endif
    }

    private var overdue: [PlanningTask] { meta.overdue }
    private var today: [PlanningTask] { model.today.sorted { ($0.planning.dueAt ?? .distantFuture) < ($1.planning.dueAt ?? .distantFuture) } }

    private var summary: String {
        let n = overdue.count + today.count
        return n == 0 ? "" : " · " + String(localized: "agenda.openCount \(n)")
    }

    var body: some View {
        List {
            ScreenHeader(title: "view.today", subtitle: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)) + summary)
            if overdue.isEmpty && today.isEmpty && !model.agendaLoaded {
                SkeletonRows().listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.canvas)
            }
            if !overdue.isEmpty {
                Section {
                    ForEach(overdue) { TaskRow(task: $0.task).taskRowInsets() }
                } header: {
                    AdaptiveStack {
                        SectionHeaderLabel(title: "agenda.overdue", count: overdue.count, tint: .dueOverdue)
                        Button("agenda.reschedule") { Task { for p in overdue { await meta.schedule(p.task, to: DueFormat.today(), model) } } }
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.brand).textCase(nil)
                            .padding(.horizontal, Space.s).padding(.vertical, Space.xs).background(Color.brand.opacity(0.07), in: Capsule()).tapTarget().buttonStyle(.plain)
                    }
                }
            }
            Section {
                ForEach(today) { TaskRow(task: $0.task).taskRowInsets() }
            } header: {
                if !overdue.isEmpty {
                    SectionHeaderLabel(title: nil, verbatim: Date().formatted(.dateTime.day().month(.abbreviated)) + " · " + String(localized: "due.today"), count: today.count)
                }
            }
        }
        .taskListStyle()
        .overlay {
            if overdue.isEmpty && today.isEmpty {
                if model.agendaLoaded { EmptyState(symbol: "sun.max", title: "agenda.todayEmpty", message: "agenda.todayHint", tint: .tileOrange) }
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .navigationTitle(Self.barTitle)
        .refreshable { await model.reloadAgenda() }
        .task { await model.reloadAgenda() }
        .quickAdd(dueDate: DueFormat.today())
    }
}

/// "Anstehend": horizontal week strip plus day-by-day sections.
struct UpcomingView: View {
    @Environment(AppModel.self) private var model
    @State private var selected = Calendar.current.startOfDay(for: Date())

    static var barTitle: LocalizedStringKey {
        #if os(iOS)
        ""
        #else
        "view.upcoming"
        #endif
    }

    private let cal = Calendar.current
    private var days: [Date] {
        let start = cal.startOfDay(for: Date())
        return (0..<14).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private var grouped: [Date: [PlanningTask]] {
        Dictionary(grouping: (model.today + model.upcoming).filter { $0.planning.dueAt != nil }) { cal.startOfDay(for: $0.planning.dueAt!) }
    }

    var body: some View {
        let groups = grouped
        let later = groups.keys.filter { $0 > days.last! }.sorted()
        ScrollViewReader { proxy in
            List {
                ScreenHeader(title: "view.upcoming", subtitle: selected.formatted(.dateTime.month(.wide).year()))
                WeekStrip(days: days, selected: $selected, hasTasks: { groups[$0] != nil }) { day in
                    withAnimation { proxy.scrollTo(day, anchor: .top) }
                }
                ForEach(days + later, id: \.self) { day in
                    Section {
                        let items = (groups[day] ?? []).sorted { ($0.planning.dueAt ?? day) < ($1.planning.dueAt ?? day) }
                        ForEach(items) { TaskRow(task: $0.task, showDue: DueFormat.hasTime($0.planning.dueAt ?? day)).taskRowInsets() }
                        if items.isEmpty {
                            Text("agenda.dayEmpty").font(.footnote).foregroundStyle(Color.textSecondary).taskRowInsets()
                        }
                    } header: {
                        SectionHeaderLabel(title: nil, verbatim: dayTitle(day), count: groups[day]?.count)
                    }
                    .id(day)
                }
            }
            .taskListStyle()
        }
        .toolbarTitleDisplayMode(.inline)
        .navigationTitle(UpcomingView.barTitle)
        .refreshable { await model.reloadAgenda() }
        .task { await model.reloadAgenda() }
        .quickAdd(dueDate: selected)
    }

    private func dayTitle(_ day: Date) -> String {
        let prefix: String
        if cal.isDateInToday(day) { prefix = String(localized: "due.today") + " · " }
        else if cal.isDateInTomorrow(day) { prefix = String(localized: "due.tomorrow") + " · " }
        else { prefix = "" }
        return prefix + day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}

struct WeekStrip: View {
    let days: [Date]
    @Binding var selected: Date
    let hasTasks: (Date) -> Bool
    let onSelect: (Date) -> Void
    private let cal = Calendar.current
    @ScaledMetric(relativeTo: .body) private var cellWidth: CGFloat = Space.xxl + Space.m
    @ScaledMetric(relativeTo: .body) private var cellHeight: CGFloat = Space.xxl * 2

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s) {
                ForEach(days, id: \.self) { day in
                    let isSelected = cal.isDate(day, inSameDayAs: selected)
                    Button { Haptics.select(); selected = day; onSelect(day) } label: {
                        VStack(spacing: Space.xs) {
                            Text(day.formatted(.dateTime.weekday(.narrow))).font(.caption2.weight(.medium))
                                .foregroundStyle(isSelected ? Color.onBrand.opacity(0.9) : Color.textSecondary)
                            Text(day.formatted(.dateTime.day())).font(.callout.weight(.semibold))
                                .foregroundStyle(isSelected ? Color.onBrand : (cal.isDateInToday(day) ? Color.brand : Color.primary))
                            Circle().fill(hasTasks(day) ? (isSelected ? Color.onBrand : Color.brand) : Color.clear).frame(width: Space.xs, height: Space.xs)
                        }
                        .frame(width: min(cellWidth, Space.xl * 3), height: min(cellHeight, Space.xxl * 3))
                        .background(isSelected ? Color.brand : (cal.isDateInToday(day) ? Color.brand.opacity(0.1) : Color.clear), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                        .shadow(color: isSelected ? Color.brand.opacity(0.3) : .clear, radius: Space.s, y: Space.xs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .pageMargins()
        }
        // The cells are fixed-size controls: their text stops growing at the largest regular size, the cell frame scales on.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.canvas)
    }
}

// MARK: Previews

#if DEBUG
private struct AgendaPreview: View {
    @State private var model = AppModel()
    @State private var meta = TaskMeta()
    var upcoming = false
    var body: some View {
        NavigationStack { if upcoming { UpcomingView() } else { TodayView() } }
            .environment(model).environment(meta)
            .onAppear {
                let project = Project(id: UUID(), parentID: nil, name: "Website-Relaunch", version: 1)
                model.projects = [project]
                func item(_ title: String, _ hours: Double, _ priority: Int) -> PlanningTask {
                    PlanningTask(task: TodoTask(id: UUID(), projectID: project.id, title: title),
                                 planning: PlanningData(dueAt: Date().addingTimeInterval(hours * 3600), priority: priority))
                }
                model.today = [item("Datenschutzerklärung überarbeiten", 1, 3), item("Rücksprache Steuerberater", 3, 0)]
                model.upcoming = [item("Wochenplanung vorbereiten", 30, 2)]
                model.agendaLoaded = true
            }
    }
}

#Preview("Today light") { AgendaPreview().preferredColorScheme(.light) }
#Preview("Today dark") { AgendaPreview().preferredColorScheme(.dark) }
#Preview("Today accessibility5") { AgendaPreview().dynamicTypeSize(.accessibility5) }
#Preview("Upcoming light") { AgendaPreview(upcoming: true).preferredColorScheme(.light) }
#Preview("Upcoming dark") { AgendaPreview(upcoming: true).preferredColorScheme(.dark) }
#Preview("Upcoming accessibility5") { AgendaPreview(upcoming: true).dynamicTypeSize(.accessibility5) }
#endif
