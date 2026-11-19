import SwiftUI
import TodoCore

/// "Steuerzentrale": kanban (default) or list of agent work for the whole account or one project, plus updates and
/// all open questions. Refetches on appear, on foreground and on pull-to-refresh.
struct CommandCenterView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    let projectID: UUID?
    @State private var cc: CommandCenterModel
    @State private var showBrief = false
    @State private var confirmTemplate = false
    @State private var templateDone = false

    init(projectID: UUID?) {
        self.projectID = projectID
        _cc = State(initialValue: CommandCenterModel(projectID: projectID))
    }

    private var project: Project? { projectID.flatMap { id in app.projects.first { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if cc.unsupported {
                    EmptyState(symbol: "exclamationmark.triangle", title: "cc.unsupported", message: "cc.unsupportedHint")
                } else {
                    switch cc.section {
                    case .overview: overview
                    case .updates: UpdatesSection(cc: cc)
                    case .questions: QuestionsSection(cc: cc)
                    }
                }
            }
        }
        // The notification explainer sits below the content so it never pushes the title and controls down.
        .safeAreaInset(edge: .bottom, spacing: 0) { PushPrimerCard() }
        .background(Color.canvas)
        // The page header already shows the title; an inline copy in the bar would duplicate it.
        #if os(iOS)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        #else
        .navigationTitle("cc.title")
        #endif
        .toolbar { toolbarContent }
        .task { await cc.refresh(app) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await cc.refresh(app) } } }
        .onChange(of: cc.mode) { _, _ in Task { await cc.refreshIfModeChanged(app) } }
        .onChange(of: app.reviewUndoGeneration) { _, _ in Task { await cc.refresh(app) } }
        .onChange(of: cc.sort) { _, _ in Task { await cc.refresh(app) } }
        .alert(LocalizedStringKey(cc.errorKey ?? ""), isPresented: Binding(get: { cc.errorKey != nil }, set: { if !$0 { cc.errorKey = nil } })) {
            Button("ok") {}
        }
        .alert("cc.template.title", isPresented: $confirmTemplate) {
            Button("cc.template.apply") { Task { templateDone = await cc.applyAgentColumns(app) } }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("cc.template.message")
        }
        .sheet(isPresented: $showBrief) {
            if let projectID { AgentBriefView(projectID: projectID, projectName: project?.name ?? "") }
        }
    }

    // MARK: Header

    /// Control layers above the content: the toolbar (mode, menu) and this section picker. Lane counts live in the
    /// lane headers, so there is no separate counter strip.
    private var header: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("cc.title").font(typeSize.isAccessibilitySize ? Font.system(.title, design: .rounded).weight(.bold) : .screenTitle).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    subtitle
                }
                Spacer()
                if cc.loading { ProgressView().controlSize(.small) }
            }
            Picker("cc.section", selection: $cc.section) {
                Text("cc.section.overview").tag(CommandCenterModel.Section.overview)
                Text("cc.section.updates").tag(CommandCenterModel.Section.updates)
                Text("cc.section.questions \(cc.summary.openQuestions)").tag(CommandCenterModel.Section.questions)
            }
            .pickerStyle(.segmented).labelsHidden()
        }
        .pageMargins().padding(.top, Space.s).padding(.bottom, Space.m)
    }

    /// Scope (account or project link) plus the number of agents that are working right now.
    private var subtitle: some View {
        AdaptiveStack(spacing: Space.s) {
            if let project {
                Button { app.selectedProjectID = project.id } label: {
                    HStack(spacing: Space.xs) {
                        Text(verbatim: "#").foregroundStyle(Color.project(project.id))
                        Text(verbatim: project.name)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .font(.subheadline).foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)
                .tapTarget()
            } else {
                Text("cc.scope.account").font(.subheadline).foregroundStyle(Color.textSecondary)
            }
            if cc.summary.activeAgents > 0 {
                HStack(spacing: Space.xs) {
                    Image(systemName: "cpu").accessibilityHidden(true)
                    Text("cc.summary.agents \(cc.summary.activeAgents)")
                }
                .font(.subheadline.weight(.medium)).foregroundStyle(Color.priority(1))
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Overview

    @ViewBuilder private var overview: some View {
        if cc.data == nil {
            if cc.loading { BoardSkeleton(width: 280).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) }
            else { EmptyState(symbol: "wifi.exclamationmark", title: "cc.loadFailed").frame(maxWidth: .infinity, maxHeight: .infinity) }
        } else if cc.mode == .kanban {
            KanbanLanes(cc: cc, showProject: true)
        } else {
            CommandListSection(cc: cc, showProject: true)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if cc.section == .overview {
                Picker("cc.mode", selection: $cc.mode) {
                    Label("cc.mode.kanban", systemImage: "rectangle.split.3x1").tag(CommandCenterModel.Mode.kanban)
                    Label("cc.mode.list", systemImage: "list.bullet").tag(CommandCenterModel.Mode.list)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .fixedSize()
            }
            Menu {
                Button { Task { await cc.refresh(app) } } label: { Label("cc.refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
                if cc.mode == .list {
                    Picker("cc.sort", selection: $cc.sort) {
                        Text("cc.sort.attention").tag(CommandCenterOptions.Sort.attention)
                        Text("cc.sort.updated").tag(CommandCenterOptions.Sort.updated)
                        Text("cc.sort.due").tag(CommandCenterOptions.Sort.due)
                        Text("cc.sort.progress").tag(CommandCenterOptions.Sort.progress)
                        Text("cc.sort.title").tag(CommandCenterOptions.Sort.title)
                    }
                }
                if projectID != nil {
                    Divider()
                    Button { showBrief = true } label: { Label("cc.brief.open", systemImage: "doc.text") }
                    Button { confirmTemplate = true } label: { Label("cc.template.button", systemImage: "rectangle.split.3x1") }
                }
            } label: { Label("cc.more", systemImage: "ellipsis") }
        }
    }
}

// MARK: Kanban

/// Lanes side by side (horizontal scroll); the whole board scrolls vertically so pull-to-refresh works. On iPhone a
/// lane is nearly screen wide (the next one peeks out and the scroll snaps), on iPad and Mac the lanes share the width.
struct KanbanLanes: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .body) private var baseWidth: CGFloat = 304
    @ScaledMetric(relativeTo: .body) private var minLaneWidth: CGFloat = 240
    /// Empty lanes stay narrow so they do not claim a full card width next to wide, filled lanes.
    @ScaledMetric(relativeTo: .body) private var emptyLaneWidth: CGFloat = 168
    let cc: CommandCenterModel
    let showProject: Bool

    private func laneWidth(_ available: CGFloat, isEmpty: Bool) -> CGFloat {
        let inner = max(available - 2 * margin, 0)
        if isEmpty { return min(emptyLaneWidth, inner) }
        if sizeClass == .compact { return min(max(inner * 0.86, minLaneWidth), inner) }
        let n = max(cc.lanes.count, 1)
        return min(inner, max(baseWidth, min((inner - CGFloat(n) * Space.m) / CGFloat(n), 420)))
    }

    private var margin: CGFloat { sizeClass == .regular ? Space.pageRegular : Space.page }

    var body: some View {
        ScrollView(.vertical) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: Space.m) {
                    ForEach(cc.lanes) { lane in
                        LaneColumn(cc: cc, lane: lane, showProject: showProject)
                            .containerRelativeFrame(.horizontal, alignment: .top) { available, _ in laneWidth(available, isEmpty: lane.cards.isEmpty) }
                    }
                }
                .padding(.horizontal, margin).padding(.top, Space.xs).padding(.bottom, Space.xl)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .refreshable { await cc.refresh(app) }
    }
}

struct LaneColumn: View {
    let cc: CommandCenterModel
    let lane: CommandLaneColumn
    let showProject: Bool
    @ScaledMetric(relativeTo: .body) private var emptyHeight: CGFloat = 84

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Image(systemName: LanePresentation.symbol(lane.key)).foregroundStyle(LanePresentation.color(lane.key)).accessibilityHidden(true)
                LanePresentation.title(lane.key, fallback: lane.title).font(.sectionTitle).fixedSize(horizontal: false, vertical: true)
                CountBadge(count: lane.count, tint: lane.count > 0 ? LanePresentation.color(lane.key) : Color.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.xs).padding(.top, Space.xs)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if lane.cards.isEmpty {
                VStack(spacing: Space.xs) {
                    Image(systemName: "tray").font(.title3)
                    Text("cc.lane.empty").font(.footnote).multilineTextAlignment(.center)
                }
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, Space.s)
                .frame(maxWidth: .infinity, minHeight: emptyHeight)
                .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.hairline, style: StrokeStyle(lineWidth: 1, dash: [Space.xs, Space.xs])))
                .accessibilityElement(children: .combine)
            } else {
                LazyVStack(spacing: Space.m) {
                    ForEach(lane.cards) { CommandCardView(cc: cc, card: $0, showProject: showProject) }
                }
                if lane.truncated {
                    Text("cc.lane.truncated \(lane.count - lane.cards.count)").font(.caption).foregroundStyle(Color.textSecondary)
                }
            }
        }
        .padding(Space.s)
        .background(Color.canvasRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).strokeBorder(Color.hairline.opacity(0.6), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}

// MARK: List

struct CommandListSection: View {
    @Environment(AppModel.self) private var app
    let cc: CommandCenterModel
    let showProject: Bool

    var body: some View {
        List {
            ForEach(Array(cc.items.enumerated()), id: \.element.id) { index, card in
                VStack(alignment: .leading, spacing: Space.s) {
                    // One group header per run of equal lanes (not above every card).
                    if index == 0 || cc.items[index - 1].lane != card.lane {
                        HStack(spacing: Space.s) {
                            Image(systemName: LanePresentation.symbol(card.lane)).foregroundStyle(LanePresentation.color(card.lane)).accessibilityHidden(true)
                            LanePresentation.title(card.lane, fallback: card.lane).font(.sectionTitle).foregroundStyle(LanePresentation.color(card.lane))
                            CountBadge(count: cc.items.filter { $0.lane == card.lane }.count, tint: LanePresentation.color(card.lane))
                        }
                        .padding(.top, index == 0 ? 0 : Space.s)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                    }
                    CommandCardView(cc: cc, card: card, showProject: showProject)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.page, bottom: Space.xs, trailing: Space.page))
            }
            if let total = cc.data?.total, total > cc.items.count {
                Text("cc.list.more \(total - cc.items.count)").font(.footnote).foregroundStyle(Color.textSecondary).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .readableWidth()
        .overlay { if cc.items.isEmpty { EmptyState(symbol: "tray", title: "cc.empty", message: "cc.emptyHint") } }
        .refreshable { await cc.refresh(app) }
    }
}

// MARK: Updates and builds

struct UpdatesSection: View {
    @Environment(AppModel.self) private var app
    let cc: CommandCenterModel

    var body: some View {
        List {
            if !cc.builds.isEmpty {
                Section {
                    ForEach(cc.builds) { group in
                        VStack(alignment: .leading, spacing: Space.s) {
                            HStack(spacing: Space.s) {
                                Text(verbatim: group.label ?? group.buildID).font(.subheadline.weight(.semibold))
                                if let platform = group.platform { Text(verbatim: platform).font(.caption).foregroundStyle(Color.textSecondary) }
                                Spacer()
                                Text(verbatim: CommandFormat.relative(group.createdAt)).font(.caption).foregroundStyle(Color.textSecondary)
                            }
                            BuildStrip(builds: group.items, total: group.items.count)
                        }
                        
                    }
                } header: { Text("cc.builds.title") }
            }
            Section {
                ForEach(cc.updates) { update in
                    Button { openTask(update) } label: {
                        HStack(alignment: .top, spacing: Space.m) {
                            Image(systemName: CommandFormat.updateSymbol(update.kind)).foregroundStyle(Color.brand).scaledSquare(24, relativeTo: .subheadline).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                HStack(spacing: Space.xs) {
                                    CommandFormat.updateKind(update.kind).fontWeight(.semibold)
                                    Text(verbatim: "·").foregroundStyle(Color.textSecondary)
                                    Text(verbatim: update.taskTitle).lineLimit(1)
                                }
                                .font(.subheadline)
                                if let text = update.text, !text.isEmpty {
                                    MarkdownText(text).font(.footnote).foregroundStyle(Color.textSecondary).lineLimit(3)
                                }
                                HStack(spacing: Space.s) {
                                    Text(verbatim: update.projectName)
                                    if let who = update.actorName { Text(verbatim: who) }
                                    Text(verbatim: CommandFormat.relative(update.createdAt))
                                }
                                .font(.caption2).foregroundStyle(Color.textSecondary)
                            }
                        }
                        .tapTarget()
                    }
                    .buttonStyle(.plain)
                }
            } header: { Text("cc.updates.title") }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .readableWidth()
        .overlay { if cc.updates.isEmpty && cc.builds.isEmpty { EmptyState(symbol: "bell", title: "cc.updates.empty", message: "cc.updates.emptyHint") } }
        .refreshable { await cc.refresh(app) }
    }

    private func openTask(_ update: CommandUpdate) {
        let known = app.tasks.first { $0.id == update.taskID }
        app.path = [known ?? TodoTask(id: update.taskID, projectID: update.projectID, title: update.taskTitle)]
    }
}

// MARK: All open questions

struct QuestionsSection: View {
    @Environment(AppModel.self) private var app
    let cc: CommandCenterModel

    var body: some View {
        List {
            ForEach(cc.questions) { q in
                VStack(alignment: .leading, spacing: Space.s) {
                    if let project = q.projectName {
                        HStack(spacing: Space.xs) {
                            Text(verbatim: "#").foregroundStyle(Color.project(q.projectID))
                            Text(verbatim: project)
                        }
                        .font(.caption).foregroundStyle(Color.textSecondary)
                    }
                    QuestionAnswerView(prompt: q.prompt, options: q.options, asker: q.askerDisplay, blocking: q.blocking, askedAt: q.createdAt,
                        taskTitle: q.taskTitle, busy: cc.busy.contains(q.id)) { answer in
                        Task { await cc.answer(questionID: q.id, with: answer, app) }
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.page, bottom: Space.xs, trailing: Space.page))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .readableWidth()
        .overlay { if cc.questions.isEmpty { EmptyState(symbol: "checkmark.bubble", title: "cc.questions.empty", message: "cc.questions.emptyHint") } }
        .refreshable { await cc.refresh(app) }
    }
}

// MARK: Agent brief

/// Markdown briefing for the project's agents (goals, constraints, definition of done). Writing needs the manage role.
struct AgentBriefView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let projectName: String
    @State private var text = ""
    @State private var original = ""
    @State private var version = 0
    @State private var loaded = false
    @State private var saving = false
    @State private var errorKey: String?
    @State private var conflict = false

    private static let template = "# Goals\n\n# Constraints\n\n# Definition of done\n\n# Agent rules\n"

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("cc.brief.hint").font(.footnote).foregroundStyle(Color.textSecondary)
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(Space.s)
                    .background(Color.canvasRaised, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty && loaded {
                            Button("cc.brief.insertTemplate") { text = Self.template }
                                .buttonStyle(.bordered).padding(Space.m)
                        }
                    }
                HStack {
                    Text("cc.brief.count \(text.count)").font(.caption).foregroundStyle(text.count > 20000 ? Color.dueOverdue : Color.textSecondary).monospacedDigit()
                    Spacer()
                    if let errorKey { Text(LocalizedStringKey(errorKey)).font(.caption).foregroundStyle(Color.dueOverdue) }
                }
                if conflict {
                    Button("cc.brief.reload") { Task { await load() } }.buttonStyle(.bordered)
                }
            }
            .pageMargins().padding(.vertical, Space.l)
            .readableWidth()
            .background(Color.canvas)
            .navigationTitle(Text("cc.brief.title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") { Task { await save() } }
                        .disabled(!loaded || saving || text == original || text.count > 20000)
                }
            }
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 560)
        #endif
    }

    private func load() async {
        guard let client = app.client else { return }
        do {
            let brief = try await client.agentBrief(projectID: projectID)
            text = brief.text; original = brief.text; version = brief.version
            loaded = true; conflict = false; errorKey = nil
        } catch {
            errorKey = AppModel.key(for: error)
        }
    }

    private func save() async {
        guard let client = app.client else { return }
        saving = true; defer { saving = false }
        do {
            let brief = try await client.saveAgentBrief(projectID: projectID, text: text, version: version)
            Haptics.success()
            original = brief.text; version = brief.version
            dismiss()
        } catch APIError.versionConflict {
            conflict = true; errorKey = "cc.brief.conflict"
        } catch APIError.forbidden {
            errorKey = "cc.brief.forbidden"
        } catch {
            errorKey = AppModel.key(for: error)
        }
    }
}

// MARK: Previews

#Preview("Steuerzentrale, Light") {
    NavigationStack { CommandCenterView(projectID: nil) }.environment(AppModel())
}

#Preview("Steuerzentrale, Dark") {
    NavigationStack { CommandCenterView(projectID: nil) }.environment(AppModel()).preferredColorScheme(.dark)
}

#Preview("Steuerzentrale, accessibility5") {
    NavigationStack { CommandCenterView(projectID: nil) }.environment(AppModel()).dynamicTypeSize(.accessibility5)
}

#Preview("Lane leer, klein") {
    let json = #"{"key":"running","title":"Läuft","count":0,"truncated":false,"cards":[]}"#
    if let lane = try? JSONDecoder().decode(CommandLaneColumn.self, from: Data(json.utf8)) {
        LaneColumn(cc: CommandCenterModel(projectID: nil), lane: lane, showProject: true)
            .frame(width: 280).padding(Space.l).background(Color.canvas)
    }
}
