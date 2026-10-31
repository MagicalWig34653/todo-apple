import SwiftUI
import TodoCore

// MARK: Metadata (planning + labels per task)

/// Planning data and labels of tasks as lists need them (priority, due date, label chips). The sync feed only carries
/// the task itself, so this is fetched from the planning and discovery endpoints and kept next to `AppModel`.
@MainActor @Observable
final class TaskMeta {
    /// Last server-confirmed values (persisted per account so lists keep their chips and due dates offline).
    private(set) var confirmedPlanning: [UUID: PlanningData] = [:]
    private(set) var overdue: [PlanningTask] = []
    private(set) var allLabels: [TaskLabel] = []
    private(set) var confirmedLabels: [UUID: [TaskLabel]] = [:]
    /// Unsent planning/label edits (outbox) shown on top of the confirmed values.
    var overlay = OutboxSnapshot()
    /// Subtask progress per parent task and the ids of tasks that are subtasks (from the command-center list).
    private(set) var subtaskProgress: [UUID: (done: Int, total: Int)] = [:]
    private(set) var subtaskIDs: Set<UUID> = []
    func isSubtask(_ id: UUID) -> Bool { subtaskIDs.contains(id) }

    func planning(for id: UUID) -> PlanningData? { overlay.planning[id] ?? confirmedPlanning[id] }

    func labels(for id: UUID) -> [TaskLabel] {
        var list = confirmedLabels[id] ?? []
        if let removed = overlay.labelRemoves[id] { list.removeAll { removed.contains($0.id) } }
        for add in overlay.labelAdds[id] ?? [] where !list.contains(where: { $0.id == add }) {
            if let known = allLabels.first(where: { $0.id == add }) { list.append(known) }
        }
        for name in overlay.namedAdds[id] ?? [] where !list.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            list.append(allLabels.first { $0.name.lowercased() == name.lowercased() } ?? Self.placeholder(name))
        }
        return list
    }

    /// Label that exists only locally until the outbox created it on the server (stable id derived from the name).
    static func placeholder(_ name: String) -> TaskLabel {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in name.lowercased().utf8.enumerated() { bytes[i % 16] = bytes[i % 16] &* 31 &+ b &+ UInt8(truncatingIfNeeded: i) }
        return TaskLabel(id: UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])), name: name)
    }

    /// Labels with their task counts (including unsent edits), for the sidebar.
    func taskCount(for label: TaskLabel) -> Int {
        var tasks = Set(confirmedLabels.filter { $0.value.contains { $0.id == label.id } }.keys)
        for (task, ids) in overlay.labelAdds where ids.contains(label.id) { tasks.insert(task) }
        for (task, ids) in overlay.labelRemoves where ids.contains(label.id) { tasks.remove(task) }
        return tasks.count
    }

    /// Everything that changes what the lists show; used as `.task(id:)` key.
    static func refreshKey(_ app: AppModel) -> Int {
        var h = Hasher()
        for t in app.tasks { h.combine(t.id); h.combine(t.version); h.combine(t.status) }
        for p in app.today + app.upcoming { h.combine(p.id); h.combine(p.planning.dueAt); h.combine(p.planning.priority) }
        h.combine(app.metaRevision)
        return h.finalize()
    }

    // MARK: Cache (offline)

    private struct Cache: Codable {
        var planning: [UUID: PlanningData]
        var labels: [TaskLabel]
        var labelsByTask: [UUID: [TaskLabel]]
    }
    private var restored = false

    private func restore(from url: URL?) {
        guard !restored else { return }
        restored = true
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(Cache.self, from: data) else { return }
        if confirmedPlanning.isEmpty { confirmedPlanning = cache.planning }
        if allLabels.isEmpty { allLabels = cache.labels }
        if confirmedLabels.isEmpty { confirmedLabels = cache.labelsByTask }
    }

    private func persist(to url: URL?) {
        guard let url else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(Cache(planning: confirmedPlanning, labels: allLabels, labelsByTask: confirmedLabels)).write(to: url, options: .atomic)
    }

    func refresh(_ app: AppModel) async {
        restore(from: app.metaCacheURL)
        guard let client = app.client else { return }
        var known: [UUID: PlanningData] = [:]
        for p in app.today + app.upcoming { known[p.id] = p.planning }
        // Offline (or any failure) keeps the last confirmed values instead of blanking the lists.
        if let next = try? await client.upNext() {
            for p in next { known[p.id] = p.planning }
            let start = DueFormat.startOfToday()
            overdue = next.filter { ($0.planning.dueAt ?? .distantFuture) < start && !$0.task.isDone }
                .sorted { ($0.planning.dueAt ?? .distantFuture) < ($1.planning.dueAt ?? .distantFuture) }
            confirmedPlanning = known
        } else {
            confirmedPlanning.merge(known) { _, new in new }
        }
        var overview = CommandCenterOptions(projectID: nil, view: .list)
        overview.includeSubtasks = true
        overview.limit = 200
        if let cards = try? await client.commandCenter(overview).items {
            var progress: [UUID: (done: Int, total: Int)] = [:]
            var children: Set<UUID> = []
            for card in cards {
                if card.parentTaskID != nil { children.insert(card.id) }
                if !card.subtasks.isEmpty { progress[card.id] = (card.subtasks.filter { $0.status == "done" }.count, card.subtasks.count) }
            }
            subtaskProgress = progress; subtaskIDs = children
        }
        if let labels = try? await client.labels(limit: 100).items {
            var map: [UUID: [TaskLabel]] = [:]
            var complete = true
            for label in labels {
                guard let hits = try? await client.search(nil, labelID: label.id, limit: 100) else { complete = false; break }
                for hit in hits.items { if let t = hit.task { map[t.id, default: []].append(label) } }
            }
            allLabels = labels
            if complete { confirmedLabels = map }
        }
        persist(to: app.metaCacheURL)
    }

    /// Current planning of the task for a read-modify-write: the known value, else the server's. nil if neither is
    /// available (offline and never seen); callers then must not guess, because PUT replaces everything.
    private func basePlanning(_ task: TodoTask, _ app: AppModel) async -> PlanningData? {
        if let known = planning(for: task.id) { return known }
        if let client = app.client, let fetched = try? await client.planning(taskID: task.id).planning { return fetched }
        app.noticeKey = "notice.planningUnavailable"
        return nil
    }

    /// Replaces the priority (0 none ... 3 highest), keeping the other planning values.
    func setPriority(_ task: TodoTask, to value: Int, _ app: AppModel) async {
        guard var data = await basePlanning(task, app) else { return }
        data.priority = value
        await app.savePlanning(taskID: task.id, data)
    }

    /// Moves the due date (nil clears it). Planning is replaced as a whole, so the current values are kept.
    func schedule(_ task: TodoTask, to date: Date?, _ app: AppModel) async {
        guard var data = await basePlanning(task, app) else { return }
        data.dueAt = date
        if date == nil && data.plannedAt == nil { data.recurrence = nil }
        await app.savePlanning(taskID: task.id, data)
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
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = Color.priority(priority)
        let size = size * scale
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
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.4), value: checked)
        .accessibilityLabel(Text(checked ? "task.markOpen" : "task.markDone"))
        .accessibilityValue(Text(priority > 0 ? TaskRow.priorityName(priority) : ""))
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
    @State private var confirmingDelete = false
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { Haptics.warning(); Task { await model.deleteTask(task) } } label: { Label("task.delete", systemImage: "trash") }
            Button { scheduling = true } label: { Label("task.schedule", systemImage: "calendar") }.tint(Color.tileOrange)
        }
        .confirmationDialog("task.delete.confirm", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("task.delete", role: .destructive) { Haptics.warning(); Task { await model.deleteTask(task) } }
            Button("cancel", role: .cancel) {}
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
            Divider()
            ShareLink(item: shareText) { Label("task.share", systemImage: "square.and.arrow.up") }
            Button(role: .destructive) { confirmingDelete = true } label: { Label("task.delete", systemImage: "trash") }
        }
        .draggable(BoardDrag(kind: .task, id: task.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: task.title))
        .accessibilityValue(Text(verbatim: accessibilitySummary))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.path = [task] }
        .accessibilityAction(named: Text(task.isDone ? "task.markOpen" : "task.markDone")) { toggle() }
        .accessibilityAction(named: Text("task.schedule")) { scheduling = true }
        .accessibilityAction(named: Text("task.delete")) { confirmingDelete = true }
    }

    private var shareText: String { task.description.isEmpty ? task.title : task.title + "\n" + task.description }

    /// Everything the visual row shows besides the title, as one spoken phrase (state, priority, due date, progress, project).
    private var accessibilitySummary: String {
        var parts: [String] = []
        if checked { parts.append(String(localized: "a11y.done")) }
        if let p = planning?.priority, p > 0 { parts.append(Self.priorityText(p)) }
        if showDue, let due = planning?.dueAt { parts.append(String(localized: "a11y.due \(DueFormat.text(due))")) }
        if let sub = meta.subtaskProgress[task.id] { parts.append(String(localized: "a11y.subtasks \(sub.done) \(sub.total)")) }
        let labels = meta.labels(for: task.id).map(\.name)
        if !labels.isEmpty { parts.append(labels.joined(separator: ", ")) }
        if showProject, let project { parts.append(String(localized: "a11y.project \(project.name)")) }
        return parts.joined(separator: ", ")
    }

    static func priorityText(_ p: Int) -> String {
        switch p { case 3: String(localized: "priority.p1"); case 2: String(localized: "priority.p2"); case 1: String(localized: "priority.p3"); default: String(localized: "priority.p4") }
    }

    static func priorityName(_ p: Int) -> LocalizedStringKey {
        switch p { case 3: "priority.p1"; case 2: "priority.p2"; case 1: "priority.p3"; default: "priority.p4" }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: task.title)
                .font(.rowTitle)
                .strikethrough(checked, color: Color.textSecondary)
                .foregroundStyle(checked ? Color.textSecondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.2), value: checked)
            if !task.description.isEmpty {
                Text(verbatim: task.description).font(.footnote).foregroundStyle(Color.textSecondary).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
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
        let priority = planning?.priority ?? 0
        if due != nil || !labels.isEmpty || showsProject || sub != nil || (priority > 0 && !task.isDone) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs)) : AnyLayout(HStackLayout(spacing: Space.s))
            layout {
                // Priority is never color alone: flag symbol plus "P1".."P3" next to the colored ring.
                if priority > 0 && !task.isDone {
                    MetaItem(symbol: "flag.fill", text: "P\(4 - priority)", tint: Color.priority(priority), textTint: Color.textSecondary)
                }
                if let due {
                    MetaItem(symbol: planning?.recurrence != nil ? "arrow.triangle.2.circlepath" : "calendar", text: DueFormat.text(due),
                             tint: task.isDone ? .secondary : DueFormat.style(due).color)
                }
                if let sub { MetaItem(symbol: "checklist", text: "\(sub.done)/\(sub.total)") }
                ForEach(labels.prefix(2)) { LabelChip(name: $0.name) }
                if !typeSize.isAccessibilitySize { Spacer(minLength: Space.xs) }
                if showsProject, let project {
                    HStack(spacing: 4) {
                        Text(verbatim: project.name).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        ProjectDot(id: project.id, size: 7)
                    }
                    .foregroundStyle(Color.textSecondary)
                    .layoutPriority(-1)
                }
            }
            .font(.rowMeta)
        }
    }

    private func toggle() {
        if task.isDone {
            Haptics.tap()
            model.setDone(task.id, false, undoManager: undoManager)
            return
        }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.35)) { completing = true }
        Haptics.success()
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 450))
            model.setDone(task.id, true, undoManager: undoManager)
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
            if let count { Text(verbatim: String(count)).foregroundStyle(Color.textSecondary).fontWeight(.regular) }
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
    @ScaledMetric(relativeTo: .title) private var fabSize: CGFloat = 60
    var projectID: UUID?
    var dueDate: Date?

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            // The floating button must never cover the last rows: scroll content gets room for it.
            .contentMargins(.bottom, fabSize + 28, for: .scrollContent)
            .overlay(alignment: .bottomTrailing) {
                Button { Haptics.tap(); show = true } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: fabSize, height: fabSize)
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
