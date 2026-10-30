import SwiftUI
import TodoCore

// MARK: Metadata (planning + labels per task)

/// Planning data and labels of tasks as lists need them (priority, due date, label chips). The sync feed only carries
/// the task itself, so this is fetched from the planning and discovery endpoints and kept next to `AppModel`.
@MainActor @Observable
final class TaskMeta {
    private(set) var planning: [UUID: PlanningData] = [:]
    private(set) var overdue: [PlanningTask] = []
    private(set) var allLabels: [TaskLabel] = []
    private(set) var labelsByTask: [UUID: [TaskLabel]] = [:]
    /// Subtask progress per parent task and the ids of tasks that are subtasks (from the command-center list).
    private(set) var subtaskProgress: [UUID: (done: Int, total: Int)] = [:]
    private(set) var subtaskIDs: Set<UUID> = []
    func isSubtask(_ id: UUID) -> Bool { subtaskIDs.contains(id) }

    func planning(for id: UUID) -> PlanningData? { planning[id] }
    func labels(for id: UUID) -> [TaskLabel] { labelsByTask[id] ?? [] }

    /// Everything that changes what the lists show; used as `.task(id:)` key.
    static func refreshKey(_ app: AppModel) -> Int {
        var h = Hasher()
        for t in app.tasks { h.combine(t.id); h.combine(t.version); h.combine(t.status) }
        for p in app.today + app.upcoming { h.combine(p.id); h.combine(p.planning.dueAt); h.combine(p.planning.priority) }
        return h.finalize()
    }

    func refresh(_ app: AppModel) async {
        guard let client = app.client else { return }
        var known: [UUID: PlanningData] = [:]
        for p in app.today + app.upcoming { known[p.id] = p.planning }
        if let next = try? await client.upNext() {
            for p in next { known[p.id] = p.planning }
            let start = DueFormat.startOfToday()
            overdue = next.filter { ($0.planning.dueAt ?? .distantFuture) < start && !$0.task.isDone }
                .sorted { ($0.planning.dueAt ?? .distantFuture) < ($1.planning.dueAt ?? .distantFuture) }
        }
        planning = known
        var overview = CommandCenterOptions(projectID: nil, view: .list)
        overview.includeSubtasks = true
        overview.limit = 200
        if let cards = try? await client.commandCenter(overview).items {
            var progress: [UUID: (done: Int, total: Int)] = [:]
            var children: Set<UUID> = []
            for card in cards {
                if let parent = card.parentTaskID { children.insert(card.id); _ = parent }
                if !card.subtasks.isEmpty { progress[card.id] = (card.subtasks.filter { $0.status == "done" }.count, card.subtasks.count) }
            }
            subtaskProgress = progress; subtaskIDs = children
        }
        if let labels = try? await client.labels(limit: 100).items {
            allLabels = labels
            var map: [UUID: [TaskLabel]] = [:]
            for label in labels {
                guard let hits = try? await client.search(nil, labelID: label.id, limit: 100) else { continue }
                for hit in hits.items { if let t = hit.task { map[t.id, default: []].append(label) } }
            }
            labelsByTask = map
        }
    }

    /// Replaces the priority (0 none ... 3 highest), keeping the other planning values.
    func setPriority(_ task: TodoTask, to value: Int, _ app: AppModel) async {
        guard let client = app.client else { return }
        do {
            var data: PlanningData
            if let known = planning[task.id] { data = known } else { data = try await client.planning(taskID: task.id).planning }
            data.priority = value
            planning[task.id] = data
            _ = try await client.setPlanning(taskID: task.id, data)
            await app.reloadAgenda()
        } catch { await app.handle(error) }
    }

    /// Moves the due date (nil clears it). Planning is replaced as a whole, so the current values are kept.
    func schedule(_ task: TodoTask, to date: Date?, _ app: AppModel) async {
        guard let client = app.client else { return }
        do {
            var data: PlanningData
            if let known = planning[task.id] { data = known } else { data = try await client.planning(taskID: task.id).planning }
            data.dueAt = date
            planning[task.id] = data
            _ = try await client.setPlanning(taskID: task.id, data)
            await app.reloadAgenda()
        } catch { await app.handle(error) }
    }
}

// MARK: Checkbox

struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.26, y: rect.minY + rect.height * 0.52))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.68))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.75, y: rect.minY + rect.height * 0.33))
        return p
    }
}

/// Circular checkbox; the ring color is the priority, the fill tint grows with it. The tick draws itself on completion.
struct TaskCheckbox: View {
    let checked: Bool
    let priority: Int
    var size: CGFloat = 24
    let action: () -> Void

    var body: some View {
        let color = Color.priority(priority)
        Button(action: action) {
            ZStack {
                Circle().fill(color.opacity(checked ? 1 : (priority > 0 ? 0.14 : 0.05)))
                Circle().strokeBorder(color.opacity(checked ? 1 : 0.9), lineWidth: priority > 0 ? 2 : 1.6)
                CheckShape()
                    .trim(from: 0, to: checked ? 1 : 0)
                    .stroke(.white, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round, lineJoin: .round))
            }
            .frame(width: size, height: size)
            .scaleEffect(checked ? 1.08 : 1.0)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.3, bounce: 0.4), value: checked)
        .accessibilityLabel(Text(checked ? "task.markOpen" : "task.markDone"))
        .accessibilityValue(Text(verbatim: priority > 0 ? "P\(4 - priority)" : ""))
    }
}

// MARK: Row

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta
    let task: TodoTask
    var showProject = true
    var showDue = true
    @State private var completing = false
    @State private var scheduling = false

    private var planning: PlanningData? { meta.planning(for: task.id) }
    private var project: Project? { model.projects.first { $0.id == task.projectID } }
    private var checked: Bool { task.isDone != completing }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            TaskCheckbox(checked: checked, priority: planning?.priority ?? 0) { toggle() }
                .padding(.leading, -10).padding(.top, -6)
            Button { model.path = [task] } label: { content }
                .buttonStyle(.plain)
        }
        .sensoryFeedback(.success, trigger: completing) { _, now in now }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { toggle() } label: { Label(task.isDone ? "task.markOpen" : "task.markDone", systemImage: task.isDone ? "arrow.uturn.backward" : "checkmark") }.tint(Color.tileGreen)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { Haptics.warning(); Task { await model.deleteTask(task) } } label: { Label("task.delete", systemImage: "trash") }
            Button { scheduling = true } label: { Label("task.schedule", systemImage: "calendar") }.tint(Color.tileOrange)
        }
        .confirmationDialog("task.schedule", isPresented: $scheduling) {
            Button("due.today") { Task { await meta.schedule(task, to: DueFormat.today(), model) } }
            Button("due.tomorrow") { Task { await meta.schedule(task, to: DueFormat.tomorrow(), model) } }
            Button("due.weekend") { Task { await meta.schedule(task, to: DueFormat.weekend(), model) } }
            Button("due.nextWeek") { Task { await meta.schedule(task, to: DueFormat.nextWeek(), model) } }
            Button("due.none", role: .destructive) { Task { await meta.schedule(task, to: nil, model) } }
            Button("cancel", role: .cancel) {}
        }
        .contextMenu {
            Button { toggle() } label: { Label(task.isDone ? "task.markOpen" : "task.markDone", systemImage: "checkmark.circle") }
            Button { model.path = [task] } label: { Label("task.open", systemImage: "arrow.up.forward.square") }
            Menu {
                Button { Task { await meta.schedule(task, to: DueFormat.today(), model) } } label: { Label("due.today", systemImage: "sun.max") }
                Button { Task { await meta.schedule(task, to: DueFormat.tomorrow(), model) } } label: { Label("due.tomorrow", systemImage: "sunrise") }
                Button { Task { await meta.schedule(task, to: DueFormat.weekend(), model) } } label: { Label("due.weekend", systemImage: "sofa") }
                Button { Task { await meta.schedule(task, to: DueFormat.nextWeek(), model) } } label: { Label("due.nextWeek", systemImage: "calendar.badge.plus") }
                Button(role: .destructive) { Task { await meta.schedule(task, to: nil, model) } } label: { Label("due.none", systemImage: "calendar.badge.minus") }
            } label: { Label("task.schedule", systemImage: "calendar") }
            Menu {
                ForEach([3, 2, 1, 0], id: \.self) { p in
                    Button { Task { await meta.setPriority(task, to: p, model) } } label: { Label(Self.priorityName(p), systemImage: (planning?.priority ?? 0) == p ? "checkmark" : "flag.fill") }
                }
            } label: { Label("task.priority", systemImage: "flag") }
            Divider()
            Button(role: .destructive) { Task { await model.deleteTask(task) } } label: { Label("task.delete", systemImage: "trash") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("task.markDone")) { toggle() }
    }

    static func priorityName(_ p: Int) -> LocalizedStringKey {
        switch p { case 3: "priority.p1"; case 2: "priority.p2"; case 1: "priority.p3"; default: "priority.p4" }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: task.title)
                .font(.rowTitle)
                .strikethrough(checked, color: .secondary)
                .foregroundStyle(checked ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.2), value: checked)
            if !task.description.isEmpty {
                Text(verbatim: task.description).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            metaLine
        }
        .padding(.top, 3)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var metaLine: some View {
        let labels = meta.labels(for: task.id)
        let due = showDue ? planning?.dueAt : nil
        let sub = meta.subtaskProgress[task.id]
        let showsProject = showProject && project != nil
        if due != nil || !labels.isEmpty || showsProject || sub != nil {
            HStack(spacing: Space.s) {
                if let due {
                    MetaItem(symbol: planning?.recurrence != nil ? "arrow.triangle.2.circlepath" : "calendar", text: DueFormat.text(due),
                             tint: task.isDone ? .secondary : DueFormat.style(due).color)
                }
                if let sub { MetaItem(symbol: "checklist", text: "\(sub.done)/\(sub.total)") }
                ForEach(labels.prefix(2)) { LabelChip(name: $0.name) }
                Spacer(minLength: Space.xs)
                if showsProject, let project {
                    HStack(spacing: 4) {
                        Text(verbatim: project.name).lineLimit(1)
                        ProjectDot(id: project.id, size: 7)
                    }
                    .foregroundStyle(.tertiary)
                    .layoutPriority(-1)
                }
            }
            .font(.rowMeta)
        }
    }

    private func toggle() {
        if task.isDone {
            Haptics.tap()
            Task { await model.toggle(task) }
            return
        }
        withAnimation(.spring(duration: 0.3, bounce: 0.35)) { completing = true }
        Haptics.success()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            await model.toggle(task)
            completing = false
        }
    }
}

// MARK: List styling

extension View {
    /// Plain Todoist-like list: hairline separators, canvas background, compact row insets.
    func taskListStyle() -> some View {
        self.listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 84, for: .scrollContent)
            .background(Color.canvas)
    }

    func taskRowInsets() -> some View {
        self.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparatorTint(Color.hairline)
            .listRowBackground(Color.canvas)
    }
}

struct SectionHeaderLabel: View {
    let title: LocalizedStringKey?
    var verbatim: String?
    var count: Int?
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 6) {
            if let title { Text(title) } else if let verbatim { Text(verbatim: verbatim) }
            if let count { Text(verbatim: String(count)).foregroundStyle(.secondary).fontWeight(.regular) }
            Spacer()
        }
        .font(.sectionTitle)
        .foregroundStyle(tint)
        .textCase(nil)
        .padding(.vertical, 2)
    }
}

// MARK: Quick-add entry point

/// Floating red "+" on iOS, toolbar button with ⌘N on macOS. Both open the quick-add sheet.
struct QuickAddButton: ViewModifier {
    @State private var show = false
    var projectID: UUID?
    var dueDate: Date?

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .overlay(alignment: .bottomTrailing) {
                Button { Haptics.tap(); show = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(LinearGradient(colors: [Color.brand.opacity(0.92), Color.brand], startPoint: .top, endPoint: .bottom), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                        .shadow(color: Color.brand.opacity(0.4), radius: 12, y: 6)
                }
                .buttonStyle(PressableStyle())
                .padding(.trailing, 20).padding(.bottom, 14)
                .accessibilityLabel(Text("task.add"))
                .accessibilityIdentifier("quickAddButton")
            }
            .sheet(isPresented: $show) { QuickAddSheet(projectID: projectID, dueDate: dueDate) }
            #if DEBUG
            .task { if DebugLaunch.openQuickAdd { try? await Task.sleep(for: .seconds(4)); show = true } }
            #endif
        #else
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { show = true } label: { Label("task.add", systemImage: "plus") }
                        .keyboardShortcut("n", modifiers: .command)
                        .help(Text("task.add"))
                }
            }
            .sheet(isPresented: $show) { QuickAddSheet(projectID: projectID, dueDate: dueDate) }
        #endif
    }
}

extension View {
    func quickAdd(projectID: UUID? = nil, dueDate: Date? = nil) -> some View {
        modifier(QuickAddButton(projectID: projectID, dueDate: dueDate))
    }
}
