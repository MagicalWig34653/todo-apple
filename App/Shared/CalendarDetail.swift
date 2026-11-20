import SwiftUI
import TodoCore

// MARK: Menu on every card (iPhone long press, Mac right click, VoiceOver actions)

private struct CalendarEntryMenu: ViewModifier {
    let model: CalendarModel
    let entry: ScheduleEntry
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button { model.openDetail(entry.id) } label: { Label("calendar.action.details", systemImage: "info.circle") }
                if entry.canDrag {
                    Button { model.openDetail(entry.id, editor: true) } label: { Label("calendar.action.edit", systemImage: "clock") }
                    if entry.plannedAt != nil {
                        Button(role: .destructive) { unschedule() } label: { Label("calendar.action.unschedule", systemImage: "tray.and.arrow.down") }
                    }
                }
            }
            .accessibilityAction(named: Text("calendar.action.details")) { model.openDetail(entry.id) }
            .modifier(EditActions(model: model, entry: entry, unschedule: unschedule))
    }

    private func unschedule() { Task { await model.drop(entry.id, onto: .unscheduled, app: app) } }
}

/// VoiceOver actions only for cards the user may change.
private struct EditActions: ViewModifier {
    let model: CalendarModel
    let entry: ScheduleEntry
    let unschedule: () -> Void

    func body(content: Content) -> some View {
        if entry.canDrag {
            content
                .accessibilityAction(named: Text("calendar.action.edit")) { model.openDetail(entry.id, editor: true) }
                .accessibilityAction(named: Text("calendar.action.unschedule")) { if entry.plannedAt != nil { unschedule() } }
        } else {
            content
        }
    }
}

extension View {
    /// Context menu (details, "Start und Dauer", "Entplanen") and VoiceOver actions of a calendar card.
    func calendarMenu(_ model: CalendarModel, _ entry: ScheduleEntry) -> some View { modifier(CalendarEntryMenu(model: model, entry: entry)) }

    /// Cards with the edit role can be dragged to another slot, the all-day row or back to the sidebar.
    @ViewBuilder func calendarDraggable(_ entry: ScheduleEntry) -> some View {
        if entry.canDrag { draggable(CalendarDrag(calendarTaskID: entry.id)) } else { self }
    }
}

// MARK: Detail sheet (full title, project, start, duration, due date, marks; actions)

struct CalendarDetailSheet: View {
    let model: CalendarModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    private enum Route: Hashable { case editor }
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let entry = model.entry(id) { details(entry) } else { EmptyState(symbol: "calendar.badge.exclamationmark", title: "calendar.detail.gone") }
            }
            .navigationTitle("calendar.detail.title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("ok") { dismiss() }.accessibilityIdentifier("calendar.detail.close") } }
            .navigationDestination(for: Route.self) { _ in CalendarScheduleEditor(model: model, id: id) { dismiss() } }
        }
        .onAppear { if model.opensEditor { path = [.editor]; model.opensEditor = false } }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 420, idealHeight: 560)
        #endif
    }

    private func details(_ entry: ScheduleEntry) -> some View {
        let marks = CalendarMark.marks(for: entry, conflicts: model.marks(for: entry), calendar: model.calendar)
        return Form {
            Section {
                Text(verbatim: entry.title).font(.detailTitle).textSelection(.enabled)
                    .accessibilityIdentifier("calendar.detail.title")
                if let name = model.projectName(entry.projectID) {
                    LabeledContent("calendar.detail.project") {
                        HStack(spacing: Space.s) {
                            Circle().fill(model.projectColor(entry.projectID)).frame(width: Space.s, height: Space.s).accessibilityHidden(true)
                            Text(verbatim: name)
                        }
                    }
                }
            }
            Section {
                LabeledContent("calendar.detail.start") { Text(verbatim: startText(entry)).multilineTextAlignment(.trailing) }
                if entry.start != nil, !entry.plannedAllDay {
                    LabeledContent("calendar.detail.duration") { Text(verbatim: CalendarFormat.duration(minutes: entry.minutes)) }
                }
                LabeledContent("calendar.detail.due") {
                    Text(verbatim: entry.dueAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "calendar.detail.none"))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("calendar.detail.autoStart") { Text(verbatim: autoStartText(entry)) }
            } footer: {
                Text("calendar.detail.dueHint")
            }
            if !marks.filter({ !$0.isDue }).isEmpty {
                Section { CalendarMarkRow(marks: marks.filter { !$0.isDue }) }
            }
            Section {
                if entry.canDrag {
                    NavigationLink(value: Route.editor) { Label("calendar.action.edit", systemImage: "clock") }
                        .accessibilityIdentifier("calendar.detail.edit")
                    if entry.plannedAt != nil {
                        Button(role: .destructive) {
                            Task { await model.drop(entry.id, onto: .unscheduled, app: app); dismiss() }
                        } label: { Label("calendar.action.unschedule", systemImage: "tray.and.arrow.down") }
                            .accessibilityIdentifier("calendar.detail.unschedule")
                    }
                } else {
                    Label { Text(entry.isDone ? "calendar.detail.doneHint" : "calendar.detail.readOnlyHint") } icon: { Image(systemName: entry.isDone ? "checkmark.circle" : "lock") }
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    private func startText(_ entry: ScheduleEntry) -> String {
        guard let start = entry.start else { return String(localized: "calendar.detail.unscheduled") }
        if entry.plannedAllDay { return start.formatted(.dateTime.weekday(.wide).day().month(.wide)) + ", " + String(localized: "calendar.allDay") }
        let end = entry.end.map { CalendarFormat.time($0) } ?? ""
        return start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + ", " + CalendarFormat.time(start) + "–" + end
    }

    /// Display only (the permission is set in the web app; the calendar never switches it).
    private func autoStartText(_ entry: ScheduleEntry) -> String {
        if let at = entry.autoStartedAt { return String(localized: "calendar.detail.autoStarted \(CalendarFormat.time(at))") }
        return entry.autoStart ? String(localized: "calendar.detail.autoStartOn") : String(localized: "calendar.detail.autoStartOff")
    }
}

// MARK: Editor "Start und Dauer"

struct CalendarScheduleEditor: View {
    let model: CalendarModel
    let id: UUID
    let finish: () -> Void
    @Environment(AppModel.self) private var app
    @State private var start: Date
    @State private var minutes: Int
    @State private var allDay: Bool
    @State private var invalid = false

    init(model: CalendarModel, id: UUID, finish: @escaping () -> Void) {
        self.model = model; self.id = id; self.finish = finish
        let entry = model.entry(id)
        let fallback = model.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: model.selectedDay) ?? model.selectedDay
        _start = State(initialValue: entry?.plannedAt ?? fallback)
        _minutes = State(initialValue: entry?.minutes ?? CalendarRules.defaultMinutes)
        _allDay = State(initialValue: entry?.plannedAllDay ?? false)
    }

    private var entry: ScheduleEntry? { model.entry(id) }

    var body: some View {
        Form {
            Section {
                Toggle("calendar.editor.allDay", isOn: $allDay).accessibilityIdentifier("calendar.editor.allDay")
                DatePicker("calendar.editor.start", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                    .accessibilityIdentifier("calendar.editor.start")
                if !allDay {
                    Stepper(value: $minutes, in: CalendarRules.minimumBlockMinutes...CalendarRules.maximumMinutes, step: CalendarRules.stepMinutes) {
                        LabeledContent("calendar.editor.duration") { Text(verbatim: CalendarFormat.duration(minutes: minutes)).monospacedDigit() }
                    }
                    .accessibilityIdentifier("calendar.editor.duration")
                }
            } footer: {
                Text("calendar.editor.hint")
            }
            if invalid { Text("calendar.notice.invalidMinutes").foregroundStyle(Color.dueOverdue).font(.footnote) }
            if let entry, entry.plannedAt != nil {
                Section {
                    Button(role: .destructive) {
                        Task { await model.drop(id, onto: .unscheduled, app: app) }
                        finish()
                    } label: { Label("calendar.action.unschedule", systemImage: "tray.and.arrow.down") }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("calendar.action.edit")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("save") { save() }.accessibilityIdentifier("calendar.editor.save") }
        }
    }

    private func save() {
        guard let entry else { finish(); return }
        switch ScheduleEditing.patch(for: entry, start: start, minutes: allDay ? nil : minutes, allDay: allDay, calendar: model.calendar) {
        case .noChange: finish()
        case .invalidMinutes: invalid = true
        case .patch(let patch):
            Task { await model.submit(entry, patch, app: app) }
            finish()
        }
    }
}

// MARK: Banner (rollback and offline hints)

struct CalendarNoticeBanner: View {
    let model: CalendarModel

    var body: some View {
        if let notice = model.notice {
            NoticeBanner(symbol: notice.isError ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath", text: LocalizedStringKey(notice.key),
                         tint: notice.isError ? .dueOverdue : .brand, action: { model.dismissNotice() })
                .padding(.horizontal, 0)
                .accessibilityIdentifier("calendar.notice")
        }
    }
}
