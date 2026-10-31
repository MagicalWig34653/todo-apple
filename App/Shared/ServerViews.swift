import SwiftUI
import TodoCore

// MARK: Project comments sheet (the "Kommentare" toolbar button)

@MainActor @Observable
final class ProjectCommentsModel {
    let projectID: UUID
    var comments: [ProjectComment] = []
    var loaded = false
    var offline = false
    init(projectID: UUID) { self.projectID = projectID }

    func load(_ app: AppModel) async {
        guard let client = app.client else { return }
        do { comments = try await client.projectComments(projectID); offline = false }
        catch APIError.transport { offline = true }
        catch { await app.handle(error) }
        loaded = true
    }

    func add(_ text: String, _ app: AppModel) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = app.client, !text.isEmpty else { return }
        do { _ = try await client.addProjectComment(projectID, body: text); await load(app) }
        catch { await app.handle(error) }
    }

    func delete(_ c: ProjectComment, _ app: AppModel) async {
        guard let client = app.client else { return }
        do { try await client.deleteProjectComment(projectID, id: c.id, version: c.version); await load(app) }
        catch { await app.handle(error) }
    }
}

struct ProjectCommentsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: ProjectCommentsModel
    @State private var draft = ""

    init(projectID: UUID) { _model = State(initialValue: ProjectCommentsModel(projectID: projectID)) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.comments) { c in
                    HStack(alignment: .top, spacing: 10) {
                        Text(verbatim: String((c.authorName ?? "?").prefix(1)).uppercased())
                            .font(.caption.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 28, height: 28).background(Color.project(c.authorID), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(verbatim: c.authorName ?? "?").font(.caption.weight(.semibold))
                                if let d = c.createdAt { Text(d, style: .relative).font(.caption).foregroundStyle(Color.textSecondary) }
                            }
                            Text(verbatim: c.body).font(.subheadline).textSelection(.enabled)
                        }
                    }
                    .swipeActions {
                        if c.authorID == app.user?.id {
                            Button("comment.delete", role: .destructive) { Task { await model.delete(c, app) } }
                        }
                    }
                    .contextMenu {
                        if c.authorID == app.user?.id {
                            Button("comment.delete", role: .destructive) { Task { await model.delete(c, app) } }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if model.loaded && model.comments.isEmpty {
                    EmptyState(symbol: "bubble.left", title: "projectComments.empty", message: "projectComments.emptyHint")
                } else if model.offline && model.comments.isEmpty {
                    EmptyState(symbol: "icloud.slash", title: "error.network")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(alignment: .bottom) {
                    TextField("comment.new", text: $draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
                    Button {
                        let t = draft; draft = ""
                        Task { await model.add(t, app) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                            .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.brand)
                    }
                    .buttonStyle(.plain).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(Text("comment.send"))
                }
                .padding(12).background(.bar)
            }
            .navigationTitle("project.comments")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("ok") { dismiss() } } }
            .task { await model.load(app) }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }
}

// MARK: Activity ("Mehr" > Aktivität)

@MainActor @Observable
final class ActivityModel {
    var items: [ActivityItem] = []
    var next: String?
    var loaded = false
    var offline = false

    func load(_ app: AppModel, more: Bool = false) async {
        guard let client = app.client else { return }
        do {
            let feed = try await client.activityFeed(limit: 50, before: more ? next : nil)
            items = more ? items + feed.items : feed.items
            next = feed.nextCursor
            offline = false
        } catch APIError.transport { offline = true }
        catch { await app.handle(error) }
        loaded = true
    }
}

struct ActivityView: View {
    @Environment(AppModel.self) private var app
    @State private var model = ActivityModel()

    var body: some View {
        List {
            ForEach(model.items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: Self.symbol(item)).foregroundStyle(Color.textSecondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(verbatim: actor(item)).fontWeight(.semibold)
                            activityText(item.kind).foregroundStyle(Color.textSecondary)
                        }
                        .font(.subheadline)
                        if let title = item.taskTitle { Text(verbatim: title).font(.subheadline).lineLimit(2) }
                        HStack(spacing: 6) {
                            ProjectDot(id: item.projectID, size: 7)
                            Text(verbatim: item.projectName)
                            if let d = item.createdAt { Text(d, style: .relative) }
                        }
                        .font(.caption).foregroundStyle(Color.textSecondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { open(item) }
                .accessibilityAddTraits(.isButton)
                .taskRowInsets()
            }
            if model.next != nil {
                Button("activity.more") { Task { await model.load(app, more: true) } }.frame(maxWidth: .infinity)
            }
        }
        .taskListStyle()
        .overlay {
            if model.loaded && model.items.isEmpty { EmptyState(symbol: "clock.arrow.circlepath", title: "activity.empty") }
            else if model.offline && model.items.isEmpty { EmptyState(symbol: "icloud.slash", title: "error.network") }
        }
        .navigationTitle("view.activity")
        .refreshable { await model.load(app) }
        .task { await model.load(app) }
    }

    private func actor(_ i: ActivityItem) -> String {
        if let n = i.actorName { return n }
        return i.actorType == "Run" ? String(localized: "activity.actor.agent") : String(localized: "activity.actor.integration")
    }

    private func open(_ i: ActivityItem) {
        if let t = i.taskID, let task = app.tasks.first(where: { $0.id == t }) { app.path = [task] }
        else if app.projects.contains(where: { $0.id == i.projectID }) { app.selectedProjectID = i.projectID }
    }

    static func symbol(_ i: ActivityItem) -> String {
        if i.kind.hasPrefix("comment") { return "bubble.left" }
        if i.kind.hasPrefix("agent") { return "terminal" }
        if i.kind.hasPrefix("criterion") { return "checklist" }
        return i.kind == "task.status_changed" ? "checkmark.circle" : "pencil"
    }
}

// MARK: Agents (devices and jobs, read only)

@MainActor @Observable
final class AgentsModel {
    var devices: [RunnerDevice] = []
    var jobs: [AgentJobListItem] = []
    var loaded = false
    var offline = false
    var forbidden = false

    func load(_ app: AppModel) async {
        guard let client = app.client else { return }
        do {
            devices = try await client.agentDevices()
            do { jobs = try await client.agentJobs(limit: 50).items; forbidden = false }
            catch APIError.forbidden { forbidden = true }
            offline = false
        } catch APIError.transport { offline = true }
        catch { await app.handle(error) }
        loaded = true
    }
}

@ViewBuilder func jobStateText(_ state: String) -> some View {
    switch state {
    case "queued": Text("job.state.queued")
    case "claimed": Text("job.state.claimed")
    case "running": Text("job.state.running")
    case "waiting_for_answer": Text("job.state.waiting")
    case "awaiting_review": Text("job.state.review")
    case "succeeded": Text("job.state.succeeded")
    case "failed": Text("job.state.failed")
    case "cancelled": Text("job.state.cancelled")
    default: Text(verbatim: state)
    }
}

struct AgentsView: View {
    @Environment(AppModel.self) private var app
    @State private var model = AgentsModel()

    var body: some View {
        List {
            Section {
                ForEach(model.devices) { d in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "desktopcomputer").foregroundStyle(Color.textSecondary)
                            Text(verbatim: d.label).font(.body.weight(.semibold))
                            Spacer()
                            if d.revokedAt != nil { Text("runner.revoked").foregroundStyle(.red) }
                            else if !d.paired { Text("runner.unpaired").foregroundStyle(.orange) }
                            else if d.activeRunCount > 0 { Text("runner.active \(d.activeRunCount)").foregroundStyle(Color.brand) }
                            else { Text("runner.idle").foregroundStyle(Color.textSecondary) }
                        }
                        .font(.subheadline)
                        ForEach(d.bindings) { b in
                            HStack(spacing: 6) {
                                ProjectDot(id: b.projectID, size: 7)
                                Text(verbatim: app.projects.first { $0.id == b.projectID }?.name ?? b.label)
                                Text(verbatim: b.repositoryKey).foregroundStyle(Color.textSecondary)
                            }
                            .font(.caption).foregroundStyle(Color.textSecondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                if model.loaded && model.devices.isEmpty {
                    Text("runner.noDevices").font(.subheadline).foregroundStyle(Color.textSecondary)
                }
            } header: { SectionHeaderLabel(title: "runner.devices") }
            Section {
                ForEach(model.jobs) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(verbatim: item.taskTitle).font(.body).lineLimit(2)
                            Spacer()
                            jobStateText(item.job.state).font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Self.tint(item.job.state).opacity(0.15), in: Capsule())
                                .foregroundStyle(Self.tint(item.job.state))
                        }
                        if let p = item.job.progress, !p.isEmpty { Text(verbatim: p).font(.footnote).foregroundStyle(Color.textSecondary).lineLimit(2) }
                        if let r = item.job.result { Text(verbatim: r.summary).font(.footnote).foregroundStyle(Color.textSecondary).lineLimit(3) }
                        HStack(spacing: 6) {
                            ProjectDot(id: item.job.projectID, size: 7)
                            Text(verbatim: item.projectName)
                            Text(item.job.mode == "clarify" ? "job.mode.clarify" : "job.mode.implement")
                            if let d = item.createdAt { Text(d, style: .relative) }
                        }
                        .font(.caption).foregroundStyle(Color.textSecondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if let t = app.tasks.first(where: { $0.id == item.job.taskID }) { app.path = [t] } }
                    .accessibilityAddTraits(.isButton)
                }
                if model.loaded && model.jobs.isEmpty {
                    Text(model.forbidden ? "runner.jobsOwnerOnly" : "runner.noJobs").font(.subheadline).foregroundStyle(Color.textSecondary)
                }
            } header: { SectionHeaderLabel(title: "runner.jobs") }
        }
        .taskListStyle()
        .overlay { if model.offline && !model.loaded { EmptyState(symbol: "icloud.slash", title: "error.network") } }
        .navigationTitle("view.runner")
        .refreshable { await model.load(app) }
        .task { await model.load(app) }
    }

    static func tint(_ state: String) -> Color {
        switch state {
        case "succeeded": .green
        case "failed", "cancelled": .red
        case "waiting_for_answer", "awaiting_review": .orange
        case "running", "claimed": Color.brand
        default: .secondary
        }
    }
}
