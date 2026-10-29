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
    var loaded = false

    init(task: TodoTask) { self.task = task }

    func load(_ app: AppModel) async {
        guard let client = app.client else { return }
        // The text fields come from the local store (optimistic, works offline); planning, comments, labels and
        // attachments are REST-only, so a failure here (typically offline) just leaves those sections empty.
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
            planning = planned.planning
            comments = try await c; activity = try await a.items; attachments = try await f
            labels = try await l.items; allLabels = try await al.items
            loaded = true
        } catch APIError.transport {
            // Offline: keep what the local store shows.
        } catch { await app.handle(error) }
    }

    func savePlanning(_ app: AppModel) async {
        guard let client = app.client else { return }
        do {
            let result = try await client.setPlanning(taskID: task.id, planning)
            planning = result.planning
            if app.pendingChanges == 0 { task = result.task }
            app.apply(result.task)
            await app.reloadAgenda()
        } catch { await app.handle(error); await load(app) }
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
        guard let client = app.client else { return }
        do {
            if labels.contains(where: { $0.id == label.id }) {
                try await client.removeLabel(label.id, fromTask: task.id); labels.removeAll { $0.id == label.id }
            } else {
                try await client.addLabel(label.id, toTask: task.id); labels.append(label)
            }
        } catch { await app.handle(error) }
    }

    func createLabel(_ name: String, _ app: AppModel) async {
        guard let client = app.client else { return }
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let l = try await client.createLabel(name: name)
            allLabels.append(l)
            try await client.addLabel(l.id, toTask: task.id); labels.append(l)
        } catch { await app.handle(error) }
    }
}

struct TaskDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(TaskMeta.self) private var meta
    @Environment(\.dismiss) private var dismiss
    @State private var model: TaskDetailModel
    @State private var title: String
    @State private var text: String
    @State private var newComment = ""
    @State private var newLabel = ""
    @State private var pickingDate = false

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

    @ViewBuilder private func priorityLabel(_ p: Int) -> some View {
        switch p {
        case 3: Text("priority.p1")
        case 2: Text("priority.p2")
        case 1: Text("priority.p3")
        default: Text("priority.p4")
        }
    }

    private var project: Project? { app.projects.first { $0.id == model.task.projectID } }

    var body: some View {
        List {
            header
            Section {
                projectRow
                dueRow
                if pickingDate { datePickerRow }
                priorityRow
                labelsRow
                statusRow
            }
            .listRowBackground(Color.canvas)
            commentsSection
            AttachmentsSection(taskID: model.task.id, attachments: $model.attachments)
            if !model.activity.isEmpty {
                Section("task.activity") {
                    ForEach(model.activity) { a in
                        VStack(alignment: .leading) {
                            activityText(a.kind)
                            HStack {
                                if let name = a.actorName { Text(verbatim: name) }
                                if let at = a.createdAt { Text(at, format: .dateTime.day().month().hour().minute()) }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("done") { saveText(); app.path = []; dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    Task { await app.deleteTask(model.task); app.path = []; dismiss() }
                } label: { Label("task.delete", systemImage: "trash") }
            }
        }
        .task { await model.load(app); title = model.task.title; text = model.task.description }
        .onDisappear { saveText() }
    }

    // MARK: header (checkbox, title, description)

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            TaskCheckbox(checked: model.task.isDone, priority: model.planning.priority) {
                Task { await model.setStatus(model.task.isDone ? .open : .done, app) }
                Haptics.success()
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField("task.title", text: $title, axis: .vertical)
                    .font(.title3.weight(.semibold))
                    .strikethrough(model.task.isDone)
                    .onSubmit(saveText)
                TextField("task.description", text: $text, axis: .vertical)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1...8)
            }
            .padding(.top, 8)
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.canvas)
    }

    // MARK: property rows

    private func propertyRow<Value: View>(_ icon: String, _ label: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value().multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .frame(minHeight: 34)
        .contentShape(Rectangle())
    }

    private var projectRow: some View {
        Menu {
            ForEach(app.projects) { p in
                Button { moveTask(to: p.id) } label: { Label(p.name, systemImage: p.id == model.task.projectID ? "checkmark" : "circle.fill") }
            }
        } label: {
            propertyRow("folder", "task.project") {
                HStack(spacing: 6) {
                    ProjectDot(id: model.task.projectID)
                    Text(verbatim: project?.name ?? "").foregroundStyle(.primary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var dueRow: some View {
        let due = model.planning.dueAt
        return propertyRow("calendar", "task.due") {
            Menu {
                Button("due.today") { setDue(DueFormat.today()) }
                Button("due.tomorrow") { setDue(DueFormat.tomorrow()) }
                Button("due.weekend") { setDue(DueFormat.weekend()) }
                Button("due.nextWeek") { setDue(DueFormat.nextWeek()) }
                Button("due.pick") { if model.planning.dueAt == nil { setDue(DueFormat.tomorrow()) }; withAnimation { pickingDate.toggle() } }
                if due != nil { Button("due.none", role: .destructive) { pickingDate = false; setDue(nil) } }
            } label: {
                if let due {
                    Text(verbatim: DueFormat.text(due)).foregroundStyle(DueFormat.style(due).color)
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

    private var priorityRow: some View {
        let p = model.planning.priority
        return propertyRow("flag", "task.priority") {
            Menu {
                ForEach([3, 2, 1, 0], id: \.self) { v in
                    Button { setPriority(v) } label: { Label { priorityLabel(v) } icon: { Image(systemName: v == p ? "checkmark" : "flag.fill") } }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: p > 0 ? "flag.fill" : "flag").foregroundStyle(Color.priority(p))
                    priorityLabel(p)
                }
            }
            .tint(.primary)
        }
    }

    private var labelsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            propertyRow("tag", "task.labels") {
                Menu {
                    ForEach(model.allLabels) { l in
                        Button { Task { await model.toggleLabel(l, app); await meta.refresh(app) } } label: {
                            Label(l.name, systemImage: model.labels.contains(where: { $0.id == l.id }) ? "checkmark" : "tag")
                        }
                    }
                } label: {
                    if model.labels.isEmpty { Text("label.add") } else {
                        HStack { ForEach(model.labels) { LabelChip(name: $0.name) } }
                    }
                }
            }
            TextField("label.new", text: $newLabel).font(.footnote).onSubmit {
                let name = newLabel; newLabel = ""
                Task { await model.createLabel(name, app); await meta.refresh(app) }
            }
            .padding(.leading, 34)
        }
    }

    private var statusRow: some View {
        propertyRow("circle.dashed", "task.status") {
            Picker("task.status", selection: statusBinding) {
                ForEach(TaskStatus.allCases, id: \.self) { statusLabel($0).tag($0) }
            }
            .labelsHidden().tint(.primary)
        }
    }

    private func setDue(_ date: Date?) {
        model.planning.dueAt = date
        Task { await model.savePlanning(app); await meta.refresh(app) }
    }

    private func setPriority(_ p: Int) {
        Haptics.tap()
        model.planning.priority = p
        Task { await model.savePlanning(app); await meta.refresh(app) }
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

    @ViewBuilder private var commentsSection: some View {
        Section {
            ForEach(model.comments) { c in
                HStack(alignment: .top, spacing: 10) {
                    Text(verbatim: String((c.authorName ?? "?").prefix(1)).uppercased())
                        .font(.caption.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26).background(Color.project(c.authorID), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: c.authorName ?? "?").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(verbatim: c.body).font(.subheadline)
                    }
                }
                .swipeActions {
                    if c.authorID == app.user?.id {
                        Button("comment.delete", role: .destructive) { Task { await model.deleteComment(c, app) } }
                    }
                }
            }
            HStack {
                TextField("comment.new", text: $newComment, axis: .vertical)
                Button {
                    let t = newComment; newComment = ""
                    Task { await model.addComment(t, app) }
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.brand) }
                .buttonStyle(.plain)
                .disabled(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(Text("comment.send"))
            }
        } header: { SectionHeaderLabel(title: "task.comments", count: model.comments.isEmpty ? nil : model.comments.count) }
    }
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
