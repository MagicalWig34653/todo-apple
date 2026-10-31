import SwiftUI
import TodoCore

@MainActor @Observable
final class TaskDetailModel {
    var task: TodoTask
    var planning = PlanningData()
    var comments: [Comment] = []
    var activity: [Activity] = []
    var attachments: [TaskAttachment] = []
    var labels: [TaskLabel] = []
    var allLabels: [TaskLabel] = []
    var subtasks: [TodoTask] = []
    var loaded = false

    init(task: TodoTask) { self.task = task }

    func loadSubtasks(_ app: AppModel) async {
        guard let client = app.client, let context = try? await client.taskContext(task.id) else { return }
        subtasks = context.subtasks
    }

    func addSubtask(_ title: String, _ app: AppModel) async {
        guard let client = app.client else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            let created = try await client.createTask(projectID: task.projectID, title: title)
            try await client.setTaskStructure(created.id, parentTaskID: task.id)
            app.apply(created)
            subtasks.append(created)
        } catch { await app.handle(error) }
    }

    func toggleSubtask(_ sub: TodoTask, _ app: AppModel) async {
        guard let client = app.client else { return }
        do {
            let updated = try await client.updateTask(sub.id, version: sub.version, TaskUpdate(status: sub.isDone ? .open : .done))
            app.apply(updated)
            if let i = subtasks.firstIndex(where: { $0.id == sub.id }) { subtasks[i] = updated }
        } catch { await app.handle(error) }
    }

    func load(_ app: AppModel, meta: TaskMeta? = nil) async {
        guard let client = app.client else { return }
        // The text fields come from the local store (optimistic, works offline). Planning and labels fall back to the
        // cached values plus the unsent outbox edits; comments, activity and attachments stay empty while offline.
        let local = app.tasks.first { $0.id == task.id }
        if let local { task = local }
        do {
            async let p = client.planning(taskID: task.id)
            async let c = client.comments(taskID: task.id)
            async let a = client.activity(taskID: task.id, limit: 30)
            async let f = client.attachments(taskID: task.id)
            async let l = client.labels(taskID: task.id)
            async let al = client.labels()
            let planned = try await p
            // Keep queued (not yet confirmed) edits visible instead of the older server state.
            task = (app.pendingChanges > 0 ? app.tasks.first { $0.id == task.id } : nil) ?? planned.task
            planning = app.outboxSnapshot.planning[task.id] ?? planned.planning
            comments = try await c; activity = try await a.items; attachments = try await f
            allLabels = try await al.items
            labels = Self.applyOutbox(try await l.items, task: task.id, known: allLabels, app.outboxSnapshot)
            loaded = true
            await loadSubtasks(app)
        } catch APIError.transport {
            offlineFallback(app, meta)
        } catch { await app.handle(error) }
    }

    /// Offline: show the cached planning/labels with the unsent edits on top.
    private func offlineFallback(_ app: AppModel, _ meta: TaskMeta?) {
        if let cached = app.outboxSnapshot.planning[task.id] ?? meta?.planning(for: task.id) { planning = cached }
        if let meta {
            allLabels = meta.allLabels
            labels = meta.labels(for: task.id)
        }
    }

    static func applyOutbox(_ confirmed: [TaskLabel], task: UUID, known: [TaskLabel], _ outbox: OutboxSnapshot) -> [TaskLabel] {
        var list = confirmed
        if let removed = outbox.labelRemoves[task] { list.removeAll { removed.contains($0.id) } }
        for id in outbox.labelAdds[task] ?? [] where !list.contains(where: { $0.id == id }) {
            if let l = known.first(where: { $0.id == id }) { list.append(l) }
        }
        for name in outbox.namedAdds[task] ?? [] where !list.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            list.append(known.first { $0.name.lowercased() == name.lowercased() } ?? TaskMeta.placeholder(name))
        }
        return list
    }

    /// Queues the edited planning (works offline); the outbox replays it and the task version follows via `apply`.
    func savePlanning(_ app: AppModel) async {
        await app.savePlanning(taskID: task.id, planning)
    }

    func saveText(title: String, description: String, _ app: AppModel) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != task.title || description != task.description else { return }
        if let updated = await app.updateTask(task, TaskUpdate(title: title, description: description)) { task = updated }
        else { await load(app) }
    }

    func setStatus(_ status: TaskStatus, _ app: AppModel) async {
        guard status.rawValue != task.status else { return }
        if let updated = await app.updateTask(task, TaskUpdate(status: status)) { task = updated }
        else { await load(app) }
    }

    func addComment(_ text: String, _ app: AppModel) async {
        guard let client = app.client else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            comments.append(try await client.addComment(taskID: task.id, body: text))
            activity = (try? await client.activity(taskID: task.id, limit: 30).items) ?? activity
        } catch { await app.handle(error) }
    }

    func deleteComment(_ c: Comment, _ app: AppModel) async {
        guard let client = app.client else { return }
        do { try await client.deleteComment(taskID: task.id, id: c.id, version: c.version); comments.removeAll { $0.id == c.id } }
        catch { await app.handle(error) }
    }

    func toggleLabel(_ label: TaskLabel, _ app: AppModel) async {
        let enabled = !labels.contains(where: { $0.id == label.id })
        if enabled { labels.append(label) } else { labels.removeAll { $0.id == label.id } }
        await app.setLabel(label, on: task.id, enabled: enabled)
    }

    func createLabel(_ name: String, _ app: AppModel) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let known = allLabels.first { $0.name.lowercased() == name.lowercased() }
        let label = known ?? TaskMeta.placeholder(name)
        if !labels.contains(where: { $0.id == label.id }) { labels.append(label) }
        await app.addLabel(named: name, to: task.id, known: allLabels)
    }
}

struct TaskDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(TaskMeta.self) private var meta
    @Environment(\.dismiss) private var dismiss
    @State private var model: TaskDetailModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var title: String
    @State private var text: String
    @State private var newComment = ""
    @State private var newLabel = ""
    @State private var newSubtask = ""
    @State private var pickingDate = false
    @State private var showActivity = false

    init(task: TodoTask) {
        _model = State(initialValue: TaskDetailModel(task: task))
        _title = State(initialValue: task.title)
        _text = State(initialValue: task.description)
    }

    private var statusBinding: Binding<TaskStatus> {
        Binding(
            get: { TaskStatus(rawValue: model.task.status) ?? .open },
            set: { s in Task { await model.setStatus(s, app) } })
    }

    @ViewBuilder private func statusLabel(_ s: TaskStatus) -> some View {
        switch s {
        case .open: Text("status.open")
        case .inProgress: Text("status.in_progress")
        case .inReview: Text("status.in_review")
        case .done: Text("status.done")
        }
    }

    private func priorityLabel(_ p: Int) -> Text { Text(TaskRow.priorityName(p)) }

    private var project: Project? { app.projects.first { $0.id == model.task.projectID } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.l) {
                header
                propertiesCard
                subtasksCard
                AttachmentsSection(taskID: model.task.id, attachments: $model.attachments)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface().padding(.horizontal, Space.l)
                commentsCard
                activityCard
            }
            .padding(.top, Space.s).padding(.bottom, Space.xxl)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.canvas)
        .safeAreaInset(edge: .bottom, spacing: 0) { commentComposer }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("done") { saveText(); app.path = []; dismiss() }.fontWeight(.semibold) }
            ToolbarItem(placement: .principal) { breadcrumb }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { Task { await model.setStatus(model.task.isDone ? .open : .done, app) } } label: {
                        Label(model.task.isDone ? "task.markOpen" : "task.markDone", systemImage: "checkmark.circle")
                    }
                    Button(role: .destructive) {
                        Task { await app.deleteTask(model.task); app.path = []; dismiss() }
                    } label: { Label("task.delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(Text("project.more"))
            }
        }
        .task { await model.load(app, meta: meta); title = model.task.title; text = model.task.description }
        .onDisappear { saveText() }
    }

    private var breadcrumb: some View {
        Menu {
            ForEach(app.projects) { p in
                Button { moveTask(to: p.id) } label: { Label(p.name, systemImage: p.id == model.task.projectID ? "checkmark" : "number") }
            }
        } label: {
            HStack(spacing: 5) {
                ProjectDot(id: model.task.projectID, size: 8)
                Text(verbatim: project?.name ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Color.textSecondary)
            }
            .foregroundStyle(Color.primary)
            .tapTarget()
        }
    }

    // MARK: header (checkbox, title, description)

    private var header: some View {
        (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs)) : AnyLayout(HStackLayout(alignment: .top, spacing: Space.xs))) {
            TaskCheckbox(checked: model.task.isDone, priority: model.planning.priority, size: 28) {
                Task { await model.setStatus(model.task.isDone ? .open : .done, app) }
                Haptics.success()
            }
            .padding(.leading, -8).padding(.top, -2)
            VStack(alignment: .leading, spacing: Space.s) {
                TextField(accessible: "task.title", text: $title, axis: .vertical)
                    .font(.detailTitle)
                    .strikethrough(model.task.isDone)
                    .foregroundStyle(model.task.isDone ? Color.textSecondary : Color.primary)
                    .onSubmit(saveText)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.alignleft").font(.footnote).foregroundStyle(.tertiary).padding(.top, 3)
                    TextField(accessible: "task.description", text: $text, axis: .vertical)
                        .font(.body).foregroundStyle(Color.textSecondary).lineLimit(1...12)
                }
            }
        }
        .padding(.horizontal, Space.l)
    }

    // MARK: properties

    private var propertiesCard: some View {
        VStack(spacing: 0) {
            dueRow
            if pickingDate { datePickerRow }
            divider
            repeatRow
            divider
            reminderRow
            divider
            priorityRow
            divider
            labelsRow
            divider
            statusRow
        }
        .padding(.horizontal, Space.m)
        .cardSurface()
        .padding(.horizontal, Space.l)
    }

    private var divider: some View { Divider().padding(.leading, 40) }

    private func propertyRow<Value: View>(_ icon: String, _ tint: Color, _ label: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
        // From the accessibility sizes on the value moves below the label instead of squeezing next to it.
        let stacked = typeSize.isAccessibilitySize
        return (stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs)) : AnyLayout(HStackLayout(spacing: Space.m))) {
            HStack(spacing: Space.m) {
                IconTile(symbol: icon, tint: tint, size: 26)
                Text(label).foregroundStyle(Color.primary)
            }
            if !stacked { Spacer(minLength: Space.s) }
            value().multilineTextAlignment(stacked ? .leading : .trailing).foregroundStyle(Color.textSecondary)
                .frame(minHeight: 44).contentShape(Rectangle())
                .padding(.leading, stacked ? 26 + Space.m : 0)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 46)
        .padding(.vertical, stacked ? Space.s : 0)
        .contentShape(Rectangle())
    }

    private var dueRow: some View {
        let due = model.planning.dueAt
        return propertyRow("calendar", .tileGreen, "task.due") {
            Menu {
                Button { setDue(DueFormat.today()) } label: { Label("due.today", systemImage: "sun.max") }
                Button { setDue(DueFormat.tomorrow()) } label: { Label("due.tomorrow", systemImage: "sunrise") }
                Button { setDue(DueFormat.weekend()) } label: { Label("due.weekend", systemImage: "sofa") }
                Button { setDue(DueFormat.nextWeek()) } label: { Label("due.nextWeek", systemImage: "calendar.badge.plus") }
                Button { if model.planning.dueAt == nil { setDue(DueFormat.tomorrow()) }; withAnimation { pickingDate.toggle() } } label: { Label("due.pick", systemImage: "calendar") }
                if due != nil { Button(role: .destructive) { pickingDate = false; setDue(nil) } label: { Label("due.none", systemImage: "xmark") } }
            } label: {
                if let due {
                    Text(verbatim: DueFormat.text(due)).fontWeight(.medium).foregroundStyle(DueFormat.style(due).color)
                } else {
                    Text("due.none")
                }
            }
        }
    }

    private var datePickerRow: some View {
        DatePicker("", selection: Binding(get: { model.planning.dueAt ?? DueFormat.tomorrow() }, set: { setDue($0) }),
                   displayedComponents: [.date, .hourAndMinute])
            .datePickerStyle(.graphical).labelsHidden()
    }

    private var repeatRow: some View {
        let rule = model.planning.recurrence
        return propertyRow("arrow.triangle.2.circlepath", .tileTeal, "task.repeat") {
            Menu {
                Button { setRecurrence(nil) } label: { Label("repeat.none", systemImage: rule == nil ? "checkmark" : "xmark") }
                ForEach(RecurrenceRule.Frequency.allCases, id: \.self) { f in
                    Button { setRecurrence(f) } label: { Label(Self.repeatKey(f), systemImage: rule?.frequency == f ? "checkmark" : "repeat") }
                }
            } label: {
                if let rule { Text(Self.repeatKey(rule.frequency)).fontWeight(.medium) } else { Text("repeat.none") }
            }
        }
    }

    private static func repeatKey(_ f: RecurrenceRule.Frequency) -> LocalizedStringKey {
        switch f { case .daily: "repeat.daily"; case .weekly: "repeat.weekly"; case .monthly: "repeat.monthly" }
    }

    private var reminderRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            propertyRow("bell.fill", .tilePurple, "task.reminders") {
                Menu {
                    if let due = model.planning.dueAt {
                        Button { addReminder(due) } label: { Label("reminder.atDue", systemImage: "bell") }
                        Button { addReminder(due.addingTimeInterval(-1800)) } label: { Label("reminder.30min", systemImage: "bell") }
                        Button { addReminder(due.addingTimeInterval(-3600)) } label: { Label("reminder.1h", systemImage: "bell") }
                        Button { addReminder(due.addingTimeInterval(-86400)) } label: { Label("reminder.1d", systemImage: "bell") }
                    } else {
                        Button { addReminder(Date().addingTimeInterval(3600)) } label: { Label("reminder.inOneHour", systemImage: "bell") }
                        Button { addReminder(DueFormat.tomorrow()) } label: { Label("reminder.tomorrowMorning", systemImage: "bell") }
                    }
                } label: { Text(model.planning.reminders.isEmpty ? LocalizedStringKey("reminder.add") : "reminder.addMore") }
            }
            if !model.planning.reminders.isEmpty {
                AdaptiveStack(spacing: 6) {
                    ForEach(model.planning.reminders, id: \.self) { r in
                        Button { removeReminder(r) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bell.fill").font(.caption2)
                                Text(verbatim: DueFormat.text(r))
                                Image(systemName: "xmark").font(.caption2.weight(.bold))
                            }
                            .font(.caption.weight(.medium)).foregroundStyle(Color.chipPurple)
                            .padding(.horizontal, 9).padding(.vertical, 4).background(Color.chipPurple.opacity(0.10), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 38).padding(.bottom, Space.s)
            }
        }
    }

    private var priorityRow: some View {
        let p = model.planning.priority
        return propertyRow("flag.fill", Color.priority(p == 0 ? 3 : p), "task.priority") {
            Menu {
                ForEach([3, 2, 1, 0], id: \.self) { v in
                    Button { setPriority(v) } label: { Label { priorityLabel(v) } icon: { Image(systemName: v == p ? "checkmark" : "flag.fill") } }
                }
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(Color.priority(p)).frame(width: 9, height: 9)
                    priorityLabel(p).fontWeight(.medium)
                }
            }
            .tint(.primary)
        }
    }

    private var labelsRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            propertyRow("tag.fill", .tileOrange, "task.labels") {
                Menu {
                    ForEach(model.allLabels) { l in
                        Button { Task { await model.toggleLabel(l, app); await meta.refresh(app) } } label: {
                            Label(l.name, systemImage: model.labels.contains(where: { $0.id == l.id }) ? "checkmark" : "tag")
                        }
                    }
                } label: {
                    if model.labels.isEmpty { Text("label.add") } else {
                        AdaptiveStack(spacing: 4) { ForEach(model.labels) { LabelChip(name: $0.name) } }
                    }
                }
            }
            TextField(accessible: "label.new", text: $newLabel).font(.footnote).onSubmit {
                let name = newLabel; newLabel = ""
                Task { await model.createLabel(name, app); await meta.refresh(app) }
            }
            .padding(.leading, 38).padding(.bottom, Space.s)
        }
    }

    private var statusRow: some View {
        propertyRow("circle.dotted.circle", .tileBlue, "task.status") {
            Picker("task.status", selection: statusBinding) {
                ForEach(TaskStatus.allCases, id: \.self) { statusLabel($0).tag($0) }
            }
            .labelsHidden().tint(.primary)
        }
    }

    // MARK: subtasks

    private var subtasksCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("task.subtasks").font(.sectionTitle)
                if !model.subtasks.isEmpty {
                    Text(verbatim: "\(model.subtasks.filter(\.isDone).count)/\(model.subtasks.count)").font(.caption.weight(.semibold)).foregroundStyle(Color.textSecondary)
                }
                Spacer()
            }
            .padding(.bottom, Space.xs)
            if !model.subtasks.isEmpty {
                ProgressView(value: Double(model.subtasks.filter(\.isDone).count), total: Double(model.subtasks.count))
                    .tint(Color.tileGreen).padding(.bottom, Space.xs)
            }
            ForEach(model.subtasks) { sub in
                HStack(spacing: Space.xs) {
                    TaskCheckbox(checked: sub.isDone, priority: 0, size: 20) { Haptics.success(); Task { await model.toggleSubtask(sub, app) } }
                        .padding(.leading, -10)
                    Text(verbatim: sub.title).font(.subheadline).strikethrough(sub.isDone)
                        .foregroundStyle(sub.isDone ? Color.textSecondary : Color.primary)
                    Spacer()
                }
            }
            HStack(spacing: Space.s) {
                Image(systemName: "plus").font(.footnote.weight(.semibold)).foregroundStyle(Color.brand).frame(width: 24)
                TextField(accessible: "subtask.add", text: $newSubtask).font(.subheadline).submitLabel(.done).onSubmit {
                    let t = newSubtask; newSubtask = ""
                    Task { await model.addSubtask(t, app); await meta.refresh(app) }
                }
            }
            .padding(.vertical, Space.xs)
        }
        .padding(Space.m)
        .cardSurface()
        .padding(.horizontal, Space.l)
    }

    // MARK: comments / activity

    private var commentsCard: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: 6) {
                Text("task.comments").font(.sectionTitle)
                if !model.comments.isEmpty { Text(verbatim: String(model.comments.count)).font(.caption.weight(.semibold)).foregroundStyle(Color.textSecondary) }
                Spacer()
            }
            if model.comments.isEmpty {
                Text("comment.empty").font(.footnote).foregroundStyle(Color.textSecondary)
            }
            ForEach(model.comments) { c in
                HStack(alignment: .top, spacing: Space.s + 2) {
                    Text(verbatim: String((c.authorName ?? "?").prefix(1)).uppercased())
                        .font(.caption.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(Color.project(c.authorID).gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(verbatim: c.authorName ?? "?").font(.caption.weight(.semibold))
                        }
                        Text(verbatim: c.body).font(.subheadline)
                            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                            .background(Color.canvasRaised, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                    }
                }
                .contextMenu {
                    if c.authorID == app.user?.id {
                        Button("comment.delete", role: .destructive) { Task { await model.deleteComment(c, app) } }
                    }
                }
            }
        }
        .padding(.horizontal, Space.l)
    }

    private var commentComposer: some View {
        HStack(spacing: Space.s) {
            TextField(accessible: "comment.new", text: $newComment, axis: .vertical).lineLimit(1...4)
                .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                .background(Color.canvasRaised, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5))
            let empty = newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button {
                let t = newComment; newComment = ""
                Task { await model.addComment(t, app) }
            } label: { Image(systemName: "arrow.up.circle.fill").font(.largeTitle).foregroundStyle(empty ? Color.secondary.opacity(0.5) : Color.brand) }
            .buttonStyle(.plain).disabled(empty)
            .accessibilityLabel(Text("comment.send"))
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.s)
        .background(.bar)
    }

    @ViewBuilder private var activityCard: some View {
        if !model.activity.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                Button { withAnimation { showActivity.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).rotationEffect(.degrees(showActivity ? 90 : 0))
                        Text("task.activity").font(.sectionTitle)
                        Text(verbatim: String(model.activity.count)).font(.caption.weight(.semibold)).foregroundStyle(Color.textSecondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showActivity {
                    ForEach(model.activity) { a in
                        HStack(alignment: .top, spacing: Space.s) {
                            Circle().fill(Color.hairline).frame(width: 7, height: 7).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 1) {
                                activityText(a.kind).font(.footnote)
                                HStack {
                                    if let name = a.actorName { Text(verbatim: name) }
                                    if let at = a.createdAt { Text(at, format: .dateTime.day().month().hour().minute()) }
                                }.font(.caption2).foregroundStyle(Color.textSecondary)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Space.l)
        }
    }

    // MARK: actions

    private func setDue(_ date: Date?) {
        Haptics.select()
        model.planning.dueAt = date
        if date == nil { model.planning.recurrence = nil; model.planning.reminders = [] }
        Task { await model.savePlanning(app); await meta.refresh(app) }
    }

    private func setPriority(_ p: Int) {
        Haptics.select()
        model.planning.priority = p
        Task { await model.savePlanning(app); await meta.refresh(app) }
    }

    private func setRecurrence(_ f: RecurrenceRule.Frequency?) {
        Haptics.select()
        model.planning.recurrence = f.map { RecurrenceRule(frequency: $0) }
        if f != nil, model.planning.dueAt == nil { model.planning.dueAt = DueFormat.today() }
        Task { await model.savePlanning(app); await meta.refresh(app) }
    }

    private func addReminder(_ date: Date) {
        Haptics.select()
        if !model.planning.reminders.contains(date) { model.planning.reminders.append(date) }
        model.planning.reminders.sort()
        Task { await model.savePlanning(app) }
    }

    private func removeReminder(_ date: Date) {
        model.planning.reminders.removeAll { $0 == date }
        Task { await model.savePlanning(app) }
    }

    private func moveTask(to projectID: UUID) {
        guard projectID != model.task.projectID, let client = app.client else { return }
        Task {
            do {
                model.task = try await client.updateTask(model.task.id, version: model.task.version, TaskUpdate(projectID: projectID))
                app.apply(model.task)
            } catch { await app.handle(error) }
        }
    }

    private func saveText() { Task { await model.saveText(title: title, description: text, app) } }
}

/// Literal keys so the string catalog resolves them; unknown kinds from newer servers show the raw kind.
@ViewBuilder func activityText(_ kind: String) -> some View {
    switch kind {
    case "task.created": Text("activity.task_created")
    case "task.updated": Text("activity.task_updated")
    case "task.status_changed": Text("activity.task_status_changed")
    case "task.moved": Text("activity.task_moved")
    case "task.planning_updated": Text("activity.task_planning_updated")
    case "comment.created": Text("activity.comment_created")
    case "comment.updated": Text("activity.comment_updated")
    case "comment.deleted": Text("activity.comment_deleted")
    case "agent.claimed": Text("activity.agent_claimed")
    case "agent.answered": Text("activity.agent_answered")
    case "agent.released": Text("activity.agent_released")
    case "criterion.created": Text("activity.criterion_created")
    case "criterion.updated": Text("activity.criterion_updated")
    case "criterion.deleted": Text("activity.criterion_deleted")
    default: Text(verbatim: kind)
    }
}
