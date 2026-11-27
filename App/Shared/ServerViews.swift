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
        LiveHub.shared.subscribe(self) { [weak self] in await self?.load(app) }
        do { let new = try await client.projectComments(projectID); if new != comments { comments = new }; offline = false }
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
    init(model: ProjectCommentsModel) { _model = State(initialValue: model) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.comments) { c in
                    HStack(alignment: .top, spacing: Space.m) {
                        Text(verbatim: String((c.authorName ?? "?").prefix(1)).uppercased())
                            .font(.caption.weight(.bold)).foregroundStyle(.white)
                            .scaledSquare(Space.xxl, relativeTo: .caption).background(Color.project(c.authorID), in: Circle())
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            AdaptiveStack(spacing: Space.s) {
                                Text(verbatim: c.authorName ?? "?").font(.caption.weight(.semibold))
                                if let d = c.createdAt { Text(d, style: .relative).font(.caption).foregroundStyle(Color.textSecondary) }
                            }
                            MarkdownText(c.body).font(.subheadline).textSelection(.enabled)
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
                HStack(alignment: .bottom, spacing: Space.s) {
                    TextField(accessible: "comment.new", text: $draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
                    Button {
                        let t = draft; draft = ""
                        Task { await model.add(t, app) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                            .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.textSecondary : Color.brand)
                    }
                    .buttonStyle(.plain).tapTarget().disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(Text("comment.send"))
                }
                .readableWidth().pageMargins().padding(.vertical, Space.m)
                .background(.bar)
            }
            .navigationTitle("project.comments")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("ok") { dismiss() } } }
            .task { await model.load(app) }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 480, idealHeight: 600)
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
        LiveHub.shared.subscribe(self) { [weak self] in await self?.load(app) }
        do {
            let feed = try await client.activityFeed(limit: 50, before: more ? next : nil)
            // A page asked for twice (two taps on "Mehr", a refresh that overlaps) must not repeat entries.
            if more { items = items.appendingPage(feed.items); next = feed.nextCursor }
            else if items.count <= 50 { if items != feed.items { items = feed.items }; next = feed.nextCursor }
            // else: the user paged further; a live refresh keeps the longer list.
            offline = false
        } catch APIError.transport { offline = true }
        catch { await app.handle(error) }
        loaded = true
    }
}

struct ActivityView: View {
    @Environment(AppModel.self) private var app
    @State private var model: ActivityModel

    init(model: ActivityModel? = nil) { _model = State(initialValue: model ?? ActivityModel()) }

    var body: some View {
        List {
            ForEach(model.items) { item in
                HStack(alignment: .top, spacing: Space.m) {
                    Image(systemName: Self.symbol(item)).foregroundStyle(Color.textSecondary).scaledSquare(Space.xl, relativeTo: .subheadline)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        AdaptiveStack(spacing: Space.xs) {
                            Text(verbatim: actor(item)).fontWeight(.semibold)
                            activityText(item.kind).foregroundStyle(Color.textSecondary)
                        }
                        .font(.subheadline)
                        if let title = item.taskTitle { Text(verbatim: title).font(.subheadline).lineLimit(2) }
                        AdaptiveStack(spacing: Space.xs) {
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
            LiveHub.shared.subscribe(self) { [weak self] in await self?.load(app) }
            let newDevices = try await client.agentDevices()
            if devices != newDevices { devices = newDevices }
            do { let newJobs = try await client.agentJobs(limit: 50).items; if jobs != newJobs { jobs = newJobs }; forbidden = false }
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
    @State private var model: AgentsModel

    init(model: AgentsModel? = nil) { _model = State(initialValue: model ?? AgentsModel()) }

    var body: some View {
        List {
            Section {
                ForEach(model.devices) { d in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        AdaptiveStack(spacing: Space.s) {
                            Image(systemName: "desktopcomputer").foregroundStyle(Color.textSecondary)
                            Text(verbatim: d.label).font(.body.weight(.semibold))
                            Spacer()
                            if d.revokedAt != nil { Text("runner.revoked").foregroundStyle(Color.dueOverdue) }
                            else if !d.paired { Text("runner.unpaired").foregroundStyle(Color.priority(2)) }
                            else if d.activeRunCount > 0 { Text("runner.active \(d.activeRunCount)").foregroundStyle(Color.brand) }
                            else { Text("runner.idle").foregroundStyle(Color.textSecondary) }
                        }
                        .font(.subheadline)
                        ForEach(d.bindings) { b in
                            AdaptiveStack(spacing: Space.xs) {
                                ProjectDot(id: b.projectID, size: 7)
                                Text(verbatim: app.projects.first { $0.id == b.projectID }?.name ?? b.label)
                                Text(verbatim: b.repositoryKey).foregroundStyle(Color.textSecondary)
                            }
                            .font(.caption).foregroundStyle(Color.textSecondary)
                        }
                    }
                    .padding(.vertical, Space.xxs)
                }
                if model.loaded && model.devices.isEmpty {
                    Text("runner.noDevices").font(.subheadline).foregroundStyle(Color.textSecondary)
                }
            } header: { SectionHeaderLabel(title: "runner.devices") }
            Section {
                ForEach(model.jobs) { item in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        AdaptiveStack(spacing: Space.s) {
                            Text(verbatim: item.taskTitle).font(.body).lineLimit(2)
                            Spacer()
                            jobStateText(item.job.state).font(.caption.weight(.semibold))
                                .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                                .background(Self.tint(item.job.state).opacity(0.10), in: Capsule())
                                .foregroundStyle(Self.tint(item.job.state))
                        }
                        if let p = item.job.progress, !p.isEmpty { Text(verbatim: p).font(.footnote).foregroundStyle(Color.textSecondary).lineLimit(2) }
                        if let r = item.job.result { MarkdownText(r.summary).font(.footnote).foregroundStyle(Color.textSecondary).lineLimit(3) }
                        AdaptiveStack(spacing: Space.xs) {
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
        case "succeeded": Color.dueToday
        case "failed", "cancelled": Color.dueOverdue
        case "waiting_for_answer", "awaiting_review": Color.priority(2)
        case "running", "claimed": Color.brand
        default: Color.textSecondary
        }
    }
}

// MARK: Previews

#if DEBUG
private enum ServerPreviewData {
    static func decode<T: Decodable>(_ json: String) -> T {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static let user = "11111111-1111-1111-1111-111111111111"
    static let project = "22222222-2222-2222-2222-222222222222"

    @MainActor static var comments: ProjectCommentsModel {
        let model = ProjectCommentsModel(projectID: UUID())
        let items: [ProjectComment] = decode("""
        [{"id":"\(UUID())","projectID":"\(project)","authorID":"\(user)","authorName":"Lino","body":"Der Zeitplan steht, die Abnahme ist am Freitag.","version":1,"createdAt":0},
         {"id":"\(UUID())","projectID":"\(project)","authorID":"\(UUID())","authorName":"Annalena","body":"Donaudampfschifffahrtsgesellschaftskapitaensmuetze ist als Beispiel fuer ein sehr langes deutsches Wort gedacht.","version":1,"createdAt":0}]
        """)
        model.comments = items
        model.loaded = true
        return model
    }

    @MainActor static var activity: ActivityModel {
        let model = ActivityModel()
        let items: [ActivityItem] = decode("""
        [{"source":"task","id":"\(UUID())","projectID":"\(project)","projectName":"Todolino","taskID":"\(UUID())","taskTitle":"Registrierung per Einladung pruefen","sequence":1,"actorType":"Person","actorID":"\(user)","actorName":"Lino","kind":"comment.created","createdAt":0},
         {"source":"task","id":"\(UUID())","projectID":"\(project)","projectName":"Todolino","taskID":null,"taskTitle":null,"sequence":2,"actorType":"Run","actorID":"\(UUID())","actorName":null,"kind":"agent.released","createdAt":0}]
        """)
        model.items = items
        model.loaded = true
        return model
    }

    @MainActor static var agents: AgentsModel {
        let model = AgentsModel()
        let devices: [RunnerDevice] = decode("""
        [{"id":"\(UUID())","label":"Mac mini im Buero","paired":true,"revokedAt":null,"activeRunCount":1,
          "bindings":[{"id":"\(UUID())","projectID":"\(project)","deviceID":"\(UUID())","repositoryKey":"todo/apple","label":"Apple"}]},
         {"id":"\(UUID())","label":"MacBook","paired":false,"revokedAt":null,"activeRunCount":0,"bindings":[]}]
        """)
        let jobs: [AgentJobListItem] = decode("""
        [{"job":{"id":"\(UUID())","taskID":"\(UUID())","projectID":"\(project)","mode":"implement","state":"running","progress":"Baue iOS und macOS","result":null},
          "taskTitle":"Anmeldung: Lesebreite fuer Formulare","projectName":"Todolino","createdAt":0},
         {"job":{"id":"\(UUID())","taskID":"\(UUID())","projectID":"\(project)","mode":"clarify","state":"waiting_for_answer","progress":null,"result":null},
          "taskTitle":"Rueckfrage zur Passkey-Wiederherstellung","projectName":"Todolino","createdAt":0}]
        """)
        model.devices = devices
        model.jobs = jobs
        model.loaded = true
        return model
    }
}

private struct ServerPreview: View {
    enum Kind { case comments, activity, agents }
    let kind: Kind
    var body: some View {
        Group {
            switch kind {
            case .comments: ProjectCommentsView(model: ServerPreviewData.comments)
            case .activity: NavigationStack { ActivityView(model: ServerPreviewData.activity) }
            case .agents: NavigationStack { AgentsView(model: ServerPreviewData.agents) }
            }
        }
        .environment(AppModel())
    }
}

#Preview("Kommentare light") { ServerPreview(kind: .comments).preferredColorScheme(.light) }
#Preview("Kommentare dark") { ServerPreview(kind: .comments).preferredColorScheme(.dark) }
#Preview("Kommentare accessibility5") { ServerPreview(kind: .comments).dynamicTypeSize(.accessibility5) }
#Preview("Aktivitaet light") { ServerPreview(kind: .activity).preferredColorScheme(.light) }
#Preview("Aktivitaet dark") { ServerPreview(kind: .activity).preferredColorScheme(.dark) }
#Preview("Aktivitaet accessibility5") { ServerPreview(kind: .activity).dynamicTypeSize(.accessibility5) }
#Preview("Runner light") { ServerPreview(kind: .agents).preferredColorScheme(.light) }
#Preview("Runner dark") { ServerPreview(kind: .agents).preferredColorScheme(.dark) }
#Preview("Runner accessibility5") { ServerPreview(kind: .agents).dynamicTypeSize(.accessibility5) }
#endif
