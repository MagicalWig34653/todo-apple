import SwiftUI
import TodoCore

/// Large title with a secondary line, used on top of the agenda lists.
struct ScreenHeader: View {
    let title: LocalizedStringKey
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.screenTitle)
            if let subtitle { Text(verbatim: subtitle).font(.subheadline.weight(.medium)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.canvas)
    }
}

/// "Heute": date header, overdue section, then what is due today.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta

    private var overdue: [PlanningTask] { meta.overdue }
    private var today: [PlanningTask] { model.today.sorted { ($0.planning.dueAt ?? .distantFuture) < ($1.planning.dueAt ?? .distantFuture) } }

    private var summary: String {
        let n = overdue.count + today.count
        return n == 0 ? "" : " · " + String(localized: "agenda.openCount \(n)")
    }

    var body: some View {
        List {
            ScreenHeader(title: "view.today", subtitle: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)) + summary)
            if !overdue.isEmpty {
                Section {
                    ForEach(overdue) { TaskRow(task: $0.task).taskRowInsets() }
                } header: {
                    HStack {
                        SectionHeaderLabel(title: "agenda.overdue", count: overdue.count, tint: .dueOverdue)
                        Button("agenda.reschedule") { Task { for p in overdue { await meta.schedule(p.task, to: DueFormat.today(), model) } } }
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.brand).textCase(nil)
                            .padding(.horizontal, Space.s + 2).padding(.vertical, 4).background(Color.brand.opacity(0.1), in: Capsule()).buttonStyle(.plain)
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
                else { SkeletonRows().frame(maxHeight: .infinity, alignment: .top).padding(.top, 120) }
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .navigationTitle("view.today")
        .refreshable { await model.reloadAgenda() }
        .task { await model.reloadAgenda() }
        .quickAdd(dueDate: DueFormat.today())
    }
}

/// "Anstehend": horizontal week strip plus day-by-day sections.
struct UpcomingView: View {
    @Environment(AppModel.self) private var model
    @State private var selected = Calendar.current.startOfDay(for: Date())

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
                            Text("agenda.dayEmpty").font(.footnote).foregroundStyle(.tertiary).taskRowInsets()
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
        .navigationTitle("view.upcoming")
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(days, id: \.self) { day in
                    let isSelected = cal.isDate(day, inSameDayAs: selected)
                    Button { Haptics.select(); selected = day; onSelect(day) } label: {
                        VStack(spacing: 4) {
                            Text(day.formatted(.dateTime.weekday(.narrow))).font(.caption2.weight(.medium))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                            Text(day.formatted(.dateTime.day())).font(.callout.weight(.semibold))
                                .foregroundStyle(isSelected ? Color.white : (cal.isDateInToday(day) ? Color.brand : Color.primary))
                            Circle().fill(hasTasks(day) ? (isSelected ? Color.white : Color.brand) : Color.clear).frame(width: 4, height: 4)
                        }
                        .frame(width: 44, height: 62)
                        .background(isSelected ? Color.brand : (cal.isDateInToday(day) ? Color.brand.opacity(0.1) : Color.clear), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                        .shadow(color: isSelected ? Color.brand.opacity(0.3) : .clear, radius: 6, y: 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.canvas)
    }
}
