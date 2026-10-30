import SwiftUI
import TodoCore

/// Project page: breadcrumb toolbar, large editable title, inline description, then list or board.
struct ProjectView: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta
    @Environment(\.projectActions) private var actions
    let projectID: UUID
    @State private var board: BoardModel
    @State private var showOptions = false
    @State private var showComments = false
    @State private var title = ""
    @State private var descriptionText = ""
    @FocusState private var titleFocus: Bool
    @FocusState private var descriptionFocus: Bool

    init(projectID: UUID) {
        self.projectID = projectID
        _board = State(initialValue: BoardModel(projectID: projectID))
    }

    private var project: Project? { model.projects.first { $0.id == projectID } }
    private var options: ProjectDisplayPrefs { model.prefs(for: projectID) }
    private var mode: ProjectDisplayPrefs.View { options.viewMode }
    private var children: [Project] { model.projects.filter { $0.parentID == projectID } }
    private var ancestors: [Project] {
        var chain: [Project] = []
        var current = project?.parentID
        while let id = current, let p = model.projects.first(where: { $0.id == id }), !chain.contains(where: { $0.id == id }) {
            chain.insert(p, at: 0); current = p.parentID
        }
        return chain
    }
    private var refreshKey: Int {
        var h = Hasher()
        h.combine(projectID)
        for t in model.tasks where t.projectID == projectID { h.combine(t.id); h.combine(t.version); h.combine(t.status); h.combine(t.columnID); h.combine(t.boardPosition) }
        for c in model.columns where c.projectID == projectID { h.combine(c) }
        return h.finalize()
    }

    var body: some View {
        Group {
            if let project {
                VStack(alignment: .leading, spacing: 0) {
                    header(project)
                    switch mode {
                    case .list: ProjectListView(projectID: projectID, board: board, options: options)
                    case .board: BoardView(board: board, showCompleted: options.showCompleted)
                    }
                }
                .background(Color.canvas)
            } else {
                EmptyState(symbol: "folder.badge.plus", title: "projects.none")
            }
        }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .task(id: refreshKey) { await board.load(model) }
        #if DEBUG
        .task { if ProcessInfo.processInfo.environment["TODO_DEBUG_COMMENTS"] == "1" { try? await Task.sleep(for: .seconds(1)); showComments = true } }
        #endif
        .onAppear { title = project?.name ?? ""; descriptionText = project?.description ?? "" }
        .onChange(of: project?.description) { _, new in if !descriptionFocus { descriptionText = new ?? "" } }
        .sheet(isPresented: $showComments) { ProjectCommentsView(projectID: projectID).environment(model) }
        .onChange(of: project?.name) { _, new in if !titleFocus { title = new ?? "" } }
        .refreshable { await model.reload() }
        .quickAdd(projectID: projectID)
    }

    private func header(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("project.name", text: $title)
                .font(.system(size: 30, weight: .bold)).textFieldStyle(.plain).focused($titleFocus)
                .onSubmit { commitTitle(project) }
                .onChange(of: titleFocus) { _, f in if !f { commitTitle(project) } }
            TextField("project.descriptionPlaceholder", text: $descriptionText, axis: .vertical)
                .font(.body).foregroundStyle(.secondary).textFieldStyle(.plain).lineLimit(1...4).focused($descriptionFocus)
                .onChange(of: descriptionFocus) { _, f in if !f { commitDescription(project) } }
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
    }

    private func commitDescription(_ project: Project) {
        let t = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != (project.description ?? "") { Task { await model.updateProject(project, ProjectUpdate(description: t)) } }
    }

    private func commitTitle(_ project: Project) {
        let t = title.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { title = project.name } else if t != project.name { Task { await model.renameProject(project, to: t) } }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .principal) { breadcrumb }
        #else
        ToolbarItem(placement: .navigation) { breadcrumb }
        #endif
        if let project {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showComments = true } label: { Label("project.comments", systemImage: "bubble.left") }
                Button { model.selection = .projectCommandCenter(projectID) } label: { Label("cc.title", systemImage: "rectangle.3.group") }
                Button { actions.share(project) } label: { Label("project.share", systemImage: "person.badge.plus") }
                Button { showOptions = true } label: { Label("project.display", systemImage: mode == .board ? "rectangle.split.3x1" : "list.bullet") }
                    .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                        DisplayOptions(projectID: projectID, hasColumns: board.hasOwnColumns || mode == .board)
                            .presentationCompactAdaptation(.popover)
                    }
                Menu {
                    Button { Task { await model.toggleFavorite(project) } } label: {
                        Label(project.isFavorite ? "project.unfavorite" : "project.favorite", systemImage: project.isFavorite ? "star.slash" : "star")
                    }
                    Menu {
                        ForEach(Color.columnPalette, id: \.hex) { entry in
                            Button { Task { await model.setProjectColor(project, hex: entry.hex) } } label: { Label(LocalizedStringKey("color.\(entry.name)"), systemImage: "circle.fill") }
                        }
                        Button { Task { await model.setProjectColor(project, hex: "") } } label: { Label("color.none", systemImage: "circle.slash") }
                    } label: { Label("project.color", systemImage: "paintpalette") }
                    Button { actions.addProject(project.id) } label: { Label("project.addSub", systemImage: "plus") }
                    Divider()
                    Button(role: .destructive) { Task { await model.deleteProject(project) } } label: { Label("project.delete", systemImage: "trash") }
                } label: { Label("project.more", systemImage: "ellipsis") }
            }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Text("projects.mine").foregroundStyle(.secondary)
            ForEach(ancestors) { p in
                Text(verbatim: "/").foregroundStyle(.tertiary)
                Button { model.selectedProjectID = p.id } label: { Text(verbatim: p.name) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if !ancestors.isEmpty || project != nil { Text(verbatim: "/").foregroundStyle(.tertiary) }
        }
        .font(.subheadline.weight(.medium)).lineLimit(1).fixedSize()
    }
}

struct DisplayOptions: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID
    let hasColumns: Bool

    var body: some View {
        let p = model.prefs(for: projectID)
        func binding<T>(_ get: @escaping (ProjectDisplayPrefs) -> T, _ patch: @escaping (T) -> ProjectPrefsPatch) -> Binding<T> {
            Binding(get: { get(model.prefs(for: projectID)) }, set: { model.setPrefs(patch($0), for: projectID) })
        }
        return VStack(alignment: .leading, spacing: 14) {
            Picker("display.layout", selection: binding(\.view, { ProjectPrefsPatch(view: $0) })) {
                Label("display.list", systemImage: "list.bullet").tag(ProjectDisplayPrefs.View.list.rawValue)
                Label("display.board", systemImage: "rectangle.split.3x1").tag(ProjectDisplayPrefs.View.board.rawValue)
            }
            .pickerStyle(.segmented)
            Picker("display.sort", selection: binding(\.sort, { ProjectPrefsPatch(sort: $0) })) {
                Text("sort.manual").tag(ProjectDisplayPrefs.Sort.manual.rawValue)
                Text("sort.name").tag(ProjectDisplayPrefs.Sort.title.rawValue)
                Text("sort.due").tag(ProjectDisplayPrefs.Sort.due.rawValue)
                Text("sort.priority").tag(ProjectDisplayPrefs.Sort.priority.rawValue)
            }
            Picker("display.group", selection: binding(\.grouping, { ProjectPrefsPatch(grouping: $0) })) {
                Text("group.none").tag(ProjectDisplayPrefs.Grouping.none.rawValue)
                Text("group.column").tag(ProjectDisplayPrefs.Grouping.column.rawValue)
                Text("group.priority").tag(ProjectDisplayPrefs.Grouping.priority.rawValue)
                Text("group.due").tag(ProjectDisplayPrefs.Grouping.due.rawValue)
            }
            Toggle("display.completed", isOn: binding(\.showCompleted, { ProjectPrefsPatch(showCompleted: $0) }))
        }
        .padding(16).frame(minWidth: 300)
        .id(p.revision)
    }
}

/// List layout: sorted/grouped sections plus sub-projects and a "completed" section.
struct ProjectListView: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta
    let projectID: UUID
    let board: BoardModel
    let options: ProjectDisplayPrefs
    @State private var doneExpanded = false

    private var children: [Project] { model.projects.filter { $0.parentID == projectID } }
    private var mine: [TodoTask] { model.tasks.filter { $0.projectID == projectID } }
    private var open: [TodoTask] { sorted(mine.filter { !$0.isDone }) }
    private var done: [TodoTask] { sorted(mine.filter(\.isDone)) }

    private func sorted(_ tasks: [TodoTask]) -> [TodoTask] {
        switch options.sortMode {
        case .manual: return tasks
        case .title: return tasks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .due: return tasks.sorted { (meta.planning(for: $0.id)?.dueAt ?? .distantFuture) < (meta.planning(for: $1.id)?.dueAt ?? .distantFuture) }
        case .priority: return tasks.sorted { (meta.planning(for: $0.id)?.priority ?? 0) > (meta.planning(for: $1.id)?.priority ?? 0) }
        }
    }

    private struct Group: Identifiable { let id: String; let title: Text?; let tasks: [TodoTask] }

    private var groups: [Group] {
        switch options.groupMode {
        case .none: return [Group(id: "all", title: nil, tasks: open)]
        case .column:
            let cols = board.columns.map { c -> Group in
                let ids = Set(c.tasks.map(\.id))
                let t = BoardModel.isUnassigned(c) ? Text("board.unassigned") : Text(verbatim: c.name)
                return Group(id: c.stableID, title: t, tasks: open.filter { ids.contains($0.id) })
            }
            return cols.filter { !$0.tasks.isEmpty }
        case .due:
            let cal = Calendar.current
            let byDay = Dictionary(grouping: open) { t in meta.planning(for: t.id)?.dueAt.map { cal.startOfDay(for: $0) } }
            let days = byDay.keys.compactMap { $0 }.sorted()
            let dated = days.map { d in Group(id: "d\(d.timeIntervalSince1970)", title: Text(verbatim: DueFormat.text(d)), tasks: byDay[d] ?? []) }
            let none = byDay[nil].map { [Group(id: "nodate", title: Text("due.none"), tasks: $0)] } ?? []
            return dated + none
        case .priority:
            return [3, 2, 1, 0].map { p in
                Group(id: "p\(p)", title: p == 0 ? Text("priority.0") : Text(LocalizedStringKey("priority.\(p)")),
                    tasks: open.filter { (meta.planning(for: $0.id)?.priority ?? 0) == p })
            }.filter { !$0.tasks.isEmpty }
        }
    }

    var body: some View {
        List {
            if !children.isEmpty {
                Section {
                    ForEach(children) { child in
                        Button { model.selectedProjectID = child.id } label: {
                            HStack(spacing: 8) {
                                Text(verbatim: "#").font(.headline).foregroundStyle(Color.project(child.id))
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
            ForEach(groups) { g in
                Section {
                    ForEach(g.tasks) { TaskRow(task: $0, showProject: false).taskRowInsets() }
                } header: {
                    if let t = g.title { t.font(.subheadline.weight(.bold)).foregroundStyle(.primary).textCase(nil) }
                }
            }
            if !done.isEmpty {
                Section {
                    if doneExpanded || options.showCompleted { ForEach(done) { TaskRow(task: $0, showProject: false).taskRowInsets() } }
                } header: {
                    Button { withAnimation { doneExpanded.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").rotationEffect(.degrees(doneExpanded || options.showCompleted ? 90 : 0)).font(.caption.weight(.bold))
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
        .overlay { if open.isEmpty && done.isEmpty && children.isEmpty { EmptyState(symbol: "tray", title: "project.empty", message: "project.emptyHint") } }
    }
}
