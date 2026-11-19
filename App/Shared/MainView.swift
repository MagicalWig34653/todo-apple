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
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var meta = TaskMeta()
    @State private var newProjectParent: UUID??  // .some(nil) = new root project
    @State private var newProjectName = ""
    @State private var shareProject: Project?
    @State private var showQuickAdd = false

    /// Task detail as a sheet: compact width, and on iPad with accessibility text sizes, where list, sidebar and
    /// inspector side by side would leave each of them a few characters wide.
    private var detailAsSheet: Bool {
        #if os(iOS)
        compact || typeSize.isAccessibilitySize
        #else
        false
        #endif
    }

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
        .reviewUndoBar(!(detailAsSheet && model.path.last != nil))
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
        .sheet(item: Binding(get: { detailAsSheet ? model.path.last : nil }, set: { if $0 == nil { model.path = [] } })) { task in
            NavigationStack { TaskDetailView(task: task) }
                .reviewUndoBar()
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
    private var isIOS: Bool { #if os(iOS)
        true
        #else
        false
        #endif
    }
    @Environment(AppModel.self) private var model
    /// Sidebar width follows the text size so entries wrap at word boundaries instead of mid-word; capped so the detail keeps room.
    @ScaledMetric(relativeTo: .body) private var sidebarMin = SidebarMetrics.columnMin
    @ScaledMetric(relativeTo: .body) private var sidebarIdeal = SidebarMetrics.columnIdeal
    @Environment(\.dynamicTypeSize) private var typeSize

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
            .inspector(isPresented: Binding(get: { model.path.last != nil && !(isIOS && typeSize.isAccessibilitySize) }, set: { if !$0 { model.path = [] } })) {
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

/// The four iPhone tabs (navigation variant A "Agenten zuerst", Lino 12.11.2026): agent work first, then projects,
/// date planning and search. Account, teams, agents/runner and activity sit behind the avatar menu.
enum PhoneTab: Hashable { case forYou, now, projects, plan, search }

/// Segments of the "Planen" tab (the former Todoist-style tabs).
enum PlanSection: String, CaseIterable, Identifiable {
    case today, upcoming, inbox
    var id: String { rawValue }
    var item: SidebarItem {
        switch self { case .today: .today; case .upcoming: .upcoming; case .inbox: .inbox }
    }
    var title: LocalizedStringKey {
        switch self { case .today: "view.today"; case .upcoming: "view.upcoming"; case .inbox: "view.inbox" }
    }
}

/// Where a navigation target lives on iPhone. `nil` = no fixed home: it is pushed onto the tab that is open.
enum PhoneRouting {
    static func tab(for item: SidebarItem) -> PhoneTab? {
        switch item {
        case .feed, .commandCenter, .brain: .forYou
        case .now: .now
        case .projects, .project, .projectCommandCenter: .projects
        case .today, .upcoming, .inbox, .labels, .label: .plan
        case .search: .search
        case .teams, .account, .runner, .activity: nil
        }
    }

    /// Items that are the root screen of their tab (no push).
    static func isRoot(_ item: SidebarItem) -> Bool {
        switch item {
        case .feed, .now, .projects, .today, .upcoming, .inbox, .search: true
        default: false
        }
    }

    /// The navigation path of `current` after selecting `item`: an item already on the stack pops back to it, an item for the open tab is pushed, otherwise the stack is replaced.
    static func path(after item: SidebarItem, current: [SidebarItem], sameTab: Bool) -> [SidebarItem] {
        if isRoot(item) { return [] }
        if let i = current.firstIndex(of: item) { return Array(current[...i]) }
        return sameTab ? current + [item] : [item]
    }
}

struct PhoneTabs: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta
    @State private var tab: PhoneTab = .forYou
    @State private var planSection: PlanSection = .today
    @State private var paths: [PhoneTab: [SidebarItem]] = [:]

    private func pathBinding(_ t: PhoneTab) -> Binding<[SidebarItem]> {
        Binding(get: { paths[t] ?? [] }, set: { paths[t] = $0 })
    }

    private func rootItem(_ t: PhoneTab) -> SidebarItem {
        switch t {
        case .forYou: .feed
        case .now: .now
        case .projects: .projects
        case .plan: planSection.item
        case .search: .search
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            stack(.forYou) { FeedView(showsAgentOverview: true, showsSystemStatus: true) }
                .tabItem { Label("view.feed", systemImage: "sparkles") }.tag(PhoneTab.forYou)
                .badge(model.attentionCount)
            stack(.now) { OverviewNowView() }
                .tabItem { Label("view.now", systemImage: "dot.radiowaves.left.and.right") }.tag(PhoneTab.now)
                .badge(model.attentionCount)
            stack(.projects) { ProjectsHome() }
                .tabItem { Label("view.projects", systemImage: "folder") }.tag(PhoneTab.projects)
            stack(.plan) { PlanView(section: $planSection) }
                .tabItem { Label("view.plan", systemImage: "calendar") }.tag(PhoneTab.plan)
                .badge(model.today.count + meta.overdue.count)
            stack(.search) { SearchView() }
                .tabItem { Label("view.search", systemImage: "magnifyingglass") }.tag(PhoneTab.search)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SyncStatusBar() }
        .onAppear { syncFromSelection(model.selection) }
        .onChange(of: model.selection) { _, new in syncFromSelection(new) }
        .onChange(of: tab) { _, new in reportSelection(of: new) }
        .onChange(of: paths) { _, _ in reportSelection(of: tab) }
        .onChange(of: planSection) { _, _ in if tab == .plan { reportSelection(of: .plan) } }
    }

    private func stack<Root: View>(_ t: PhoneTab, @ViewBuilder root: () -> Root) -> some View {
        NavigationStack(path: pathBinding(t)) {
            root()
                // Tab roots only: pushed screens keep their own toolbar (project actions, command-center mode).
                .accountMenu()
                .navigationDestination(for: SidebarItem.self) { SidebarScreen(item: $0) }
        }
    }

    /// Tab switch, back navigation or a pushed link: the model selection follows what is on screen, so a later
    /// selection of the same item (favorite, breadcrumb, menu) still changes the value and navigates.
    private func reportSelection(of t: PhoneTab) {
        let shown = paths[t]?.last ?? rootItem(t)
        if model.selection != shown { model.selection = shown }
    }

    private func syncFromSelection(_ item: SidebarItem?) {
        guard let item else {
            // Signed out or reset: back to the start tab.
            tab = .forYou; paths = [:]
            return
        }
        let target = PhoneRouting.tab(for: item) ?? tab
        if target == .plan, let section = PlanSection.allCases.first(where: { $0.item == item }), planSection != section {
            planSection = section
        }
        let current = paths[target] ?? []
        let next = PhoneRouting.path(after: item, current: current, sameTab: target == tab)
        if next != current { paths[target] = next }
        if tab != target { tab = target }
    }
}

/// "Planen": the date views as segments (Heute, Anstehend, Eingang); labels and filters from the toolbar.
struct PlanView: View {
    @Binding var section: PlanSection

    var body: some View {
        Group {
            switch section {
            case .today: TodayView()
            case .upcoming: UpcomingView()
            case .inbox: InboxView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("view.plan", selection: $section) {
                ForEach(PlanSection.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityIdentifier("planSection")
            .pageMargins().padding(.vertical, Space.s)
            .readableWidth()
            .background(Color.canvas)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: SidebarItem.labels) { Label("view.labels", systemImage: "tag") }
                    .accessibilityIdentifier("plan.labels")
            }
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
