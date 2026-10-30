import SwiftUI
import TodoCore

/// Sidebar (iPad/Mac) and Browse list (iPhone): account header, quick add, main entries, "Mehr", favorites,
/// project tree, teams, help.
struct SidebarList: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta
    @Environment(\.projectActions) private var actions
    let linking: Bool
    @State private var projectsExpanded = true
    @State private var favoritesExpanded = true
    @State private var teamsExpanded = true
    @State private var moreExpanded = false
    @State private var showHelp = false

    private var dayNumber: Int { Calendar.current.component(.day, from: Date()) }
    private var inboxCount: Int { model.tasks.filter { !$0.isDone && meta.planning(for: $0.id)?.dueAt == nil }.count }
    private var openCounts: [UUID: Int] {
        Dictionary(grouping: model.tasks.filter { !$0.isDone }, by: \.projectID).mapValues(\.count)
    }
    private var favoriteProjects: [Project] { model.favoriteProjects }

    var body: some View {
        @Bindable var model = model
        let counts = openCounts
        List(selection: $model.selection) {
            Section {
                Button { actions.addTask() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(Color.brand)
                        Text("task.add").font(.body.weight(.semibold)).foregroundStyle(Color.brand)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .listRowBackground(Color.clear)
            }
            Section {
                row(.search, "view.search", "magnifyingglass", .secondary)
                row(.inbox, "view.inbox", "tray", .secondary, count: inboxCount)
                row(.today, "view.today", "\(min(dayNumber, 50)).square", .secondary, count: model.today.count + meta.overdue.count)
                row(.upcoming, "view.upcoming", "calendar", .secondary)
                row(.labels, "view.labels", "square.grid.2x2", .secondary)
                Button { withAnimation { moreExpanded.toggle() } } label: {
                    Label { Text("view.more") } icon: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if moreExpanded {
                    row(.teams, "view.teams", "person.2", .secondary, count: model.teamInvitations.count).padding(.leading, 12)
                    row(.account, "view.account", "gearshape", .secondary).padding(.leading, 12)
                    row(.activity, "view.activity", "clock.arrow.circlepath", .secondary).padding(.leading, 12)
                    row(.runner, "view.runner", "terminal", .secondary).padding(.leading, 12)
                }
            }
            if !favoriteProjects.isEmpty {
                Section(isExpanded: $favoritesExpanded) {
                    ForEach(favoriteProjects) { p in
                        projectLabel(p, count: counts[p.id] ?? 0)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedProjectID = p.id }
                            .listRowBackground(model.selectedProjectID == p.id ? Color.brand.opacity(0.12) : Color.clear)
                            .contextMenu { projectMenu(p) }
                    }
                } header: { Text("favorites.title") }
            }
            Section(isExpanded: $projectsExpanded) {
                OutlineGroup(model.tree, children: \.children) { node in
                    link(.project(node.id)) { projectLabel(node.project, count: counts[node.id] ?? 0) }
                        .contextMenu { projectMenu(node.project) }
                        .draggable(BoardDrag(kind: .project, id: node.id))
                        .modifier(ProjectDropTarget(project: node.project))
                }
                .onDrop(of: [.json], isTargeted: nil) { _ in false }
                if !model.tree.isEmpty {
                    RootDropZone()
                }
                if model.tree.isEmpty {
                    Text("projects.none").font(.subheadline).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("projects.mine")
                    Spacer()
                    Button { actions.addProject(nil) } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(Text("project.add"))
                }
            }
            if !model.teams.isEmpty {
                Section(isExpanded: $teamsExpanded) {
                    ForEach(model.teams) { team in
                        Button { model.selection = .teams } label: {
                            Label { Text(verbatim: team.name) } icon: { Image(systemName: "person.2.fill").foregroundStyle(Color.priority(1)) }
                        }
                        .buttonStyle(.plain)
                    }
                } header: { Text("sidebar.teams") }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.canvasRaised)
        .safeAreaInset(edge: .top, spacing: 0) { AccountHeader() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { showHelp = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                    Text("help.title")
                    Spacer()
                }
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showHelp) { HelpView() }
        .task { await model.reloadTeams() }
    }

    private func projectLabel(_ p: Project, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "#").font(.headline).foregroundStyle(model.projectColor(p.id)).frame(width: 14)
            Text(verbatim: p.name).lineLimit(1)
            Spacer(minLength: 4)
            if count > 0 { Text(verbatim: String(count)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
    }

    @ViewBuilder private func projectMenu(_ p: Project) -> some View {
        Button { Task { await model.toggleFavorite(p) } } label: {
            Label(p.isFavorite ? "project.unfavorite" : "project.favorite", systemImage: p.isFavorite ? "star.slash" : "star")
        }
        Button { actions.addProject(p.id) } label: { Label("project.addSub", systemImage: "plus") }
        Button { actions.share(p) } label: { Label("project.share", systemImage: "person.badge.plus") }
        Button(role: .destructive) { Task { await model.deleteProject(p) } } label: { Label("project.delete", systemImage: "trash") }
    }

    /// Sidebar rows select through the list; on iPhone (Browse tab) they push through NavigationLink.
    @ViewBuilder private func link<Content: View>(_ item: SidebarItem, @ViewBuilder _ content: () -> Content) -> some View {
        if linking { NavigationLink(value: item) { content() } } else { content().tag(item) }
    }

    private func row(_ item: SidebarItem, _ title: LocalizedStringKey, _ symbol: String, _ tint: Color, count: Int = 0) -> some View {
        link(item) {
            HStack {
                Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
                Spacer(minLength: 4)
                if count > 0 { Text(verbatim: String(count)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
    }
}

/// Avatar + name menu and notification bell (pending team invitations). The sidebar toggle comes from the split view.
struct AccountHeader: View {
    @Environment(AppModel.self) private var model
    @State private var showNotifications = false

    private var initials: String {
        let parts = (model.user?.displayName ?? "?").split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Text(verbatim: model.user?.displayName ?? "")
                Button { model.selection = .account } label: { Label("view.account", systemImage: "gearshape") }
                Button { model.selection = .teams } label: { Label("view.teams", systemImage: "person.2") }
                Divider()
                Button("logout", role: .destructive) { Task { await model.logout() } }
            } label: {
                HStack(spacing: 8) {
                    Text(verbatim: initials).font(.caption.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(Color.brand, in: Circle())
                    Text(verbatim: model.user?.displayName ?? "").font(.body.weight(.semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            Spacer()
            Button { showNotifications = true } label: {
                Image(systemName: "bell").overlay(alignment: .topTrailing) {
                    if !model.teamInvitations.isEmpty { Circle().fill(Color.brand).frame(width: 8, height: 8).offset(x: 3, y: -3) }
                }
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel(Text("notifications.title"))
            .popover(isPresented: $showNotifications) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("notifications.title").font(.headline)
                    if model.teamInvitations.isEmpty {
                        Text("notifications.empty").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Button { showNotifications = false; model.selection = .teams } label: {
                            Label { Text("notifications.invitations \(model.teamInvitations.count)") } icon: { Image(systemName: "person.2.badge.plus") }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16).frame(minWidth: 240, alignment: .leading)
                .presentationCompactAdaptation(.popover)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.canvasRaised)
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section("help.tips") {
                    Label("help.tip.quickAdd", systemImage: "plus.circle")
                    Label("help.tip.board", systemImage: "rectangle.split.3x1")
                    Label("help.tip.offline", systemImage: "icloud.slash")
                }
                Section("help.about") {
                    LabeledContent("login.server") { Text(verbatim: model.serverURL).font(.footnote).textSelection(.enabled) }
                    LabeledContent("help.version") { Text(verbatim: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") }
                }
            }
            .navigationTitle("help.title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("ok") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }
}

/// The screen for a sidebar / browse destination.
struct SidebarScreen: View {
    let item: SidebarItem?

    var body: some View {
        switch item {
        case .inbox: InboxView()
        case .today, nil: TodayView()
        case .upcoming: UpcomingView()
        case .search: SearchView()
        case .teams: TeamsView()
        case .labels: LabelsView()
        case .label(let id): LabelTasksView(labelID: id)
        case .account: AccountView()
        case .runner: AgentsView()
        case .activity: ActivityView()
        case .project(let id): ProjectView(projectID: id).id(id)
        }
    }
}

// MARK: Filter und Etiketten

struct LabelsView: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta

    var body: some View {
        List {
            Section {
                ForEach(meta.allLabels) { l in
                    Button { model.selection = .label(l.id) } label: {
                        HStack {
                            Label { Text(verbatim: l.name) } icon: { Image(systemName: "tag").foregroundStyle(Color.project(l.id)) }
                            Spacer()
                            Text(verbatim: String(meta.labelsByTask.values.filter { $0.contains { $0.id == l.id } }.count)).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).taskRowInsets()
                }
            } header: { SectionHeaderLabel(title: "task.labels") }
        }
        .taskListStyle()
        .overlay { if meta.allLabels.isEmpty { EmptyState(symbol: "tag", title: "labels.empty", message: "labels.emptyHint") } }
        .navigationTitle("view.labels")
    }
}

struct LabelTasksView: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta
    let labelID: UUID
    @State private var hits: [TodoTask] = []

    private var label: TaskLabel? { meta.allLabels.first { $0.id == labelID } }

    var body: some View {
        List { ForEach(hits) { TaskRow(task: $0).taskRowInsets() } }
            .taskListStyle()
            .overlay { if hits.isEmpty { EmptyState(symbol: "tag", title: "labels.noTasks") } }
            .navigationTitle(label?.name ?? "")
            .task(id: model.tasks.count) {
                guard let client = model.client else { return }
                hits = ((try? await client.search(nil, labelID: labelID, limit: 100).items) ?? []).compactMap(\.task)
            }
            .quickAdd()
    }
}

// MARK: Konto, Agenten/Runner

struct AccountView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                LabeledContent("account.name") { Text(verbatim: model.user?.displayName ?? "") }
                if let u = model.user?.username { LabeledContent("account.username") { Text(verbatim: u) } }
                LabeledContent("login.server") { Text(verbatim: model.serverURL).textSelection(.enabled) }
            }
            Section {
                Button("logout", role: .destructive) { Task { await model.logout() } }
            }
        }
        .navigationTitle("view.account")
    }
}

/// Drop target on a sidebar project row: upper quarter = before, lower quarter = after, middle = into (child).
struct ProjectDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var zone: ProjectDropZone?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { if zone == .before { line } }
            .overlay(alignment: .bottom) { if zone == .after { line } }
            .background(zone == .into ? Color.brand.opacity(0.15) : Color.clear)
            .dropDestination(for: BoardDrag.self) { items, location in
                guard let drag = items.first, drag.kind == .project else { return false }
                let z = Self.zone(at: location.y)
                Task { await model.dropProject(drag.id, on: project, zone: z) }
                return true
            } isTargeted: { targeted in if !targeted { zone = nil } else if zone == nil { zone = .into } }
    }

    private var line: some View { Rectangle().fill(Color.brand).frame(height: 2) }

    static func zone(at y: CGFloat) -> ProjectDropZone { y < 10 ? .before : (y > 26 ? .after : .into) }
}

/// Dropping here makes a project a top-level project at the end.
struct RootDropZone: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    var body: some View {
        Text("projects.dropRoot").font(.caption).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(targeted ? Color.brand.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .dropDestination(for: BoardDrag.self) { items, _ in
                guard let drag = items.first, drag.kind == .project else { return false }
                Task { await model.moveProject(drag.id, toParent: nil, at: nil) }
                return true
            } isTargeted: { targeted = $0 }
    }
}
