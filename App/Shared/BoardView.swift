import SwiftUI
import TodoCore

/// Horizontally scrolling columns with cards. Cards and columns are draggable; columns accept cards at the end, cards
/// accept cards before themselves, column headers accept columns.
struct BoardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    let board: BoardModel
    let showCompleted: Bool
    @State private var addingColumn = false
    @State private var newColumnName = ""
    @FocusState private var columnFocus: Bool
    @ScaledMetric(relativeTo: .body) private var baseWidth: CGFloat = 288
    @ScaledMetric(relativeTo: .body) private var minColumnWidth: CGFloat = 240
    @ScaledMetric(relativeTo: .body) private var maxSharedWidth: CGFloat = 420
    @ScaledMetric(relativeTo: .body) private var addButtonMinWidth: CGFloat = 200
    /// On iPhone a column takes this share of the width so the next column peeks out.
    private static let compactColumnShare: CGFloat = 0.86

    /// Horizontal page margin, identical to the project header (`pageMargins()`).
    private var pageMargin: CGFloat { sizeClass == .regular ? Space.pageRegular : Space.page }

    /// Column width: on iPhone nearly the screen (the next column peeks out), on iPad/Mac the columns share the
    /// width when there are only a few, otherwise the scaled base width; never wider than the screen.
    /// `available` is the visible width of the horizontal scroll view (from `containerRelativeFrame`).
    private func columnWidth(_ available: CGFloat) -> CGFloat {
        // No lower bound above the real width: at accessibility sizes the scaled minimum is wider than the screen.
        let inner = max(available - 2 * pageMargin, 0)
        if sizeClass == .compact { return min(max(inner * Self.compactColumnShare, minColumnWidth), inner) }
        let n = max(board.columns.count, 1)
        let shared = (inner - CGFloat(n) * Space.m) / CGFloat(n)
        return min(inner, max(baseWidth, min(shared, maxSharedWidth)))
    }

    var body: some View {
        Group {
            if !board.isLoaded {
                BoardSkeleton(columnWidth: columnWidth)
            } else {
                ScrollView(.vertical) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(alignment: .top, spacing: Space.m) {
                            ForEach(board.columns, id: \.stableID) { column in
                                BoardColumnView(board: board, column: column, showCompleted: showCompleted)
                                    .containerRelativeFrame(.horizontal) { available, _ in columnWidth(available) }
                            }
                            if !board.unsupported { addColumn }
                        }
                        .pageMargins().padding(.top, Space.xs).padding(.bottom, Space.xl)
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                }
            }
        }
        .background(Color.canvas)
    }

    @ViewBuilder private var addColumn: some View {
        Group {
            if addingColumn {
                VStack(alignment: .leading, spacing: Space.s) {
                    TextField(accessible: "board.column.name", text: $newColumnName)
                        .textFieldStyle(.roundedBorder).focused($columnFocus)
                        .onSubmit { commit() }
                    HStack {
                        Button("board.column.add") { commit() }.buttonStyle(.borderedProminent).disabled(newColumnName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("cancel") { addingColumn = false; newColumnName = "" }.buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
                .padding(Space.m)
                .containerRelativeFrame(.horizontal) { available, _ in columnWidth(available) }
                .background(Color.canvasRaised, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            } else {
                Menu {
                    Button { addingColumn = true; columnFocus = true } label: { Label("board.column.empty", systemImage: "rectangle.split.1x2") }
                    if !board.hasOwnColumns {
                        Button { Task { await board.applyStatusTemplate(model) } } label: { Label("board.column.template", systemImage: "checklist") }
                    }
                } label: {
                    Label("board.column.add", systemImage: "plus")
                        .font(.subheadline.weight(.medium)).foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, Space.l).padding(.vertical, Space.m)
                        .frame(minWidth: addButtonMinWidth, alignment: .leading)
                        .tapTarget()
                        .background(Color.canvasRaised, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.hairline, style: StrokeStyle(lineWidth: 1, dash: [Space.xs, Space.xs])))
                }
                .menuStyle(.button).buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
        }
        .padding(.top, Space.xxs)
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
    @ScaledMetric(relativeTo: .subheadline) private var emptyColumnHeight: CGFloat = 84
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
            do {
                LazyVStack(spacing: Space.s) {
                    if tasks.isEmpty && !adding { emptyColumn }
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        BoardCard(task: task, board: board, column: column)
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
                .padding(.bottom, Space.xs)
            }
        }
        .padding(.horizontal, Space.s)
        .background(targeted ? Color.brand.opacity(0.10) : Color.canvasRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).strokeBorder(targeted ? Color.brand.opacity(0.6) : Color.hairline.opacity(0.6), lineWidth: targeted ? 1.5 : 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .dropDestination(for: BoardDrag.self) { items, _ in
            guard let drag = items.first else { return false }
            switch drag.kind {
            case .task:
                Task { await board.move(taskID: drag.id, to: column, index: nil, model) }
            case .column:
                guard column.isReal else { return false }
                Task { await board.moveColumn(drag.id, before: column, model) }
            case .project:
                return false
            }
            return true
        } isTargeted: { targeted = $0 }
        .alert("board.column.rename", isPresented: $renaming) {
            TextField(accessible: "board.column.name", text: $renameText)
            Button("save") { Task { await board.update(column, name: renameText, model) } }
            Button("cancel", role: .cancel) {}
        }
        .confirmationDialog("board.column.deleteConfirm", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("board.column.delete", role: .destructive) { Task { await board.delete(column, model) } }
            Button("cancel", role: .cancel) {}
        } message: { Text("board.column.deleteHint") }
    }

    @ViewBuilder private var header: some View {
        let base = HStack(spacing: Space.s) {
            if let color = Color(hex: column.color) { Circle().fill(color).scaledSquare(10, relativeTo: .subheadline).accessibilityHidden(true) }
            title.font(.sectionTitle).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            CountBadge(count: tasks.count)
            Spacer(minLength: Space.xs)
            if column.isReal { columnMenu }
        }
        .padding(Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(Text("a11y.board.cards \(tasks.count)"))
        if let id = column.id { base.draggable(BoardDrag(kind: .column, id: id)) } else { base }
    }

    private var emptyColumn: some View {
        VStack(spacing: Space.xs) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "tray").font(.title3).foregroundStyle(targeted ? Color.brand : Color.textSecondary)
            Text("board.lane.empty").font(.footnote).foregroundStyle(Color.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: emptyColumnHeight)
        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.hairline, style: StrokeStyle(lineWidth: 1, dash: [Space.xs, Space.xs])))
        .accessibilityElement(children: .combine)
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
            Image(systemName: "ellipsis").foregroundStyle(Color.textSecondary).tapTarget()
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel(Text("board.column.menu"))
    }

    @ViewBuilder private var footer: some View {
        if adding {
            VStack(alignment: .leading, spacing: Space.s) {
                TextField(accessible: "quickAdd.title", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).focused($focus)
                    .onSubmit { submit() }
                HStack {
                    Button("board.task.add") { submit() }.buttonStyle(.borderedProminent).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("cancel") { adding = false; draft = "" }.buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
            .padding(Space.m)
            .cardSurface(radius: Radius.m)
        } else {
            Button { adding = true; focus = true } label: {
                Label("board.task.add", systemImage: "plus")
                    .font(.subheadline).foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                    .tapTarget()
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let task: TodoTask
    let board: BoardModel
    let column: BoardColumn
    @State private var completing = false

    private var planning: PlanningData? { meta.planning(for: task.id) }
    private var checked: Bool { task.isDone != completing }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            TaskCheckbox(checked: checked, priority: planning?.priority ?? 0) { toggle() }
                .padding(.leading, -10).padding(.top, -6)
            Button { model.path = [task] } label: {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(verbatim: task.title).font(.rowTitle)
                        .strikethrough(checked, color: Color.textSecondary)
                        .foregroundStyle(checked ? Color.textSecondary : Color.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !task.description.isEmpty {
                        Text(verbatim: task.description).font(.footnote).foregroundStyle(Color.textSecondary).lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                            .multilineTextAlignment(.leading)
                    }
                    metaLine
                }
                .padding(.top, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .cardSurface(radius: Radius.m)
        .sensoryFeedback(.success, trigger: completing) { _, now in now }
        .contextMenu {
            Button { toggle() } label: { Label(task.isDone ? "task.markOpen" : "task.markDone", systemImage: "checkmark.circle") }
            Button { model.path = [task] } label: { Label("task.open", systemImage: "arrow.up.forward.square") }
            Menu {
                ForEach(targets, id: \.stableID) { target in
                    Button { move(to: target) } label: { Label { targetTitle(target) } icon: { Image(systemName: "rectangle.split.3x1") } }
                }
            } label: { Label("board.moveToColumn", systemImage: "arrow.left.arrow.right") }
            Button(role: .destructive) { Haptics.warning(); Task { await model.deleteTask(task) } } label: { Label("task.delete", systemImage: "trash") }
        }
        // VoiceOver: one element with the state as value; moving between columns has actions because drag is not accessible.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: task.title))
        .accessibilityValue(Text(verbatim: summary))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.path = [task] }
        .accessibilityAction(named: Text(task.isDone ? "task.markOpen" : "task.markDone")) { toggle() }
        .accessibilityActions {
            ForEach(targets, id: \.stableID) { target in
                Button { move(to: target) } label: { Text("board.moveTo \(Self.name(target))") }
            }
        }
    }

    /// Columns this card could move to (all except its own).
    private var targets: [BoardColumn] { board.columns.filter { $0.stableID != column.stableID } }
    private static func name(_ c: BoardColumn) -> String { BoardModel.isUnassigned(c) ? String(localized: "board.unassigned") : c.name }
    private func targetTitle(_ c: BoardColumn) -> Text { Text(verbatim: Self.name(c)) }
    private func move(to target: BoardColumn) { Haptics.select(); Task { await board.move(taskID: task.id, to: target, index: nil, model) } }

    private var summary: String {
        var parts: [String] = []
        if checked { parts.append(String(localized: "a11y.done")) }
        if let agent = meta.agentState(for: task) { parts.append(LanePresentation.name(agent.rawValue)) }
        if let p = planning?.priority, p > 0 { parts.append(TaskRow.priorityText(p)) }
        if let due = planning?.dueAt { parts.append(String(localized: "a11y.due \(DueFormat.text(due))")) }
        if let sub = meta.subtaskProgress[task.id] { parts.append(String(localized: "a11y.subtasks \(sub.done) \(sub.total)")) }
        let labels = meta.labels(for: task.id).map(\.name)
        if !labels.isEmpty { parts.append(labels.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var metaLine: some View {
        let labels = meta.labels(for: task.id)
        let due = planning?.dueAt
        let sub = meta.subtaskProgress[task.id]
        let priority = planning?.priority ?? 0
        let agent = meta.agentState(for: task)
        if agent != nil || due != nil || !labels.isEmpty || sub != nil || (priority > 0 && !task.isDone) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs)) : AnyLayout(HStackLayout(spacing: Space.s))
            layout {
                if let agent { AgentStateItem(state: agent) }
                if priority > 0 && !task.isDone {
                    MetaItem(symbol: "flag.fill", text: "P\(4 - priority)", tint: Color.priority(priority), textTint: Color.textSecondary)
                }
                if let due {
                    MetaItem(symbol: planning?.recurrence != nil ? "arrow.triangle.2.circlepath" : "calendar", text: DueFormat.text(due),
                             tint: task.isDone ? Color.textSecondary : DueFormat.style(due).color)
                }
                if let sub { MetaItem(symbol: "checklist", text: "\(sub.done)/\(sub.total)") }
                ForEach(labels.prefix(2)) { LabelChip(name: $0.name) }
            }
            .font(.rowMeta)
        }
    }

    private func toggle() {
        if task.isDone { Haptics.tap(); Task { await model.toggle(task) }; return }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.35)) { completing = true }
        Haptics.success()
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 450))
            await model.toggle(task)
            completing = false
        }
    }
}

/// Placeholder columns while the first load runs.
struct BoardSkeleton: View {
    /// Column width for the visible scroll width (same rule as the loaded board).
    let columnWidth: (CGFloat) -> CGFloat

    init(columnWidth: @escaping (CGFloat) -> CGFloat) { self.columnWidth = columnWidth }
    /// Fixed column width (used by the command center, which has its own column logic).
    init(width: CGFloat) { columnWidth = { _ in width } }

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var barHeight: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var barWidth: CGFloat = 110

    /// Placeholder bar; `seed` varies the length so the cards look like text.
    private func bar(_ seed: Int, height: CGFloat, opacity: Double = 1) -> some View {
        RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).fill(Color.hairline.opacity(opacity))
            .frame(width: barWidth * (0.5 + CGFloat(seed % 8) / 10), height: height)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Space.m) {
                ForEach(0..<3, id: \.self) { col in
                    VStack(alignment: .leading, spacing: Space.s) {
                        bar(4, height: barHeight).padding(.vertical, Space.s)
                        ForEach(0..<(3 - col % 2), id: \.self) { i in
                            VStack(alignment: .leading, spacing: Space.s) {
                                bar(i * 4 + col * 2 + 3, height: barHeight)
                                bar(i * 3 + 1, height: barHeight * 0.7, opacity: 0.6)
                            }
                            .padding(Space.m).frame(maxWidth: .infinity, alignment: .leading).cardSurface(radius: Radius.m)
                        }
                    }
                    .padding(.horizontal, Space.s)
                    .containerRelativeFrame(.horizontal) { available, _ in columnWidth(available) }
                    .background(Color.canvasRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                }
            }
            .pageMargins().padding(.top, Space.xs)
        }
        .opacity(pulse ? 0.5 : 1)
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("loading"))
    }
}

// MARK: Previews

#if DEBUG
@MainActor private enum BoardPreviewData {
    static let projectID = UUID()
    static let board = BoardModel(projectID: projectID)
    static let model = AppModel()
    static let column = BoardColumn(id: UUID(), name: "In Arbeit", color: "#3B82F6", tasks: [
        TodoTask(id: UUID(), projectID: projectID, title: "Donaudampfschifffahrtsgesellschaft anrufen", description: "Rückfrage zur Kündigung des Liegeplatzes"),
        TodoTask(id: UUID(), projectID: projectID, title: "Kartons besorgen"),
    ])
}

private struct BoardPreview: View {
    var body: some View {
        // The board stays on the skeleton (no sync engine in previews); columns and cards are previewed separately.
        BoardView(board: BoardPreviewData.board, showCompleted: false)
            .environment(BoardPreviewData.model).environment(TaskMeta())
    }
}

private struct ColumnPreview: View {
    var body: some View {
        let column = BoardPreviewData.column
        ScrollView {
            BoardColumnView(board: BoardPreviewData.board, column: column, showCompleted: false)
                .padding(Space.l)
        }
        .background(Color.canvas)
        .environment(BoardPreviewData.model).environment(TaskMeta())
    }
}

#Preview("Board skeleton light") { BoardPreview().preferredColorScheme(.light) }
#Preview("Board skeleton dark") { BoardPreview().preferredColorScheme(.dark) }
#Preview("Board skeleton accessibility5") { BoardPreview().dynamicTypeSize(.accessibility5) }
#Preview("Column light") { ColumnPreview().preferredColorScheme(.light) }
#Preview("Column dark") { ColumnPreview().preferredColorScheme(.dark) }
#Preview("Column accessibility5") { ColumnPreview().dynamicTypeSize(.accessibility5) }
#endif
