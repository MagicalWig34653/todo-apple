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
            PushPrimerCard()
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
        .background(Color.canvas)
        .navigationTitle("cc.title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .task { await cc.refresh(app) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await cc.refresh(app) } } }
        .onChange(of: cc.mode) { _, _ in Task { await cc.refreshIfModeChanged(app) } }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("cc.title").font(typeSize.isAccessibilitySize ? Font.system(.title, design: .rounded).weight(.bold) : .screenTitle).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    if let project {
                        Button { app.selectedProjectID = project.id } label: {
                            HStack(spacing: 4) {
                                Text(verbatim: "#").foregroundStyle(Color.project(project.id))
                                Text(verbatim: project.name)
                                Image(systemName: "chevron.right").font(.caption2)
                            }
                            .font(.subheadline).foregroundStyle(Color.textSecondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("cc.scope.account").font(.subheadline).foregroundStyle(Color.textSecondary)
                    }
                }
                Spacer()
                if cc.loading { ProgressView().controlSize(.small) }
            }
            summaryStrip
            Picker("cc.section", selection: $cc.section) {
                Text("cc.section.overview").tag(CommandCenterModel.Section.overview)
                Text("cc.section.updates").tag(CommandCenterModel.Section.updates)
                Text("cc.section.questions \(cc.summary.openQuestions)").tag(CommandCenterModel.Section.questions)
            }
            .pickerStyle(.segmented).labelsHidden()
        }
        .padding(.horizontal, Space.l + 4).padding(.top, Space.s).padding(.bottom, Space.m)
    }

    @ViewBuilder private var summaryStrip: some View {
        if typeSize.isAccessibilitySize {
            // Accessibility sizes: wrap into a column instead of a clipped horizontal strip.
            VStack(alignment: .leading, spacing: 8) { summaryChips }
        } else {
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { summaryChips } }
        }
    }

    @ViewBuilder private var summaryChips: some View {
        ForEach(CommandLane.allCases, id: \.self) { lane in
            chip(lane.rawValue, cc.summary.count(for: lane))
        }
        if cc.summary.activeAgents > 0 {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text("cc.summary.agents \(cc.summary.activeAgents)")
            }
            .font(.caption.weight(.medium)).foregroundStyle(Color.priority(1))
            .padding(.horizontal, Space.m).padding(.vertical, 6)
            .background(Color.priority(1).opacity(0.10), in: Capsule())
            .accessibilityElement(children: .combine)
        }
    }

    private func chip(_ key: String, _ count: Int) -> some View {
        let color = LanePresentation.color(key)
        return HStack(spacing: 4) {
            Image(systemName: LanePresentation.symbol(key))
            LanePresentation.title(key, fallback: key).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            Text(verbatim: String(count)).monospacedDigit().fontWeight(.bold)
        }
        .fixedSize(horizontal: false, vertical: true)
        .font(.caption.weight(.medium))
        .foregroundStyle(count > 0 ? color : Color.textSecondary)
        .padding(.horizontal, Space.m).padding(.vertical, 6)
        .background((count > 0 ? color : Color.textSecondary).opacity(0.10), in: Capsule())
        .accessibilityElement(children: .combine)
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
            Picker("cc.mode", selection: $cc.mode) {
                Label("cc.mode.kanban", systemImage: "rectangle.split.3x1").tag(CommandCenterModel.Mode.kanban)
                Label("cc.mode.list", systemImage: "list.bullet").tag(CommandCenterModel.Mode.list)
            }
            .pickerStyle(.segmented)
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
    let cc: CommandCenterModel
    let showProject: Bool

    private func laneWidth(_ available: CGFloat) -> CGFloat {
        let inner = max(available - 2 * Space.l, 240)
        if sizeClass == .compact { return min(max(inner * 0.86, 240), inner) }
        let n = max(cc.lanes.count, 1)
        return min(inner, max(baseWidth, min((inner - CGFloat(n) * Space.m) / CGFloat(n), 420)))
    }

    var body: some View {
        GeometryReader { geo in
            let width = laneWidth(geo.size.width)
            ScrollView(.vertical) {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: Space.m) {
                        ForEach(cc.lanes) { lane in
                            LaneColumn(cc: cc, lane: lane, showProject: showProject, width: width)
                        }
                    }
                    .padding(.horizontal, Space.l).padding(.top, Space.xs).padding(.bottom, Space.xl)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
            }
            .refreshable { await cc.refresh(app) }
        }
    }
}

struct LaneColumn: View {
    let cc: CommandCenterModel
    let lane: CommandLaneColumn
    let showProject: Bool
    var width: CGFloat = 304

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
                .frame(maxWidth: .infinity, minHeight: 84)
                .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
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
        .frame(width: width, alignment: .top)
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
                .listRowInsets(EdgeInsets(top: Space.xs + 2, leading: Space.l, bottom: Space.xs + 2, trailing: Space.l))
            }
            if let total = cc.data?.total, total > cc.items.count {
                Text("cc.list.more \(total - cc.items.count)").font(.footnote).foregroundStyle(Color.textSecondary).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(verbatim: group.label ?? group.buildID).font(.subheadline.weight(.semibold))
                                if let platform = group.platform { Text(verbatim: platform).font(.caption).foregroundStyle(Color.textSecondary) }
                                Spacer()
                                Text(verbatim: CommandFormat.relative(group.createdAt)).font(.caption).foregroundStyle(Color.textSecondary)
                            }
                            BuildStrip(builds: group.items, total: group.items.count)
                        }
                        .padding(.vertical, 4)
                    }
                } header: { Text("cc.builds.title") }
            }
            Section {
                ForEach(cc.updates) { update in
                    Button { openTask(update) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: CommandFormat.updateSymbol(update.kind)).foregroundStyle(Color.brand).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    CommandFormat.updateKind(update.kind).fontWeight(.semibold)
                                    Text(verbatim: "·").foregroundStyle(Color.textSecondary)
                                    Text(verbatim: update.taskTitle).lineLimit(1)
                                }
                                .font(.subheadline)
                                if let text = update.text, !text.isEmpty {
                                    Text(verbatim: text).font(.footnote).foregroundStyle(Color.textSecondary).lineLimit(3)
                                }
                                HStack(spacing: 6) {
                                    Text(verbatim: update.projectName)
                                    if let who = update.actorName { Text(verbatim: who) }
                                    Text(verbatim: CommandFormat.relative(update.createdAt))
                                }
                                .font(.caption2).foregroundStyle(Color.textSecondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: { Text("cc.updates.title") }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
                VStack(alignment: .leading, spacing: 6) {
                    if let project = q.projectName {
                        HStack(spacing: 4) {
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
                .listRowInsets(EdgeInsets(top: Space.xs + 2, leading: Space.l, bottom: Space.xs + 2, trailing: Space.l))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
            VStack(alignment: .leading, spacing: 8) {
                Text("cc.brief.hint").font(.footnote).foregroundStyle(Color.textSecondary)
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.canvasRaised, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty && loaded {
                            Button("cc.brief.insertTemplate") { text = Self.template }
                                .buttonStyle(.bordered).padding(14)
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
            .padding(16)
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
        .frame(minWidth: 520, minHeight: 480)
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
