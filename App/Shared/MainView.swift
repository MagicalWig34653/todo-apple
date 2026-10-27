import SwiftUI
import TodoCore

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var newProjectParent: UUID??  // .some(nil) = new root project
    @State private var newProjectName = ""
    @State private var shareProject: Project?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    Label("view.today", systemImage: "sun.max").tag(SidebarItem.today)
                    Label("view.upcoming", systemImage: "calendar").tag(SidebarItem.upcoming)
                    Label("view.search", systemImage: "magnifyingglass").tag(SidebarItem.search)
                    Label("view.teams", systemImage: "person.2").tag(SidebarItem.teams)
                        .badge(model.teamInvitations.count)
                }
                Section("projects.title") {
                    OutlineGroup(model.tree, children: \.children) { node in
                        Label(node.project.name, systemImage: "folder")
                            .tag(SidebarItem.project(node.id))
                            .contextMenu {
                                Button("project.addSub") { newProjectName = ""; newProjectParent = .some(node.id) }
                                Button("project.share") { shareProject = node.project }
                                Button("project.delete", role: .destructive) { Task { await model.deleteProject(node.project) } }
                            }
                    }
                }
            }
            .navigationTitle("app.title")
            .toolbar {
                ToolbarItem {
                    Button { newProjectName = ""; newProjectParent = .some(nil) } label: { Label("project.add", systemImage: "plus") }
                }
                ToolbarItem {
                    Menu {
                        Text(model.user?.displayName ?? "")
                        Button("logout", role: .destructive) { Task { await model.logout() } }
                    } label: { Label("account", systemImage: "person.crop.circle") }
                }
            }
        } detail: {
            NavigationStack(path: $model.path) {
                Group {
                    switch model.selection {
                    case .today: AgendaView(mode: .today)
                    case .upcoming: AgendaView(mode: .upcoming)
                    case .search: SearchView()
                    case .teams: TeamsView()
                    default: TaskListView()
                    }
                }
                .navigationDestination(for: TodoTask.self) { TaskDetailView(task: $0) }
            }
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
        .alert(LocalizedStringKey(model.noticeKey ?? ""), isPresented: Binding(get: { model.noticeKey != nil }, set: { if !$0 { model.noticeKey = nil } })) {
            Button("ok") {}
        }
    }
}

struct TaskListView: View {
    @Environment(AppModel.self) private var model
    @State private var quickTitle = ""

    var body: some View {
        let selected = model.projects.first { $0.id == model.selectedProjectID }
        List {
            if selected != nil {
                TextField("task.quickAdd", text: $quickTitle)
                    .onSubmit {
                        let title = quickTitle; quickTitle = ""
                        Task { await model.addTask(title: title) }
                    }
            }
            ForEach(model.visibleTasks) { task in
                NavigationLink(value: task) {
                    TaskRow(task: task)
                }
                .swipeActions {
                    Button("task.delete", role: .destructive) { Task { await model.deleteTask(task) } }
                }
            }
        }
        .overlay { if selected == nil { ContentUnavailableView("projects.none", systemImage: "folder.badge.plus") } }
        .navigationTitle(selected?.name ?? "")
        .refreshable { await model.reload() }
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: TodoTask
    var planning: PlanningData?

    var body: some View {
        HStack {
            Button { Task { await model.toggle(task) } } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(task.isDone ? "task.markOpen" : "task.markDone"))
            VStack(alignment: .leading) {
                Text(task.title).strikethrough(task.isDone).foregroundStyle(task.isDone ? .secondary : .primary)
                if let due = planning?.dueAt {
                    Text(due, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let p = planning, p.priority > 0 {
                Image(systemName: p.priority >= 3 ? "exclamationmark.3" : p.priority == 2 ? "exclamationmark.2" : "exclamationmark")
                    .foregroundStyle(p.priority >= 3 ? .red : .orange)
                    .accessibilityLabel(Text("priority.label"))
            }
        }
    }
}
