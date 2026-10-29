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

/// Circular checkbox; the ring color is the priority. The tick draws itself when the box becomes checked.
struct TaskCheckbox: View {
    let checked: Bool
    let priority: Int
    let action: () -> Void

    var body: some View {
        let color = Color.priority(priority)
        Button(action: action) {
            ZStack {
                Circle().fill(color.opacity(checked ? 1 : 0.12))
                Circle().strokeBorder(color, lineWidth: 2)
                CheckShape()
                    .trim(from: 0, to: checked ? 1 : 0)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            .frame(width: 22, height: 22)
            .scaleEffect(checked ? 1.0 : 1.0)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.3, bounce: 0.35), value: checked)
        .accessibilityLabel(Text(checked ? "task.markOpen" : "task.markDone"))
        .accessibilityAddTraits(.isButton)
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
        HStack(alignment: .top, spacing: 4) {
            TaskCheckbox(checked: checked, priority: planning?.priority ?? 0) { toggle() }
                .padding(.leading, -8)
            Button { model.path = [task] } label: { content }
                .buttonStyle(.plain)
        }
        .sensoryFeedback(.success, trigger: completing) { _, now in now }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { toggle() } label: { Label("task.markDone", systemImage: "checkmark") }.tint(Color.dueToday)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { Task { await model.deleteTask(task) } } label: { Label("task.delete", systemImage: "trash") }
            Button { scheduling = true } label: { Label("task.schedule", systemImage: "calendar") }.tint(Color.dueTomorrow)
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
            Button { scheduling = true } label: { Label("task.schedule", systemImage: "calendar") }
            Button(role: .destructive) { Task { await model.deleteTask(task) } } label: { Label("task.delete", systemImage: "trash") }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: task.title)
                .font(.body)
                .strikethrough(checked, color: .secondary)
                .foregroundStyle(checked ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.2), value: checked)
            if !task.description.isEmpty {
                Text(verbatim: task.description).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            metaLine
        }
        .padding(.top, 9)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var metaLine: some View {
        let labels = meta.labels(for: task.id)
        let due = showDue ? planning?.dueAt : nil
        let showsProject = showProject && project != nil
        if due != nil || !labels.isEmpty || showsProject {
            HStack(spacing: 8) {
                if let due {
                    HStack(spacing: 3) {
                        Image(systemName: planning?.recurrence != nil ? "arrow.triangle.2.circlepath" : "calendar")
                        Text(verbatim: DueFormat.text(due))
                    }
                    .foregroundStyle(task.isDone ? Color.secondary : DueFormat.style(due).color)
                }
                ForEach(labels.prefix(2)) { LabelChip(name: $0.name) }
                Spacer(minLength: 4)
                if showsProject, let project {
                    HStack(spacing: 4) {
                        Text(verbatim: project.name).lineLimit(1)
                        ProjectDot(id: project.id, size: 7)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
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
        self.listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 6, trailing: 16))
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
        .font(.subheadline.weight(.bold))
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
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(Color.brand, in: Circle())
                        .shadow(color: Color.brand.opacity(0.35), radius: 10, y: 4)
                }
                .padding(.trailing, 20).padding(.bottom, 16)
                .accessibilityLabel(Text("task.add"))
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
