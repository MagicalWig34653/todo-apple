import SwiftUI
import TodoCore

/// Sheet sizing: a centered form sheet on iPad and Mac (iOS 18/macOS 15), detents only where it is a bottom sheet.
private struct QuickAddPresentation: ViewModifier {
    var largeOnly: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.presentationSizing(.form).presentationDetents(detents)
        } else {
            content.presentationDetents(detents)
        }
    }
    /// Regular width has no medium bottom sheet to fall back on: always full height so nothing is cut off.
    private var detents: Set<PresentationDetent> { largeOnly || sizeClass == .regular ? [.large] : [.medium, .large] }
}

/// Mac sheet size (min and ideal); the sheet scrolls when Dynamic Type needs more room.
private enum QuickAddLayout {
    static let macMinWidth: CGFloat = 440, macIdealWidth: CGFloat = 480
    static let macMinHeight: CGFloat = 380, macIdealHeight: CGFloat = 420
}

/// Bottom-sheet quick add: title, due chips, priority flag, project and label pickers.
struct QuickAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(TaskMeta.self) private var meta
    @Environment(\.dismiss) private var dismiss

    var projectID: UUID?
    var dueDate: Date?

    @State private var title = ""
    @State private var notes = ""
    @State private var due: Date?
    @State private var priority = 0
    @State private var project: UUID?
    @State private var labelIDs: Set<UUID> = []
    @State private var recurrence: RecurrenceRule?
    /// Due date the text alone produced (preview chip); nil once the user picked a date by hand.
    @State private var parsedDue: Date?
    @State private var labelTokens: [String] = []
    @State private var recognized: [String] = []
    /// Chips the user set by hand win over what the text parser finds.
    @State private var dueTouched = false
    @State private var priorityTouched = false
    @State private var projectTouched = false
    @State private var pickingDate = false
    @State private var saving = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var sendSize: CGFloat = TapTarget.minimum

    private var chosenProject: Project? { model.projects.first { $0.id == project } }
    private var parsedTitle: String { QuickAddParser.parse(title).title }
    private var canSave: Bool { !parsedTitle.isEmpty && project != nil && !saving }

    var body: some View {
        ScrollView {
            content
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.canvas)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: recognized)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: recurrence)
        .modifier(QuickAddPresentation(largeOnly: typeSize.isAccessibilitySize))
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.canvas)
        #if os(macOS)
        .frame(minWidth: QuickAddLayout.macMinWidth, idealWidth: QuickAddLayout.macIdealWidth,
               minHeight: QuickAddLayout.macMinHeight, idealHeight: QuickAddLayout.macIdealHeight)
        #endif
        .onAppear {
            if project == nil {
                project = projectID ?? model.projects.first(where: { $0.name == "Eingang" })?.id ?? model.projects.first?.id
            }
            if due == nil { due = dueDate }
            #if DEBUG
            if let text = ProcessInfo.processInfo.environment["TODO_DEBUG_QUICKADD_TEXT"] { title = text }
            #endif
            focused = true
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            TextField(accessible: "quickAdd.title", text: $title, axis: .vertical)
                .lineLimit(1...6)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { if canSave { save() } }
                .onChange(of: title) { _, new in
                    // A wrapping (vertical-axis) field turns Return into a line break: treat it as "save" instead.
                    if new.contains("\n") {
                        title = new.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                        if canSave { save() }
                        return
                    }
                    applyParse(new)
                }
                .accessibilityIdentifier("quickAddTitle")
            if !recognized.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Image(systemName: "sparkles").foregroundStyle(Color.tileOrange)
                    Text("quickAdd.recognized") + Text(verbatim: " ") + Text(verbatim: recognized.joined(separator: " · ")).fontWeight(.semibold)
                }
                .font(.caption).foregroundStyle(Color.textSecondary).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                .transition(.opacity)
            }
            preview
            TextField(accessible: "quickAdd.notes", text: $notes, axis: .vertical)
                .font(.subheadline).foregroundStyle(Color.textSecondary).lineLimit(2...5)
                .frame(maxWidth: .infinity, minHeight: TapTarget.minimum, alignment: .topLeading).contentShape(Rectangle())

            dueChips

            let bottomLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s)) : AnyLayout(HStackLayout(spacing: Space.s))
            bottomLayout {
                priorityMenu
                labelMenu
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Button { save() } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold)).foregroundStyle(Color.onBrand)
                        .frame(width: sendSize, height: sendSize)
                        .background(canSave ? Color.brand : Color.brand.opacity(0.35), in: Circle())
                        .shadow(color: canSave ? Color.brand.opacity(0.35) : .clear, radius: 6, y: 3)
                }
                .buttonStyle(PressableStyle()).disabled(!canSave)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(Text("task.add"))
                .accessibilityIdentifier("quickAddSave")
            }
            Divider()
            projectMenu
        }
        .padding(.vertical, Space.l)
        .pageMargins()
        .frame(maxWidth: .infinity, alignment: .leading)
        .readableWidth()
    }

    // MARK: pieces

    /// What the text produced: due date and repetition, shown while typing and gone with the text. The due chip
    /// disappears once the user picks a date by hand (the pick wins, see `dueTouched`).
    @ViewBuilder private var preview: some View {
        let shownDue = dueTouched ? nil : parsedDue
        if shownDue != nil || recurrence != nil {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs)) : AnyLayout(HStackLayout(spacing: Space.m))
            layout {
                if let shownDue {
                    Label { Text("quickAdd.preview.due \(DueFormat.text(shownDue))") } icon: { Image(systemName: "calendar") }
                        .accessibilityIdentifier("quickAddPreviewDue")
                }
                if let recurrence {
                    Label { Text("quickAdd.preview.repeat \(RepeatText.text(recurrence))") } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                        .accessibilityIdentifier("quickAddPreviewRepeat")
                }
            }
            .font(.footnote.weight(.medium)).foregroundStyle(Color.brand)
            .transition(.opacity)
        }
    }

    /// Due chips: one scrolling row, or a column from the accessibility sizes on so no chip is cut off.
    @ViewBuilder private var dueChips: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Space.s) { dueChipItems }
        } else {
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: Space.s) { dueChipItems } }
        }
    }

    @ViewBuilder private var dueChipItems: some View {
        dueChip("due.today", date: DueFormat.today(), icon: "sun.max")
        dueChip("due.tomorrow", date: DueFormat.tomorrow(), icon: "sunrise")
        dueChip("due.weekend", date: DueFormat.weekend(), icon: "sofa")
        Button { pickingDate = true } label: {
            chip(icon: "calendar", text: customDueText, active: isCustomDue, tint: .brand)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $pickingDate) {
            DatePicker("", selection: Binding(get: { due ?? DueFormat.tomorrow() }, set: { dueTouched = true; due = $0 }), displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical).labelsHidden().padding(Space.l)
                .presentationCompactAdaptation(.popover)
        }
    }


    private var isCustomDue: Bool {
        guard let due else { return false }
        return ![DueFormat.today(), DueFormat.tomorrow(), DueFormat.weekend()].contains { Calendar.current.isDate($0, inSameDayAs: due) }
    }

    private var customDueText: String { isCustomDue ? DueFormat.text(due!) : String(localized: "due.pick") }

    private func dueChip(_ key: LocalizedStringKey, date: Date, icon: String) -> some View {
        let active = due.map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false
        return Button {
            Haptics.tap()
            dueTouched = true
            due = active ? nil : date
        } label: {
            chip(icon: icon, text: nil, key: key, active: active, tint: DueFormat.style(date).color == .secondary ? .brand : DueFormat.style(date).color)
        }
        .buttonStyle(.plain)
    }

    private func chip(icon: String, text: String?, key: LocalizedStringKey? = nil, active: Bool, tint: Color) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: icon).font(.footnote)
            if let key { Text(key) } else if let text { Text(verbatim: text) }
        }
        .fixedSize(horizontal: true, vertical: false)
        .font(.footnote.weight(.medium))
        .foregroundStyle(active ? tint : Color.textSecondary)
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .background(active ? tint.opacity(0.10) : Color.canvasRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(active ? tint.opacity(0.5) : Color.hairline, lineWidth: 1))
        .contentShape(Capsule())
        .tapTarget()
    }

    private var priorityMenu: some View {
        Menu {
            ForEach([3, 2, 1, 0], id: \.self) { p in
                Button { priorityTouched = true; priority = p } label: {
                    Label { priorityName(p) } icon: { Image(systemName: priority == p ? "checkmark" : "flag.fill") }
                }
            }
        } label: {
            chip(icon: priority > 0 ? "flag.fill" : "flag", text: nil, key: priority > 0 ? priorityKey(priority) : "task.priority",
                active: priority > 0, tint: Color.priority(priority))
        }
        .menuStyle(.button).buttonStyle(.plain)
    }

    private var labelMenu: some View {
        Menu {
            if meta.allLabels.isEmpty { Text("label.none") }
            ForEach(meta.allLabels) { l in
                Button {
                    if labelIDs.contains(l.id) { labelIDs.remove(l.id) } else { labelIDs.insert(l.id) }
                } label: { Label(l.name, systemImage: labelIDs.contains(l.id) ? "checkmark" : "tag") }
            }
        } label: {
            chip(icon: "tag", text: labelIDs.isEmpty ? nil : String(labelIDs.count), key: labelIDs.isEmpty ? "task.labels" : nil,
                active: !labelIDs.isEmpty, tint: .brand)
        }
        .menuStyle(.button).buttonStyle(.plain)
    }

    private var projectMenu: some View {
        Menu {
            ForEach(flatProjects(), id: \.0.id) { entry in
                Button { projectTouched = true; project = entry.0.id } label: {
                    Label(String(repeating: "  ", count: entry.1) + entry.0.name, systemImage: project == entry.0.id ? "checkmark" : "circle.fill")
                }
            }
        } label: {
            HStack(spacing: Space.s) {
                ProjectDot(id: project)
                Text(verbatim: chosenProject?.name ?? String(localized: "projects.none"))
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(Color.primary)
            .tapTarget()
        }
        .menuStyle(.button).buttonStyle(.plain)
    }

    private func flatProjects() -> [(Project, Int)] {
        func walk(_ nodes: [ProjectNode], _ depth: Int) -> [(Project, Int)] {
            nodes.flatMap { [($0.project, depth)] + walk($0.children ?? [], depth + 1) }
        }
        return walk(model.tree, 0)
    }

    @ViewBuilder private func priorityName(_ p: Int) -> some View {
        switch p {
        case 3: Text("priority.p1")
        case 2: Text("priority.p2")
        case 1: Text("priority.p3")
        default: Text("priority.p4")
        }
    }

    private func priorityKey(_ p: Int) -> LocalizedStringKey {
        switch p { case 3: "priority.p1"; case 2: "priority.p2"; default: "priority.p3" }
    }

    // MARK: natural language

    private func applyParse(_ text: String) {
        let parsed = QuickAddParser.parse(text)
        recognized = parsed.recognized
        if !dueTouched { due = parsed.due ?? dueDate }
        if !priorityTouched { priority = parsed.priority ?? 0 }
        recurrence = parsed.recurrenceRule
        parsedDue = parsed.due
        labelTokens = parsed.labelTokens
        if !projectTouched {
            if let token = parsed.projectToken?.lowercased(),
               let match = model.projects.first(where: { $0.name.lowercased().hasPrefix(token) }) {
                project = match.id
            } else {
                project = projectID ?? model.projects.first(where: { $0.name == "Eingang" })?.id ?? model.projects.first?.id
            }
        }
    }

    // MARK: save

    private func save() {
        guard canSave, let projectID = project else { return }
        saving = true
        let text = parsedTitle, description = notes, due = due, priority = priority, labels = labelIDs
        let repeating = recurrence, newLabelNames = labelTokens
        Task {
            guard let id = await model.createTask(projectID: projectID, title: text) else { saving = false; return }
            Haptics.success()
            dismiss()
            // Planning and labels go through the outbox: it waits until the task exists on the server (offline too).
            if due != nil || priority > 0 || repeating != nil {
                await model.savePlanning(taskID: id, PlanningData(dueAt: due, priority: priority, recurrence: repeating))
            }
            for l in labels { if let known = meta.allLabels.first(where: { $0.id == l }) { await model.setLabel(known, on: id, enabled: true) } }
            for name in newLabelNames { await model.addLabel(named: name, to: id, known: meta.allLabels) }
            if !description.isEmpty, let t = model.tasks.first(where: { $0.id == id }) {
                _ = await model.updateTask(t, TaskUpdate(description: description))
            }
        }
    }
}

#if DEBUG
@MainActor private func quickAddPreview() -> some View {
    QuickAddSheet(projectID: nil, dueDate: nil)
        .environment(AppModel()).environment(TaskMeta())
}
#Preview("Quick add light") { quickAddPreview().preferredColorScheme(.light) }
#Preview("Quick add dark") { quickAddPreview().preferredColorScheme(.dark) }
#Preview("Quick add accessibility5") { quickAddPreview().dynamicTypeSize(.accessibility5) }
#endif

/// "Täglich" / "Alle 2 Wochen": the rule as text (interval 1 uses the plain frequency names).
enum RepeatText {
    static func text(_ rule: RecurrenceRule) -> String {
        let n = rule.interval
        switch (rule.frequency, n > 1) {
        case (.daily, false): return String(localized: "repeat.daily")
        case (.weekly, false): return String(localized: "repeat.weekly")
        case (.monthly, false): return String(localized: "repeat.monthly")
        case (.daily, true): return String(localized: "repeat.every.days \(n)")
        case (.weekly, true): return String(localized: "repeat.every.weeks \(n)")
        case (.monthly, true): return String(localized: "repeat.every.months \(n)")
        }
    }
}
