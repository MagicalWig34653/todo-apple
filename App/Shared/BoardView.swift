import SwiftUI
import TodoCore

/// Horizontally scrolling columns with cards. Cards and columns are draggable; columns accept cards at the end, cards
/// accept cards before themselves, column headers accept columns.
struct BoardView: View {
    @Environment(AppModel.self) private var model
    let board: BoardModel
    let showCompleted: Bool
    @State private var addingColumn = false
    @State private var newColumnName = ""
    @FocusState private var columnFocus: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(board.columns, id: \.stableID) { column in
                    BoardColumnView(board: board, column: column, showCompleted: showCompleted)
                }
                if !board.unsupported { addColumn }
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 24)
        }
        .scrollClipDisabled(false)
        .background(Color.canvas)
    }

    @ViewBuilder private var addColumn: some View {
        Group {
            if addingColumn {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("board.column.name", text: $newColumnName)
                        .textFieldStyle(.roundedBorder).focused($columnFocus)
                        .onSubmit { commit() }
                    HStack {
                        Button("board.column.add") { commit() }.buttonStyle(.borderedProminent).disabled(newColumnName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("cancel") { addingColumn = false; newColumnName = "" }.buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
                .padding(12).frame(width: 280).background(Color.canvasRaised, in: RoundedRectangle(cornerRadius: 12))
            } else {
                Menu {
                    Button { addingColumn = true; columnFocus = true } label: { Label("board.column.empty", systemImage: "rectangle.split.1x2") }
                    if !board.hasOwnColumns {
                        Button { Task { await board.applyStatusTemplate(model) } } label: { Label("board.column.template", systemImage: "checklist") }
                    }
                } label: {
                    Label("board.column.add", systemImage: "plus")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(width: 200, alignment: .leading)
                        .background(Color.canvasRaised, in: RoundedRectangle(cornerRadius: 12))
                }
                .menuStyle(.button).buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
        }
        .padding(.top, 2)
    }

    private func commit() {
        let name = newColumnName
        addingColumn = false; newColumnName = ""
        Task { await board.addColumn(name: name, model) }
    }
}

struct BoardColumnView: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta
    let board: BoardModel
    let column: BoardColumn
    let showCompleted: Bool
    @State private var adding = false
    @State private var draft = ""
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var targeted = false
    @FocusState private var focus: Bool

    private var tasks: [TodoTask] { showCompleted || column.isDone ? column.tasks : column.tasks.filter { !$0.isDone } }
    private var title: Text {
        BoardModel.isUnassigned(column) ? Text("board.unassigned") : Text(verbatim: column.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        BoardCard(task: task)
                            .draggable(BoardDrag(kind: .task, id: task.id))
                            .dropDestination(for: BoardDrag.self) { items, _ in
                                guard let drag = items.first, drag.kind == .task, drag.id != task.id else { return false }
                                let from = column.tasks.firstIndex { $0.id == drag.id }
                                let target = column.tasks.firstIndex { $0.id == task.id } ?? index
                                let final = (from.map { $0 < target } ?? false) ? target - 1 : target
                                Task { await board.move(taskID: drag.id, to: column, index: final, model) }
                                return true
                            }
                    }
                    footer
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 290)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 2)
        .background(targeted ? Color.brand.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .dropDestination(for: BoardDrag.self) { items, _ in
            guard let drag = items.first else { return false }
            switch drag.kind {
            case .task:
                Task { await board.move(taskID: drag.id, to: column, index: nil, model) }
            case .column:
                guard column.isReal else { return false }
                Task { await board.moveColumn(drag.id, before: column, model) }
            }
            return true
        } isTargeted: { targeted = $0 }
        .alert("board.column.rename", isPresented: $renaming) {
            TextField("board.column.name", text: $renameText)
            Button("save") { Task { await board.update(column, name: renameText, model) } }
            Button("cancel", role: .cancel) {}
        }
        .confirmationDialog("board.column.deleteConfirm", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("board.column.delete", role: .destructive) { Task { await board.delete(column, model) } }
            Button("cancel", role: .cancel) {}
        } message: { Text("board.column.deleteHint") }
    }

    @ViewBuilder private var header: some View {
        let base = HStack(spacing: 6) {
            if let color = Color(hex: column.color) { Circle().fill(color).frame(width: 9, height: 9) }
            title.font(.headline).lineLimit(1)
            Text(verbatim: String(tasks.count)).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if column.isReal { columnMenu }
        }
        .padding(.horizontal, 4).padding(.vertical, 8)
        if let id = column.id { base.draggable(BoardDrag(kind: .column, id: id)) } else { base }
    }

    private var columnMenu: some View {
        Menu {
            Button { renameText = column.name; renaming = true } label: { Label("board.column.rename", systemImage: "pencil") }
            Menu {
                ForEach(Color.columnPalette, id: \.hex) { entry in
                    Button { Task { await board.update(column, color: entry.hex, model) } } label: { Label(LocalizedStringKey("color.\(entry.name)"), systemImage: "circle.fill") }
                }
                Button { Task { await board.update(column, color: "", model) } } label: { Label("color.none", systemImage: "circle.slash") }
            } label: { Label("board.column.color", systemImage: "paintpalette") }
            Button { Task { await board.update(column, isDone: !column.isDone, model) } } label: {
                Label(column.isDone ? "board.column.notDone" : "board.column.isDone", systemImage: "checkmark.circle")
            }
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Label("board.column.delete", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 28, height: 24).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel(Text("board.column.menu"))
    }

    @ViewBuilder private var footer: some View {
        if adding {
            VStack(alignment: .leading, spacing: 8) {
                TextField("quickAdd.title", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).focused($focus)
                    .onSubmit { submit() }
                HStack {
                    Button("board.task.add") { submit() }.buttonStyle(.borderedProminent).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("cancel") { adding = false; draft = "" }.buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(Color.canvas, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.hairline))
        } else {
            Button { adding = true; focus = true } label: {
                Label("board.task.add", systemImage: "plus")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func submit() {
        let t = draft
        draft = ""
        focus = true
        Task { await board.addTask(title: t, in: column, model) }
    }
}

struct BoardCard: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta
    let task: TodoTask
    @State private var completing = false

    private var planning: PlanningData? { meta.planning(for: task.id) }
    private var checked: Bool { task.isDone != completing }

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            TaskCheckbox(checked: checked, priority: planning?.priority ?? 0) { toggle() }
                .padding(.leading, -8).padding(.top, -6)
            Button { model.path = [task] } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: task.title).font(.body)
                        .strikethrough(checked, color: .secondary)
                        .foregroundStyle(checked ? Color.secondary : Color.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !task.description.isEmpty {
                        Text(verbatim: task.description).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    meta_line
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.canvas, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.hairline))
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        .contextMenu {
            Button { toggle() } label: { Label(task.isDone ? "task.markOpen" : "task.markDone", systemImage: "checkmark.circle") }
            Button(role: .destructive) { Task { await model.deleteTask(task) } } label: { Label("task.delete", systemImage: "trash") }
        }
    }

    @ViewBuilder private var meta_line: some View {
        let labels = meta.labels(for: task.id)
        if planning?.dueAt != nil || !labels.isEmpty {
            HStack(spacing: 8) {
                if let due = planning?.dueAt {
                    HStack(spacing: 3) {
                        Image(systemName: planning?.recurrence != nil ? "arrow.triangle.2.circlepath" : "calendar")
                        Text(verbatim: DueFormat.text(due))
                    }
                    .foregroundStyle(task.isDone ? Color.secondary : DueFormat.style(due).color)
                }
                ForEach(labels.prefix(3)) { LabelChip(name: $0.name) }
            }
            .font(.caption)
        }
    }

    private func toggle() {
        if task.isDone { Haptics.tap(); Task { await model.toggle(task) }; return }
        withAnimation(.spring(duration: 0.3, bounce: 0.35)) { completing = true }
        Haptics.success()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            await model.toggle(task)
            completing = false
        }
    }
}
