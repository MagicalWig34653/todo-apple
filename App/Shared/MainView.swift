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

    private var newProjectPresented: Binding<Bool> {
        Binding<Bool>(get: { newProjectParent != nil }, set: { shown in if !shown { newProjectParent = nil } })
    }

    private var conflictPresented: Binding<Bool> {
        Binding<Bool>(get: { model.conflict != nil }, set: { _ in })
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
        .onChange(of: model.quickAddRequests) { _, _ in showQuickAdd = true }
        .modifier(LiveRefreshLifecycle())
        .onChange(of: model.newProjectRequests) { _, _ in newProjectName = ""; newProjectParent = .some(nil) }
        .sheet(isPresented: $showQuickAdd) { QuickAddSheet(projectID: model.selectedProjectID, dueDate: nil).environment(model).environment(meta) }
        .task(id: TaskMeta.refreshKey(model)) { await meta.refresh(model) }
        .onChange(of: model.outboxSnapshot, initial: true) { _, new in meta.overlay = new }
        .onChange(of: model.feedPlanning, initial: true) { _, _ in meta.adoptFeed(model) }
        .onChange(of: model.feedLabels, initial: true) { _, _ in meta.adoptFeed(model) }
        .onChange(of: model.metaFromFeed) { _, _ in meta.adoptFeed(model) }
        // Compact width: task detail as a sheet. Regular width (iPad, Mac): inspector column in `SplitLayout`.
        .sheet(item: Binding(get: { compact ? model.path.last : nil }, set: { if $0 == nil { model.path = [] } })) { task in
            NavigationStack { TaskDetailView(task: task) }
                .environment(model).environment(meta)
                // Sheets do not inherit the root tint; without this, bordered buttons in the detail turned system blue.
                .tint(.brand)
                #if os(macOS)
                .frame(minWidth: 520, idealWidth: 560, minHeight: 600, idealHeight: 680)
                #endif
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $shareProject) { ShareView(project: $0) }
        .alert("project.new", isPresented: newProjectPresented) {
            TextField(accessible: "project.name", text: $newProjectName)
            Button("save") {
                let parent = newProjectParent ?? nil
                Task { await model.addProject(name: newProjectName, parentID: parent ?? nil) }
            }
            Button("cancel", role: .cancel) {}
        }
        .alert("sync.conflict.title", isPresented: conflictPresented) {
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
        if model.syncStatus == .offline || model.unsentChanges > 0 {
            HStack(spacing: Space.s) {
                Image(systemName: model.syncStatus == .offline ? "icloud.slash" : "arrow.triangle.2.circlepath")
                if model.syncStatus == .offline { Text("sync.offline") }
                if model.unsentChanges > 0 {
                    Text(verbatim: String(model.unsentChanges))
                    Text("sync.pending")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(model.syncStatus == .offline ? Color.dueTomorrow : Color.textSecondary)
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
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

private enum InspectorMetrics { static let min: CGFloat = 340, ideal: CGFloat = 420, max: CGFloat = 560 }

struct SplitLayout: View {
    @Environment(AppModel.self) private var model
    /// Sidebar width follows the text size so entries wrap at word boundaries instead of mid-word; capped so the detail keeps room.
    @ScaledMetric(relativeTo: .body) private var sidebarMin = SidebarMetrics.columnMin
    @ScaledMetric(relativeTo: .body) private var sidebarIdeal = SidebarMetrics.columnIdeal

    var body: some View {
        NavigationSplitView {
            SidebarList(linking: false)
                .navigationTitle("app.title")
                .navigationSplitViewColumnWidth(
                    min: min(sidebarMin, 400), ideal: min(sidebarIdeal, 400), max: max(SidebarMetrics.columnMax, min(sidebarIdeal, 400)))
                .safeAreaInset(edge: .bottom) { SyncStatusBar() }
        } detail: {
            NavigationStack {
                SidebarScreen(item: model.selection)
            }
            .safeAreaInset(edge: .bottom) { SyncStatusBar() }
            .inspector(isPresented: Binding(get: { model.path.last != nil }, set: { if !$0 { model.path = [] } })) {
                if let task = model.path.last {
                    NavigationStack { TaskDetailView(task: task) }
                        .id(task.id)
                        .inspectorColumnWidth(min: InspectorMetrics.min, ideal: InspectorMetrics.ideal, max: InspectorMetrics.max)
                }
            }
        }
    }
}

// MARK: iPhone: bottom tab bar

struct PhoneTabs: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta
    @State private var tab = 5
    @State private var browsePath: [SidebarItem] = []

    private var inboxCount: Int { model.tasks.filter { !$0.isDone && !meta.isSubtask($0.id) && meta.planning(for: $0.id)?.dueAt == nil }.count }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { FeedView() }
                .tabItem { Label("view.feed", systemImage: "sparkles") }.tag(5)
                .badge(model.attentionCount)
            NavigationStack { InboxView() }
                .tabItem { Label("view.inbox", systemImage: "tray") }.tag(0)
                .badge(inboxCount)
            NavigationStack { TodayView() }
                .tabItem { Label("view.today", systemImage: "sun.max") }.tag(1)
                .badge(model.today.count + meta.overdue.count)
            NavigationStack { UpcomingView() }
                .tabItem { Label("view.upcoming", systemImage: "calendar") }.tag(2)
            NavigationStack(path: $browsePath) {
                SidebarList(linking: true)
                    .navigationTitle("browse.title")
                    .navigationDestination(for: SidebarItem.self) { SidebarScreen(item: $0) }
            }
            .tabItem { Label("browse.title", systemImage: "square.grid.2x2") }.tag(4)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SyncStatusBar() }
        .onAppear { syncFromSelection(model.selection) }
        #if DEBUG
        // Screenshots: `TODO_DEBUG_SELECT=browse` shows the root of the browse tab (no tap automation in simctl);
        // after the debug sign-in, which resets the selection.
        .task {
            guard ProcessInfo.processInfo.environment["TODO_DEBUG_SELECT"] == "browse" else { return }
            try? await Task.sleep(for: .seconds(3))
            tab = 4
        }
        #endif
        .onChange(of: model.selection) { _, new in syncFromSelection(new) }
        .onChange(of: tab) { _, new in
            switch new {
            case 5: model.selection = .feed
            case 0: model.selection = .inbox
            case 1: model.selection = .today
            case 2: model.selection = .upcoming
            default: break
            }
        }
    }

    private func syncFromSelection(_ item: SidebarItem?) {
        switch item {
        case .feed, nil: tab = 5
        case .inbox: tab = 0
        case .today: tab = 1
        case .upcoming: tab = 2
        // Search lives in the browse tab: with six tabs iOS wraps the extra ones in its own "More" navigation controller,
        // which put a second back button above the stack's own one.
        case .search, .teams, .project, .labels, .label, .account, .runner, .activity, .commandCenter, .projectCommandCenter:
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

// MARK: Previews

#if DEBUG
private struct NavPreviewHost<Content: View>: View {
    @State private var model = AppModel()
    @State private var meta = TaskMeta()
    @ViewBuilder var content: () -> Content
    var body: some View { content().environment(model).environment(meta) }
}

#Preview("Sync bar light") { NavPreviewHost { SyncStatusBar() }.preferredColorScheme(.light) }
#Preview("Sync bar dark") { NavPreviewHost { SyncStatusBar() }.preferredColorScheme(.dark) }
#Preview("Sync bar accessibility5") { NavPreviewHost { SyncStatusBar() }.dynamicTypeSize(.accessibility5) }

#Preview("Split light") { NavPreviewHost { SplitLayout() }.preferredColorScheme(.light) }
#Preview("Split dark") { NavPreviewHost { SplitLayout() }.preferredColorScheme(.dark) }
#Preview("Split accessibility5") { NavPreviewHost { SplitLayout() }.dynamicTypeSize(.accessibility5) }

#Preview("Tabs light") { NavPreviewHost { PhoneTabs() }.preferredColorScheme(.light) }
#Preview("Tabs dark") { NavPreviewHost { PhoneTabs() }.preferredColorScheme(.dark) }
#Preview("Tabs accessibility5") { NavPreviewHost { PhoneTabs() }.dynamicTypeSize(.accessibility5) }

#Preview("Inbox light") { NavPreviewHost { NavigationStack { InboxView() } }.preferredColorScheme(.light) }
#Preview("Inbox dark") { NavPreviewHost { NavigationStack { InboxView() } }.preferredColorScheme(.dark) }
#Preview("Inbox accessibility5") { NavPreviewHost { NavigationStack { InboxView() } }.dynamicTypeSize(.accessibility5) }
#endif
