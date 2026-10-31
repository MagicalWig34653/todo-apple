import SwiftUI
import TodoCore

/// "Steuerzentrale": kanban (default) or list of agent work for the whole account or one project, plus updates and
/// all open questions. Refetches on appear, on foreground and on pull-to-refresh.
struct CommandCenterView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("cc.title").font(.largeTitle.bold())
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
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 10)
    }

    private var summaryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CommandLane.allCases, id: \.self) { lane in
                    chip(lane.rawValue, cc.summary.count(for: lane))
                }
                if cc.summary.activeAgents > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                        Text("cc.summary.agents \(cc.summary.activeAgents)")
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.blue)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.blue.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    private func chip(_ key: String, _ count: Int) -> some View {
        let color = LanePresentation.color(key)
        return HStack(spacing: 4) {
            Image(systemName: LanePresentation.symbol(key))
            LanePresentation.title(key, fallback: key)
            Text(verbatim: String(count)).monospacedDigit().fontWeight(.bold)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(count > 0 ? color : Color.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background((count > 0 ? color : Color.secondary).opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    // MARK: Overview

    @ViewBuilder private var overview: some View {
        if cc.data == nil {
            if cc.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
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

/// Lanes side by side (horizontal scroll); the whole board scrolls vertically so pull-to-refresh works.
struct KanbanLanes: View {
    @Environment(AppModel.self) private var app
    let cc: CommandCenterModel
    let showProject: Bool

    var body: some View {
        ScrollView(.vertical) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cc.lanes) { lane in
                        LaneColumn(cc: cc, lane: lane, showProject: showProject)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 24)
            }
        }
        .refreshable { await cc.refresh(app) }
    }
}

struct LaneColumn: View {
    let cc: CommandCenterModel
    let lane: CommandLaneColumn
    let showProject: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: LanePresentation.symbol(lane.key)).foregroundStyle(LanePresentation.color(lane.key))
                LanePresentation.title(lane.key, fallback: lane.title).font(.subheadline.weight(.bold))
                Text(verbatim: String(lane.count)).font(.subheadline).foregroundStyle(Color.textSecondary).monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 4)
            if lane.cards.isEmpty {
                Text("cc.lane.empty").font(.footnote).foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(lane.cards) { CommandCardView(cc: cc, card: $0, showProject: showProject) }
                }
                if lane.truncated {
                    Text("cc.lane.truncated \(lane.count - lane.cards.count)").font(.caption).foregroundStyle(Color.textSecondary)
                }
            }
        }
        .frame(width: 304, alignment: .top)
    }
}

// MARK: List

struct CommandListSection: View {
    @Environment(AppModel.self) private var app
    let cc: CommandCenterModel
    let showProject: Bool

    var body: some View {
        List {
            ForEach(cc.items) { card in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: LanePresentation.symbol(card.lane)).foregroundStyle(LanePresentation.color(card.lane))
                        LanePresentation.title(card.lane, fallback: card.lane).font(.caption.weight(.semibold)).foregroundStyle(LanePresentation.color(card.lane))
                    }
                    CommandCardView(cc: cc, card: card, showProject: showProject)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
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
                                    Text(verbatim: "·").foregroundStyle(.tertiary)
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
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
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
                    .background(Color.canvasRaised, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty && loaded {
                            Button("cc.brief.insertTemplate") { text = Self.template }
                                .buttonStyle(.bordered).padding(14)
                        }
                    }
                HStack {
                    Text("cc.brief.count \(text.count)").font(.caption).foregroundStyle(text.count > 20000 ? .red : .secondary).monospacedDigit()
                    Spacer()
                    if let errorKey { Text(LocalizedStringKey(errorKey)).font(.caption).foregroundStyle(.red) }
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
