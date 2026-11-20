import SwiftUI
import TodoCore

/// "Kalender" (card 8CECAD24, phase 1: read-only layouts). iPhone and accessibility text sizes: day list with week strip
/// and "Ohne Termin" as a sheet. iPad and Mac: week grid with 15-minute raster and a side panel "Ohne Termin"; when the
/// window is too narrow for the grid the panel becomes the sheet, and below that the day list takes over.
/// Dragging, writing and offline come in phase 2 (docs/CALENDAR.md).
struct CalendarScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(TaskMeta.self) private var meta
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Seeded once with the live model or a sample model; the screen owns it afterwards.
    @State private var model: CalendarModel
    @ScaledMetric(relativeTo: .body) private var timeColumn = CalendarMetrics.timeColumn
    @ScaledMetric(relativeTo: .body) private var dayColumn = CalendarMetrics.dayColumnMin
    @ScaledMetric(relativeTo: .body) private var panel = CalendarMetrics.sidePanel

    @MainActor init(model: CalendarModel? = nil) { _model = State(initialValue: model ?? CalendarModel()) }

    private var phoneLayout: Bool {
        #if os(iOS)
        sizeClass == .compact || typeSize.isAccessibilitySize
        #else
        false
        #endif
    }

    /// Narrowest width the seven day columns and the time column need.
    private var gridMinimum: CGFloat { timeColumn + dayColumn * 7 }

    var body: some View {
        Group {
            if phoneLayout {
                CalendarDayList(model: model)
            } else {
                ViewThatFits(in: .horizontal) {
                    CalendarWeekView(model: model, showsPanel: true).frame(minWidth: gridMinimum + panel)
                    CalendarWeekView(model: model, showsPanel: false).frame(minWidth: gridMinimum)
                    CalendarDayList(model: model)
                }
            }
        }
        .background(Color.canvas)
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.notice != nil { CalendarNoticeBanner(model: model).padding(.vertical, Space.xs).frame(maxWidth: .infinity).background(Color.canvas) }
        }
        .toolbarTitleDisplayMode(.inline)
        .navigationTitle("view.calendar")
        .task(id: model.window.from) { model.hasRecurrence = { [meta] in meta.planning(for: $0)?.recurrence != nil }; await model.load(app) }
        .refreshable { await model.load(app) }
        // After a reconnect the queue has sent the offline edits: show what the server made of them.
        .onChange(of: app.unsentChanges) { old, new in if old > 0, new == 0 { Task { await model.load(app, quiet: true) } } }
        .sheet(isPresented: Binding(get: { model.selection != nil }, set: { if !$0 { model.selection = nil } })) {
            if let id = model.selection { CalendarDetailSheet(model: model, id: id).environment(app).environment(meta).tint(.brand) }
        }
    }
}

// MARK: Previews

#if DEBUG
private struct CalendarPreviewFrame<Content: View>: View {
    @State private var app = AppModel()
    @State private var meta = TaskMeta()
    @ViewBuilder var content: () -> Content
    var body: some View { NavigationStack { content() }.environment(app).environment(meta).tint(.brand) }
}

#Preview("Calendar light") { CalendarPreviewFrame { CalendarScreen(model: CalendarSeed.model()) }.preferredColorScheme(.light) }
#Preview("Calendar dark") { CalendarPreviewFrame { CalendarScreen(model: CalendarSeed.model()) }.preferredColorScheme(.dark) }
#Preview("Calendar accessibility5") { CalendarPreviewFrame { CalendarScreen(model: CalendarSeed.model()) }.dynamicTypeSize(.accessibility5) }
#Preview("Calendar week light", traits: .fixedLayout(width: 1180, height: 820)) {
    CalendarPreviewFrame { CalendarWeekView(model: CalendarSeed.model(), showsPanel: true) }.preferredColorScheme(.light)
}
#Preview("Calendar week dark", traits: .fixedLayout(width: 1180, height: 820)) {
    CalendarPreviewFrame { CalendarWeekView(model: CalendarSeed.model(), showsPanel: true) }.preferredColorScheme(.dark)
}
#Preview("Calendar week accessibility5", traits: .fixedLayout(width: 1180, height: 820)) {
    CalendarPreviewFrame { CalendarWeekView(model: CalendarSeed.model(), showsPanel: true) }.dynamicTypeSize(.accessibility5)
}
#Preview("Calendar unscheduled light") { CalendarPreviewFrame { CalendarUnscheduledSheet(model: CalendarSeed.model()) }.preferredColorScheme(.light) }
#Preview("Calendar unscheduled dark") { CalendarPreviewFrame { CalendarUnscheduledSheet(model: CalendarSeed.model()) }.preferredColorScheme(.dark) }
#Preview("Calendar unscheduled accessibility5") { CalendarPreviewFrame { CalendarUnscheduledSheet(model: CalendarSeed.model()) }.dynamicTypeSize(.accessibility5) }
#Preview("Calendar card light") {
    CalendarPreviewFrame { CalendarCardGallery() }.preferredColorScheme(.light)
}
#Preview("Calendar card dark") {
    CalendarPreviewFrame { CalendarCardGallery() }.preferredColorScheme(.dark)
}
#Preview("Calendar card accessibility5") {
    CalendarPreviewFrame { CalendarCardGallery() }.dynamicTypeSize(.accessibility5)
}

/// Cards and chips on their own (small size, long German words).
private struct CalendarCardGallery: View {
    var body: some View {
        let model = CalendarSeed.model()
        ScrollView {
            VStack(spacing: Space.s) {
                ForEach(model.selectedContent.timed.prefix(4)) { placed in
                    CalendarEntryCard(entry: placed.entry, marks: model.cardMarks(placed.entry),
                                      projectName: model.projectName(placed.entry.projectID), projectColor: model.projectColor(placed.entry.projectID))
                }
                if let e = model.unscheduled.last {
                    UnscheduledCard(entry: e, projectName: model.projectName(e.projectID), projectColor: model.projectColor(e.projectID))
                }
            }
            .pageMargins().padding(.vertical, Space.s)
        }
        .background(Color.canvas)
    }
}
#endif
