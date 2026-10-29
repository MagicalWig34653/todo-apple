import SwiftUI
import TodoCore

/// Actions the project screens trigger on the root view (sheets and alerts live there).
struct ProjectActions {
    var addProject: (UUID?) -> Void = { _ in }
    var share: (Project) -> Void = { _ in }
}

private struct ProjectActionsKey: EnvironmentKey { static let defaultValue = ProjectActions() }
extension EnvironmentValues {
    var projectActions: ProjectActions {
        get { self[ProjectActionsKey.self] }
        set { self[ProjectActionsKey.self] = newValue }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var meta = TaskMeta()
    @State private var newProjectParent: UUID??  // .some(nil) = new root project
    @State private var newProjectName = ""
    @State private var shareProject: Project?

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if compact { PhoneTabs() } else { SplitLayout() }
        }
        .tint(.brand)
        .environment(meta)
        .environment(\.projectActions, ProjectActions(
            addProject: { newProjectName = ""; newProjectParent = .some($0) },
            share: { shareProject = $0 }))
        .task(id: TaskMeta.refreshKey(model)) { await meta.refresh(model) }
        .sheet(item: Binding(get: { model.path.last }, set: { if $0 == nil { model.path = [] } })) { task in
            NavigationStack { TaskDetailView(task: task) }
                .environment(model).environment(meta)
                #if os(macOS)
                .frame(minWidth: 520, idealWidth: 560, minHeight: 600)
                #endif
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $shareProject) { ShareView(project: $0) }
        .alert("project.new", isPresented: Binding(get: { newProjectParent != nil }, set: { if !$0 { newProjectParent = nil } })) {
            TextField("project.name", text: $newProjectName)
            Button("save") {
                let parent = newProjectParent ?? nil
                Task { await model.addProject(name: newProjectName, parentID: parent ?? nil) }
            }
            Button("cancel", role: .cancel) {}
        }
        .alert("sync.conflict.title", isPresented: Binding(get: { model.conflict != nil }, set: { _ in })) {
            Button("sync.conflict.keepMine") { Task { await model.resolveConflict(keepMine: true) } }
            Button("sync.conflict.useServer", role: .destructive) { Task { await model.resolveConflict(keepMine: false) } }
        } message: {
            Text("sync.conflict.message")
        }
        .alert(LocalizedStringKey(model.noticeKey ?? ""), isPresented: Binding(get: { model.noticeKey != nil }, set: { if !$0 { model.noticeKey = nil } })) {
            Button("ok") {}
        }
    }
}

/// Offline / pending-changes indicator; shown in the sidebar and under the detail stack (on iPhone only one is visible).
struct SyncStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.syncStatus == .offline || model.pendingChanges > 0 {
            HStack(spacing: 6) {
                Image(systemName: model.syncStatus == .offline ? "icloud.slash" : "arrow.triangle.2.circlepath")
                if model.syncStatus == .offline { Text("sync.offline") }
                if model.pendingChanges > 0 {
                    Text(verbatim: String(model.pendingChanges))
                    Text("sync.pending")
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(8)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }
}

// MARK: iPad / Mac: sidebar + detail

struct SplitLayout: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarList(linking: false)
                .navigationTitle("app.title")
                .safeAreaInset(edge: .bottom) { SyncStatusBar() }
        } detail: {
            NavigationStack {
                SidebarScreen(item: model.selection)
            }
            .safeAreaInset(edge: .bottom) { SyncStatusBar() }
        }
    }
}

// MARK: iPhone: bottom tab bar

struct PhoneTabs: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0
    @State private var browsePath: [SidebarItem] = []

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { TodayView() }
                .tabItem { Label("view.today", systemImage: "calendar") }.tag(0)
            NavigationStack { UpcomingView() }
                .tabItem { Label("view.upcoming", systemImage: "calendar.badge.clock") }.tag(1)
            NavigationStack { SearchView() }
                .tabItem { Label("view.search", systemImage: "magnifyingglass") }.tag(2)
            NavigationStack(path: $browsePath) {
                SidebarList(linking: true)
                    .navigationTitle("browse.title")
                    .navigationDestination(for: SidebarItem.self) { SidebarScreen(item: $0) }
            }
            .tabItem { Label("browse.title", systemImage: "square.grid.2x2") }.tag(3)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SyncStatusBar() }
        .onAppear { syncFromSelection(model.selection) }
        .onChange(of: model.selection) { _, new in syncFromSelection(new) }
        .onChange(of: tab) { _, new in
            switch new {
            case 0: model.selection = .today
            case 1: model.selection = .upcoming
            case 2: model.selection = .search
            default: break
            }
        }
    }

    private func syncFromSelection(_ item: SidebarItem?) {
        switch item {
        case .today, nil: tab = 0
        case .upcoming: tab = 1
        case .search: tab = 2
        case .inbox, .teams, .project:
            tab = 3
            if let item, browsePath.last != item { browsePath = [item] }
        }
    }
}

// MARK: Sidebar / Browse list

struct SidebarList: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta
    @Environment(\.projectActions) private var actions
    let linking: Bool
    @State private var projectsExpanded = true
    @State private var teamsExpanded = true

    private var dayNumber: Int { Calendar.current.component(.day, from: Date()) }
    private var inboxCount: Int { model.tasks.filter { !$0.isDone && meta.planning(for: $0.id)?.dueAt == nil }.count }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                row(.inbox, "view.inbox", "tray", .priority(1), count: inboxCount)
                row(.today, "view.today", "\(min(dayNumber, 50)).square", .dueToday, count: model.today.count + meta.overdue.count)
                row(.upcoming, "view.upcoming", "calendar", .dueTomorrow)
                row(.search, "view.search", "magnifyingglass", .secondary)
            }
            Section(isExpanded: $projectsExpanded) {
                OutlineGroup(model.tree, children: \.children) { node in
                    link(.project(node.id)) {
                        Label { Text(verbatim: node.project.name) } icon: { ProjectDot(id: node.id, size: 10) }
                    }
                    .contextMenu {
                        Button("project.addSub") { actions.addProject(node.id) }
                        Button("project.share") { actions.share(node.project) }
                        Button("project.delete", role: .destructive) { Task { await model.deleteProject(node.project) } }
                    }
                }
                Button { actions.addProject(nil) } label: {
                    Label("project.add", systemImage: "plus").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } header: { Text("projects.title") }
            Section(isExpanded: $teamsExpanded) {
                ForEach(model.teams) { team in
                    Button { model.selection = .teams } label: {
                        Label { Text(verbatim: team.name) } icon: { Image(systemName: "person.2.fill").foregroundStyle(Color.priority(1)) }
                    }
                    .buttonStyle(.plain)
                }
                row(.teams, "teams.all", "person.2", .secondary, count: model.teamInvitations.count)
            } header: { Text("view.teams") }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.canvasRaised)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Text(model.user?.displayName ?? "")
                    Button("logout", role: .destructive) { Task { await model.logout() } }
                } label: { Label("account", systemImage: "person.crop.circle") }
            }
        }
        .task { await model.reloadTeams() }
    }

    /// Sidebar rows select through the list; on iPhone (Browse tab) they push through NavigationLink.
    @ViewBuilder private func link<Content: View>(_ item: SidebarItem, @ViewBuilder _ content: () -> Content) -> some View {
        if linking { NavigationLink(value: item) { content() } } else { content().tag(item) }
    }

    private func row(_ item: SidebarItem, _ title: LocalizedStringKey, _ symbol: String, _ tint: Color, count: Int = 0) -> some View {
        link(item) {
            Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
                .badge(count)
        }
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
        case .project(let id): ProjectView(projectID: id)
        }
    }
}

// MARK: Project and Eingang lists

struct ProjectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.projectActions) private var actions
    let projectID: UUID
    @State private var showDone = false

    private var project: Project? { model.projects.first { $0.id == projectID } }
    private var open: [TodoTask] { model.tasks.filter { $0.projectID == projectID && !$0.isDone } }
    private var done: [TodoTask] { model.tasks.filter { $0.projectID == projectID && $0.isDone } }
    private var children: [Project] { model.projects.filter { $0.parentID == projectID } }

    var body: some View {
        List {
            if !children.isEmpty {
                Section {
                    ForEach(children) { child in
                        Button { model.selectedProjectID = child.id } label: {
                            HStack(spacing: 8) {
                                ProjectDot(id: child.id, size: 10)
                                Text(verbatim: child.name)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).taskRowInsets()
                    }
                }
            }
            Section {
                ForEach(open) { task in TaskRow(task: task, showProject: false).taskRowInsets() }
            }
            if !done.isEmpty {
                Section {
                    if showDone { ForEach(done) { task in TaskRow(task: task, showProject: false).taskRowInsets() } }
                } header: {
                    Button { withAnimation { showDone.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").rotationEffect(.degrees(showDone ? 90 : 0)).font(.caption.weight(.bold))
                            Text("task.completed")
                            Text(verbatim: String(done.count)).fontWeight(.regular)
                            Spacer()
                        }
                        .font(.subheadline.weight(.bold)).foregroundStyle(.secondary).textCase(nil)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .taskListStyle()
        .overlay { if project != nil && open.isEmpty && done.isEmpty && children.isEmpty { EmptyState(symbol: "tray", title: "project.empty", message: "project.emptyHint") } }
        .overlay { if project == nil { EmptyState(symbol: "folder.badge.plus", title: "projects.none") } }
        .navigationTitle(project?.name ?? "")
        .toolbar {
            if let project {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { actions.addProject(project.id) } label: { Label("project.addSub", systemImage: "plus") }
                        Button { actions.share(project) } label: { Label("project.share", systemImage: "person.badge.plus") }
                        Button(role: .destructive) { Task { await model.deleteProject(project) } } label: { Label("project.delete", systemImage: "trash") }
                    } label: { Label("project.more", systemImage: "ellipsis") }
                }
            }
        }
        .refreshable { await model.reload() }
        .quickAdd(projectID: projectID)
    }
}

/// "Eingang": open tasks that have no due date yet, across all projects.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta

    private var items: [TodoTask] { model.tasks.filter { !$0.isDone && meta.planning(for: $0.id)?.dueAt == nil } }

    var body: some View {
        List {
            ForEach(items) { TaskRow(task: $0).taskRowInsets() }
        }
        .taskListStyle()
        .overlay { if items.isEmpty { EmptyState(symbol: "tray", title: "inbox.empty", message: "inbox.emptyHint") } }
        .navigationTitle("view.inbox")
        .refreshable { await model.reload() }
        .quickAdd()
    }
}
