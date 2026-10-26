import SwiftUI
import TodoCore

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var newProjectParent: UUID??  // .some(nil) = new root project
    @State private var newProjectName = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(model.tree, children: \.children, selection: $model.selectedProjectID) { node in
                Label(node.project.name, systemImage: "folder")
                    .tag(node.id)
                    .contextMenu {
                        Button("project.addSub") { newProjectName = ""; newProjectParent = .some(node.id) }
                        Button("project.delete", role: .destructive) { Task { await model.deleteProject(node.project) } }
                    }
            }
            .navigationTitle("projects.title")
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
            TaskListView()
        }
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
                HStack {
                    Button { Task { await model.toggle(task) } } label: {
                        Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(task.isDone ? "task.markOpen" : "task.markDone"))
                    Text(task.title).strikethrough(task.isDone).foregroundStyle(task.isDone ? .secondary : .primary)
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
