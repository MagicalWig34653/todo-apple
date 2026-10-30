import SwiftUI
import TodoCore

/// Actions the project screens trigger on the root view (sheets and alerts live there).
struct ProjectActions {
    var addProject: (UUID?) -> Void = { _ in }
    var share: (Project) -> Void = { _ in }
    var addTask: () -> Void = {}
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
    @State private var showQuickAdd = false

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
            share: { shareProject = $0 },
            addTask: { showQuickAdd = true }))
        .sheet(isPresented: $showQuickAdd) { QuickAddSheet(projectID: model.selectedProjectID, dueDate: nil).environment(model).environment(meta) }
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(model.syncStatus == .offline ? Color.tileOrange : Color.secondary)
            .padding(.horizontal, Space.m).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 0.5))
            .padding(.bottom, Space.xs)
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
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
    @Environment(TaskMeta.self) private var meta
    @State private var tab = 1
    @State private var browsePath: [SidebarItem] = []

    private var inboxCount: Int { model.tasks.filter { !$0.isDone && !meta.isSubtask($0.id) && meta.planning(for: $0.id)?.dueAt == nil }.count }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { InboxView() }
                .tabItem { Label("view.inbox", systemImage: "tray") }.tag(0)
                .badge(inboxCount)
            NavigationStack { TodayView() }
                .tabItem { Label("view.today", systemImage: "sun.max") }.tag(1)
                .badge(model.today.count + meta.overdue.count)
            NavigationStack { UpcomingView() }
                .tabItem { Label("view.upcoming", systemImage: "calendar") }.tag(2)
            NavigationStack { SearchView() }
                .tabItem { Label("view.search", systemImage: "magnifyingglass") }.tag(3)
            NavigationStack(path: $browsePath) {
                SidebarList(linking: true)
                    .navigationTitle("browse.title")
                    .navigationDestination(for: SidebarItem.self) { SidebarScreen(item: $0) }
            }
            .tabItem { Label("browse.title", systemImage: "square.grid.2x2") }.tag(4)
            .badge(model.attentionCount)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SyncStatusBar() }
        .onAppear { syncFromSelection(model.selection) }
        .onChange(of: model.selection) { _, new in syncFromSelection(new) }
        .onChange(of: tab) { _, new in
            switch new {
            case 0: model.selection = .inbox
            case 1: model.selection = .today
            case 2: model.selection = .upcoming
            case 3: model.selection = .search
            default: break
            }
        }
    }

    private func syncFromSelection(_ item: SidebarItem?) {
        switch item {
        case .inbox: tab = 0
        case .today, nil: tab = 1
        case .upcoming: tab = 2
        case .search: tab = 3
        case .teams, .project, .labels, .label, .account, .runner, .activity, .commandCenter, .projectCommandCenter:
            tab = 4
            if let item, browsePath.last != item { browsePath = [item] }
        }
    }
}

// MARK: Project and Eingang lists

/// "Eingang": open tasks that have no due date yet, across all projects.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta

    private var items: [TodoTask] { model.tasks.filter { !$0.isDone && !meta.isSubtask($0.id) && meta.planning(for: $0.id)?.dueAt == nil } }

    var body: some View {
        List {
            ScreenHeader(title: "view.inbox", subtitle: items.isEmpty ? nil : String(localized: "agenda.openCount \(items.count)"))
            ForEach(items) { TaskRow(task: $0).taskRowInsets() }
        }
        .taskListStyle()
        .overlay { if items.isEmpty { EmptyState(symbol: "tray", title: "inbox.empty", message: "inbox.emptyHint", tint: .tileBlue) } }
        .toolbarTitleDisplayMode(.inline)
        .navigationTitle("view.inbox")
        .refreshable { await model.reload() }
        .quickAdd()
    }
}
