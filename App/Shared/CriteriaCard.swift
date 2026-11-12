import SwiftUI
import TodoCore

/// Acceptance criteria of a card, editable like in the PWA: tick, add, rename (context menu or swipe), delete.
struct CriteriaCard: View {
    let criteria: [TaskCriterion]
    let busy: Bool
    let onAdd: (String) -> Void
    let onToggle: (TaskCriterion) -> Void
    let onEdit: (TaskCriterion, String) -> Void
    let onDelete: (TaskCriterion) -> Void
    @State private var newText = ""
    @State private var editing: TaskCriterion?
    @State private var editText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("criteria.title").font(.sectionTitle).accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.xs)
                if !criteria.isEmpty {
                    Text("criteria.count \(criteria.filter(\.completed).count) \(criteria.count)")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.textSecondary)
                }
            }
            ForEach(criteria) { c in row(c) }
            HStack(alignment: .bottom, spacing: Space.s) {
                TextField(accessible: "criteria.add", text: $newText, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .accessibilityIdentifier("criteria.field")
                Button(action: add) { Image(systemName: "plus.circle.fill").font(.title3).tapTarget() }
                    .buttonStyle(.plain).foregroundStyle(Color.brand)
                    .disabled(busy || newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(Text("criteria.addButton"))
                    .accessibilityIdentifier("criteria.addButton")
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .alert("criteria.edit", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField(accessible: "criteria.text", text: $editText)
            Button("save") { if let c = editing { onEdit(c, editText) }; editing = nil }
            Button("cancel", role: .cancel) { editing = nil }
        }
    }

    private func add() {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        onAdd(t)
        newText = ""
    }

    private func row(_ c: TaskCriterion) -> some View {
        Button { onToggle(c) } label: {
            HStack(alignment: .top, spacing: Space.s) {
                Image(systemName: c.completed ? "checkmark.circle.fill" : "circle")
                    .font(.body).foregroundStyle(c.completed ? Color.tileGreen : Color.textSecondary)
                    .scaledSquare(22, relativeTo: .body)
                MarkdownText(c.text).font(.subheadline).strikethrough(c.completed)
                    .foregroundStyle(c.completed ? Color.textSecondary : Color.primary)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .tapTarget()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityValue(Text(c.completed ? "agent.criterion.done" : "agent.criterion.open"))
        .accessibilityIdentifier("criteria.row")
        .contextMenu {
            Button { editText = c.text; editing = c } label: { Label("criteria.edit", systemImage: "pencil") }
            Button(role: .destructive) { onDelete(c) } label: { Label("criteria.delete", systemImage: "trash") }
        }
        .accessibilityAction(named: Text("criteria.edit")) { editText = c.text; editing = c }
        .accessibilityAction(named: Text("criteria.delete")) { onDelete(c) }
    }
}

/// Prerequisites ("Hängt ab von") and the milestone of a card, read only (planning-ext); tapping a prerequisite opens it.
struct PlanningLinksCard: View {
    let dependencies: [TodoTask]
    let milestone: MilestoneWithTasks?
    let open: (TodoTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if !dependencies.isEmpty {
                Text("links.dependencies").font(.sectionTitle).accessibilityAddTraits(.isHeader)
                ForEach(dependencies) { t in
                    Button { open(t) } label: {
                        HStack(spacing: Space.s) {
                            Image(systemName: t.isDone ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(t.isDone ? Color.tileGreen : Color.dueToday)
                            Text(verbatim: t.title).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                                .strikethrough(t.isDone).foregroundStyle(t.isDone ? Color.textSecondary : Color.primary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(Color.textSecondary)
                        }
                        .tapTarget().contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(Text(t.isDone ? "links.done" : "links.open"))
                }
                let open = dependencies.filter { !$0.isDone }.count
                if open > 0 { Text("links.blockedBy \(open)").font(.caption).foregroundStyle(Color.dueToday) }
            }
            if let m = milestone {
                if !dependencies.isEmpty { Divider() }
                Text("links.milestone").font(.sectionTitle).accessibilityAddTraits(.isHeader)
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Image(systemName: "flag.fill").foregroundStyle(Color.brand).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(verbatim: m.milestone.title).font(.subheadline.weight(.semibold))
                        HStack(spacing: Space.s) {
                            Text("links.milestoneProgress \(m.doneCount) \(m.tasks.count)")
                            if let due = m.milestone.dueAt { Text(due, format: .dateTime.day().month().year()) }
                        }
                        .font(.caption).foregroundStyle(Color.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                ProgressView(value: Double(m.doneCount), total: Double(max(m.tasks.count, 1))).tint(Color.brand)
                    .accessibilityHidden(true)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("links.card")
    }
}

#if DEBUG
private struct CriteriaPreview: View {
    let pid = UUID(), tid = UUID()
    var body: some View {
        ScrollView {
            VStack(spacing: Space.m) {
                CriteriaCard(criteria: [
                    TaskCriterion(id: UUID(), taskID: tid, text: "Mobil zuerst", completed: true, version: 1),
                    TaskCriterion(id: UUID(), taskID: tid, text: "Tablet **auch**", completed: false, version: 1),
                ], busy: false, onAdd: { _ in }, onToggle: { _ in }, onEdit: { _, _ in }, onDelete: { _ in })
                PlanningLinksCard(
                    dependencies: [TodoTask(id: UUID(), projectID: pid, title: "API-Vertrag festlegen", status: "done"),
                                   TodoTask(id: UUID(), projectID: pid, title: "Designsystem anpassen")],
                    milestone: MilestoneWithTasks(milestone: Milestone(id: UUID(), projectID: pid, title: "Beta", dueAt: Date().addingTimeInterval(864_000)),
                                                  tasks: [TodoTask(id: UUID(), projectID: pid, title: "A", status: "done"), TodoTask(id: UUID(), projectID: pid, title: "B")])
                ) { _ in }
            }
            .padding(Space.page)
        }
        .background(Color.canvas)
    }
}

#Preview("Criteria light") { CriteriaPreview().preferredColorScheme(.light) }
#Preview("Criteria dark") { CriteriaPreview().preferredColorScheme(.dark) }
#Preview("Criteria accessibility5") { CriteriaPreview().dynamicTypeSize(.accessibility5) }
#endif
