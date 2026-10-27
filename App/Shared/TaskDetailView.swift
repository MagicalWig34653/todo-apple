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
        do {
            async let p = client.planning(taskID: task.id)
            async let c = client.comments(taskID: task.id)
            async let a = client.activity(taskID: task.id, limit: 30)
            async let f = client.attachments(taskID: task.id)
            async let l = client.labels(taskID: task.id)
            async let al = client.labels()
            let planned = try await p
            task = planned.task; planning = planned.planning
            comments = try await c; activity = try await a.items; attachments = try await f
            labels = try await l.items; allLabels = try await al.items
            loaded = true
        } catch { await app.handle(error) }
    }

    func savePlanning(_ app: AppModel) async {
        guard let client = app.client else { return }
        do {
            let result = try await client.setPlanning(taskID: task.id, planning)
            task = result.task; planning = result.planning
            await app.reloadAgenda()
        } catch { await app.handle(error); await load(app) }
    }

    func saveText(title: String, description: String, _ app: AppModel) async {
        guard let client = app.client else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != task.title || description != task.description else { return }
        do {
            task = try await client.updateTask(task.id, version: task.version, TaskUpdate(title: title, description: description))
            app.apply(task)
        } catch { await app.handle(error); await load(app) }
    }

    func setStatus(_ status: TaskStatus, _ app: AppModel) async {
        guard let client = app.client else { return }
        do {
            task = try await client.updateTask(task.id, version: task.version, TaskUpdate(status: status))
            app.apply(task)
            await app.reloadAgenda()
        } catch { await app.handle(error); await load(app) }
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
    @State private var model: TaskDetailModel
    @State private var title: String
    @State private var text: String
    @State private var newComment = ""
    @State private var newLabel = ""

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
        case 1: Text("priority.1")
        case 2: Text("priority.2")
        case 3: Text("priority.3")
        default: Text("priority.0")
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("task.title", text: $title).onSubmit(saveText)
                TextField("task.description", text: $text, axis: .vertical).lineLimit(2...8)
                Picker("task.status", selection: statusBinding) {
                    ForEach(TaskStatus.allCases, id: \.self) { statusLabel($0).tag($0) }
                }
            }
            planningSection
            labelsSection
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
        .formStyle(.grouped)
        .navigationTitle(model.task.title)
        .task { await model.load(app); title = model.task.title; text = model.task.description }
        .onDisappear { saveText() }
    }

    private func saveText() { Task { await model.saveText(title: title, description: text, app) } }

    @ViewBuilder private var planningSection: some View {
        Section("task.planning") {
            optionalDate("task.due", \.dueAt)
            optionalDate("task.planned", \.plannedAt)
            Picker("task.priority", selection: Binding(
                get: { model.planning.priority },
                set: { model.planning.priority = $0; Task { await model.savePlanning(app) } })
            ) {
                ForEach(0...3, id: \.self) { priorityLabel($0).tag($0) }
            }
        }
    }

    private func optionalDate(_ label: LocalizedStringKey, _ keyPath: WritableKeyPath<PlanningData, Date?>) -> some View {
        let binding = Binding<Date?>(
            get: { model.planning[keyPath: keyPath] },
            set: { model.planning[keyPath: keyPath] = $0; Task { await model.savePlanning(app) } })
        return HStack {
            Toggle(label, isOn: Binding(
                get: { binding.wrappedValue != nil },
                set: { binding.wrappedValue = $0 ? Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600) : nil }))
            if let date = binding.wrappedValue {
                DatePicker("", selection: Binding(get: { date }, set: { binding.wrappedValue = $0 }))
                    .labelsHidden()
            }
        }
    }

    @ViewBuilder private var labelsSection: some View {
        Section("task.labels") {
            ForEach(model.allLabels) { label in
                Button { Task { await model.toggleLabel(label, app) } } label: {
                    HStack {
                        Text(verbatim: label.name)
                        Spacer()
                        if model.labels.contains(where: { $0.id == label.id }) { Image(systemName: "checkmark") }
                    }
                }
                .buttonStyle(.plain)
            }
            TextField("label.new", text: $newLabel).onSubmit {
                let name = newLabel; newLabel = ""
                Task { await model.createLabel(name, app) }
            }
        }
    }

    @ViewBuilder private var commentsSection: some View {
        Section("task.comments") {
            ForEach(model.comments) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: c.authorName ?? "?").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: c.body)
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
                } label: { Image(systemName: "paperplane") }
                .disabled(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(Text("comment.send"))
            }
        }
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
