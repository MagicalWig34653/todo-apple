import SwiftUI
import TodoCore

/// "Jetzt" (layout A of the web page): one collapsible card per project with what runs, which sessions report, what waits
/// for the user, builds and the latest events. Projects with an open question or review come first and are never quiet;
/// quiet projects sit below a heading and start collapsed.
struct OverviewNowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model: OverviewNowModel

    init(model: OverviewNowModel? = nil) {
        #if DEBUG
        _model = State(initialValue: model ?? OverviewNowModel.debugStub() ?? OverviewNowModel())
        #else
        _model = State(initialValue: model ?? OverviewNowModel())
        #endif
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.l) {
                header
                content
            }
            .pageMargins().padding(.vertical, Space.l)
            .readableWidth()
            .frame(maxWidth: .infinity)
        }
        .background(Color.canvas)
        .refreshable { await model.refresh(app) }
        #if os(iOS)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        #else
        .navigationTitle("now.title")
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refresh(app) } } label: { Label("now.refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
                    .accessibilityIdentifier("now.refresh")
            }
        }
        .task { await model.refresh(app) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.refresh(app) } } }
        .accessibilityIdentifier("now.screen")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("now.title")
                    .font(typeSize.isAccessibilitySize ? Font.system(.title, design: .rounded).weight(.bold) : .screenTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if model.loading { ProgressView().controlSize(.small) }
            }
            Text("now.hint").font(.subheadline).foregroundStyle(Color.textSecondary)
            if let at = model.fetchedAt {
                Text("now.asOf \(at.formatted(date: .omitted, time: .shortened))").font(.footnote).foregroundStyle(Color.textSecondary)
            }
            if model.loadFailed, model.data != nil {
                Label("now.errorStale", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium)).foregroundStyle(Color.primary)
            }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if model.unsupported {
            EmptyState(symbol: "exclamationmark.triangle", title: "now.unsupported", message: "now.unsupportedHint")
                .accessibilityIdentifier("now.unsupported")
        } else if model.data == nil {
            if model.loadFailed {
                VStack(spacing: Space.m) {
                    EmptyState(symbol: "wifi.exclamationmark", title: "now.error")
                    Button("now.retry") { Task { await model.refresh(app) } }.buttonStyle(.borderedProminent).tapTarget()
                }
                .frame(maxWidth: .infinity)
            } else {
                ProgressView("now.loading").frame(maxWidth: .infinity).padding(.top, Space.xxl)
            }
        } else if model.isEmpty {
            EmptyState(symbol: "moon.zzz", title: "now.empty", message: "now.emptyHint", tint: .tileBlue)
                .accessibilityIdentifier("now.empty")
        } else {
            if let block = model.data?.now {
                NowBlockView(block: block, now: model.now, silentExpanded: Binding(get: { model.silentExpanded }, set: { model.silentExpanded = $0 }),
                             open: { open(taskID: $0, projectID: $1, title: $2) })
                if !model.groups.isEmpty {
                    Text("now.block.projects").font(.headline).padding(.top, Space.s).accessibilityAddTraits(.isHeader)
                }
            }
            projects(model.groups)
        }
    }

    @ViewBuilder private func projects(_ groups: OverviewGroups) -> some View {
        ForEach(groups.waiting) { card($0, .waiting) }
        ForEach(groups.active) { card($0, .active) }
        if !groups.quiet.isEmpty {
            Text("now.quiet \(groups.quiet.count)")
                .font(.subheadline).foregroundStyle(Color.textSecondary)
                .padding(.top, Space.s)
                .accessibilityAddTraits(.isHeader)
            ForEach(groups.quiet) { card($0, .quiet) }
        }
    }

    private func card(_ project: OverviewProject, _ category: OverviewNowModel.Category) -> some View {
        OverviewProjectCard(
            project: project, quiet: category == .quiet, now: model.now,
            isExpanded: Binding(get: { model.isExpanded(project.projectID, category) },
                                set: { model.setExpanded($0, project.projectID, category) }),
            open: { open(taskID: $0, in: project) })
    }

    /// Antworten / Ansehen: the existing task detail (sheet on iPhone, inspector on iPad and Mac).
    private func open(taskID: UUID, in project: OverviewProject) {
        open(taskID: taskID, projectID: project.projectID, title: project.title(of: taskID) ?? "")
    }

    private func open(taskID: UUID, projectID: UUID, title: String) {
        let known = app.tasks.first { $0.id == taskID }
        app.path = [known ?? TodoTask(id: taskID, projectID: projectID, title: title)]
    }
}

private extension OverviewProject {
    /// Best known title of a task from the project's own lists (placeholder until the detail loads the real task).
    func title(of taskID: UUID) -> String? {
        runningTasks.first { $0.taskID == taskID }?.title
            ?? (openQuestions + pendingReviews).first { $0.taskID == taskID }?.taskTitle
            ?? recentActivity.first { $0.taskID == taskID }?.taskTitle
    }
}

// MARK: Project card

struct OverviewProjectCard: View {
    let project: OverviewProject
    let quiet: Bool
    let now: Date
    @Binding var isExpanded: Bool
    let open: (UUID) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            OverviewProjectDetails(project: project, now: now, open: open)
                .padding(.top, Space.m)
        } label: {
            OverviewProjectHeader(project: project, quiet: quiet, now: now)
        }
        .padding(Space.m)
        .cardSurface()
        .accessibilityIdentifier("now.project")
    }
}

private struct OverviewProjectHeader: View {
    let project: OverviewProject
    let quiet: Bool
    let now: Date

    private var waiting: Int { project.openItemCount }
    private var nothingOpen: Bool { project.runningTasks.isEmpty && project.sessions.isEmpty && waiting == 0 && project.builds.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Circle().fill(Color.project(project.projectID)).scaledSquare(Space.s, relativeTo: .body).accessibilityHidden(true)
                Text(verbatim: project.projectName)
                    .font(quiet ? .headline.weight(.medium) : .headline)
                    .foregroundStyle(quiet ? Color.textSecondary : Color.primary)
                    .lineLimit(3)
                    .accessibilityAddTraits(.isHeader)
            }
            FlowLayout(spacing: Space.s) {
                if !project.runningTasks.isEmpty { StatBadge(text: Text("now.stat.running \(project.runningTasks.count)"), tint: .priority(1)) }
                if !project.sessions.isEmpty { StatBadge(text: Text("now.stat.sessions \(project.sessions.count)"), tint: .tileGreen) }
                if waiting > 0 { StatBadge(text: Text("now.stat.waiting \(waiting)"), tint: .priority(2), symbol: "hand.raised.fill") }
                if !project.builds.isEmpty { StatBadge(text: Text("now.stat.builds \(project.builds.count)"), tint: .textSecondary) }
                if nothingOpen { Text("now.nothingOpen").font(.subheadline).foregroundStyle(Color.textSecondary) }
                if let last = project.lastActivityAt {
                    Text("now.lastActivity \(CommandFormat.relative(last, now: now))").font(.subheadline).foregroundStyle(Color.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Count capsule: the number and its word carry the meaning, the tint is only decoration.
private struct StatBadge: View {
    let text: Text
    let tint: Color
    var symbol: String?
    var body: some View {
        HStack(spacing: Space.xs) {
            if let symbol { Image(systemName: symbol).font(.caption2).accessibilityHidden(true) }
            text.lineLimit(2)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.primary)
        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
        .background(tint.opacity(0.16), in: Capsule())
    }
}

// MARK: Details

private struct OverviewProjectDetails: View {
    let project: OverviewProject
    let now: Date
    let open: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            if !project.runningTasks.isEmpty {
                OverviewSection("now.section.running") {
                    ForEach(project.runningTasks) { RunningRow(task: $0, now: now, open: open) }
                }
            }
            if !project.sessions.isEmpty {
                OverviewSection("now.section.sessions") {
                    ForEach(project.sessions) { SessionRow(session: $0, now: now) }
                }
            }
            if !project.agentJobs.isEmpty {
                OverviewSection("now.section.jobs") {
                    ForEach(Array(project.agentJobs.enumerated()), id: \.offset) { JobRow(job: $0.element) }
                }
            }
            if project.hasOpenItems {
                OverviewSection("now.section.waiting") {
                    ForEach(project.openQuestions, id: \.listID) { OpenItemRow(item: $0, isQuestion: true, now: now, open: open) }
                    ForEach(project.pendingReviews, id: \.listID) { OpenItemRow(item: $0, isQuestion: false, now: now, open: open) }
                }
            }
            if !project.builds.isEmpty {
                OverviewSection("now.section.builds") {
                    ForEach(project.builds) { BuildRow(build: $0, now: now) }
                }
            }
            if !project.recentActivity.isEmpty {
                OverviewSection("now.section.events") {
                    ForEach(Array(project.recentActivity.enumerated()), id: \.offset) { EventRow(event: $0.element) }
                }
            }
        }
    }
}

private struct OverviewSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).font(.sectionTitle).foregroundStyle(Color.textSecondary).textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RunningRow: View {
    let task: OverviewRunningTask
    let now: Date
    let open: (UUID) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button { open(task.taskID) } label: {
            VStack(alignment: .leading, spacing: Space.xs) {
                AdaptiveStack(spacing: Space.s, verticalAlignment: .firstTextBaseline) {
                    Text(verbatim: task.title).font(.body.weight(.semibold)).lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                        .multilineTextAlignment(.leading)
                    if let worker = task.worker, !worker.isEmpty {
                        Text(verbatim: worker).font(.caption.weight(.medium)).foregroundStyle(Color.textSecondary)
                            .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                            .background(Color.hairline.opacity(0.5), in: Capsule())
                    }
                }
                if let percent = task.percent {
                    ProgressView(value: Double(percent), total: 100).tint(LanePresentation.color("running"))
                        .accessibilityLabel(Text("now.progress \(percent)"))
                }
                note
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tapTarget()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("now.running")
    }

    private var note: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            if let percent = task.percent { Text(verbatim: "\(percent) %").monospacedDigit() }
            if let text = task.lastProgress?.note, !text.isEmpty { Text(verbatim: "„\(text)“").lineLimit(typeSize.isAccessibilitySize ? nil : 3) }
            else { Text("now.noNote") }
            if let at = task.lastProgress?.at { Text(verbatim: "· " + CommandFormat.relative(at, now: now)) }
        }
        .font(.footnote).foregroundStyle(Color.textSecondary)
        .multilineTextAlignment(.leading)
    }
}

private struct SessionRow: View {
    let session: OverviewSession
    let now: Date

    var body: some View {
        let orphaned = session.isOrphaned(at: now)
        VStack(alignment: .leading, spacing: Space.xs) {
            AdaptiveStack(spacing: Space.s, verticalAlignment: .firstTextBaseline) {
                Text(verbatim: session.sessionName).font(.body.weight(.semibold)).lineLimit(2)
                // Text and symbol, not only colour (guideline: states never by colour alone).
                if orphaned {
                    Label("now.session.orphaned", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.dueOverdue)
                } else {
                    Label("now.session.active", systemImage: "circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.primary)
                        .symbolRenderingMode(.hierarchical)
                }
                if let at = session.updatedAt {
                    Text("now.heartbeat \(CommandFormat.relative(at, now: now))").font(.footnote).foregroundStyle(Color.textSecondary)
                }
            }
            if !session.activity.isEmpty {
                Text(verbatim: session.activity).font(.footnote).foregroundStyle(Color.textSecondary).lineLimit(3)
            }
            if orphaned { Text("now.session.orphanedHint").font(.footnote).foregroundStyle(Color.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(orphaned ? "now.session.orphaned" : "now.session")
    }
}

private struct JobRow: View {
    let job: OverviewJob
    var body: some View {
        AdaptiveStack(spacing: Space.s, verticalAlignment: .firstTextBaseline) {
            if let state = job.state { CommandFormat.jobState(state).font(.subheadline.weight(.semibold)) }
            if let progress = job.progress, !progress.isEmpty {
                Text(verbatim: progress).font(.footnote).foregroundStyle(Color.textSecondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct OpenItemRow: View {
    let item: OverviewOpenItem
    let isQuestion: Bool
    let now: Date
    let open: (UUID) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xs) {
                (Text(isQuestion ? "now.question" : "now.review").fontWeight(.bold) + Text(verbatim: ": ") + Text(verbatim: item.text))
                    .font(.subheadline).lineLimit(typeSize.isAccessibilitySize ? nil : 4)
                HStack(spacing: Space.xs) {
                    if !item.taskTitle.isEmpty { Text(verbatim: item.taskTitle).lineLimit(2) }
                    if let at = item.createdAt { Text(verbatim: "· " + CommandFormat.relative(at, now: now)) }
                }
                .font(.footnote).foregroundStyle(Color.textSecondary)
            }
            // Same destination for both: the task detail holds the answer field and the review decision.
            if isQuestion {
                Button { open(item.taskID) } label: { Text("now.answer").frame(minHeight: TapTarget.minimum - Space.l) }
                    .buttonStyle(.borderedProminent).tint(.brand)
                    .accessibilityIdentifier("now.answer")
            } else {
                Button { open(item.taskID) } label: { Text("now.look").frame(minHeight: TapTarget.minimum - Space.l) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("now.look")
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.priority(2).opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
    }
}

private struct BuildRow: View {
    let build: OverviewBuild
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            AdaptiveStack(spacing: Space.s, verticalAlignment: .firstTextBaseline) {
                Text(verbatim: build.label ?? String(localized: "now.build.untitled")).font(.body.weight(.semibold)).lineLimit(2)
                BuildStatusBadge(status: build.status)
            }
            AdaptiveStack(spacing: Space.s, verticalAlignment: .firstTextBaseline) {
                if let platform = build.platform { Text(verbatim: platform).font(.footnote).foregroundStyle(Color.textSecondary) }
                if let commit = build.commitShort { Text(verbatim: commit).font(.footnote.monospaced()).foregroundStyle(Color.textSecondary).textSelection(.enabled) }
                if let at = build.createdAt { Text(verbatim: CommandFormat.relative(at, now: now)).font(.footnote).foregroundStyle(Color.textSecondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct EventRow: View {
    let event: OverviewEvent

    private var label: String {
        let key = "now.event.\(event.kind)"
        let found = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return found == key ? String(localized: "now.event.unknown \(event.kind)") : found
    }

    var body: some View {
        AdaptiveStack(spacing: Space.s, verticalAlignment: .firstTextBaseline) {
            if let at = event.createdAt {
                Text(at.formatted(date: .omitted, time: .shortened)).font(.footnote.monospacedDigit()).foregroundStyle(Color.textSecondary)
            }
            Text(verbatim: event.taskTitle.isEmpty ? label : "\(label): \(event.taskTitle)").font(.footnote).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Previews and debug sample

#if DEBUG
enum OverviewNowSample {
    static let now = Date(timeIntervalSince1970: 1_795_000_000)
    private static func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
    private static let t1 = UUID(), t2 = UUID(), t3 = UUID(), t4 = UUID()
    private static let pTodolino = UUID(), pApple = UUID()

    /// One project with only builds in the three states (debug screenshots: `TODO_DEBUG_NOW_PREVIEW=builds`).
    static let buildsOnly = OverviewNow(serverTime: now, projects: [
        OverviewProject(projectID: UUID(), projectName: "Todolino", lastActivityAt: ago(60), builds: [
            OverviewBuild(taskID: t1, buildID: "d955b88c0ffee", label: "CI main", platform: "web", createdAt: ago(540), commit: "d955b88c0ffee", status: .failed),
            OverviewBuild(taskID: t1, buildID: "214", label: "iOS Archiv", platform: "ios", createdAt: ago(300), commit: "a1b2c3d4e5f6", status: .building),
            OverviewBuild(taskID: t1, buildID: "215", label: "macOS", platform: "macos", createdAt: ago(900), commit: "0f1e2d3c4b5a", status: .succeeded),
            OverviewBuild(taskID: t1, buildID: "216", label: "Ohne Status", platform: "ios", createdAt: ago(1200))])
    ])

    /// Block "Jetzt": two running (card and session), a question and a review waiting, two done, three silent.
    static let block = NowBlock(
        counts: NowCounts(running: 2, waiting: 2, recentlyDone: 2, silent: 3),
        running: [
            NowActive(kind: .task, projectID: pTodolino, projectName: "Todolino", taskID: t1, title: "Passkey-Anmeldung auf Safari absichern",
                      text: "Fallback für Conditional UI geschrieben, Tests laufen", worker: "Claude Sonnet", since: ago(5400), lastSignAt: ago(240),
                      ageSeconds: 240, dueAt: now.addingTimeInterval(3 * 3600), percent: 60),
            NowActive(kind: .session, projectID: pApple, projectName: "Todolino Apple", title: "apple-jetzt", text: "Baut die Ansicht Jetzt mit dem Block",
                      lastSignAt: ago(40), ageSeconds: 40)],
        waiting: [
            NowWaiting(kind: .question, id: UUID(), projectID: pTodolino, projectName: "Todolino", taskID: t3, taskTitle: "Runner-Bindings",
                       text: "Soll der Runner nach Eigentumswechsel pausieren oder weiterlaufen?", createdAt: ago(720)),
            NowWaiting(kind: .review, id: UUID(), projectID: pTodolino, projectName: "Todolino", taskID: t4, taskTitle: "Kalender Stufe A",
                       text: "Schedule-API fertig", createdAt: ago(3600))],
        recentlyDone: [
            NowDone(taskID: UUID(), title: "Label umbenennen und löschen", projectID: pApple, projectName: "Todolino Apple", doneAt: ago(1800)),
            NowDone(taskID: UUID(), title: "Benachrichtigungen bündeln", projectID: pApple, projectName: "Todolino Apple", doneAt: ago(14_400))],
        silent: [
            NowActive(kind: .task, projectID: pTodolino, projectName: "Todolino", taskID: UUID(), title: "Migration 0092 prüfen", text: "Skript angelegt",
                      worker: "Claude Sonnet", since: ago(90_000), lastSignAt: ago(7200), ageSeconds: 7200, dueAt: ago(3600)),
            NowActive(kind: .session, projectID: pTodolino, projectName: "Todolino", title: "backend-oauth", text: "Migration 0092 prüfen", lastSignAt: ago(2820), ageSeconds: 2820),
            NowActive(kind: .task, projectID: pApple, projectName: "Todolino Apple", taskID: UUID(), title: "Widget „Heute“ für iOS", text: "", lastSignAt: ago(20_000), ageSeconds: 20_000)])

    static let data = OverviewNow(serverTime: now, projects: [
        OverviewProject(
            projectID: UUID(), projectName: "Todolino", lastActivityAt: ago(60),
            runningTasks: [
                OverviewRunningTask(taskID: t1, title: "Passkey-Anmeldung auf Safari absichern", worker: "Claude Sonnet",
                                    lastProgress: OverviewProgress(note: "Fallback für Conditional UI geschrieben, Tests laufen", at: ago(240)), ageSeconds: 5400, percent: 60),
                OverviewRunningTask(taskID: t2, title: "Übersicht Jetzt: Entwürfe zeichnen", worker: "Claude Sonnet",
                                    lastProgress: OverviewProgress(note: "Tokens gelesen", at: ago(60)), ageSeconds: 900)],
            sessions: [
                OverviewSession(sessionName: "web-passkey", activity: "Führt vitest für auth.test.ts aus", updatedAt: ago(40), ageSeconds: 40, orphaned: false),
                OverviewSession(sessionName: "backend-oauth", activity: "Migration 0092 prüfen", updatedAt: ago(2820), ageSeconds: 2820, orphaned: true)],
            builds: [OverviewBuild(taskID: t1, buildID: "d955b88c0ffee", label: "CI main", platform: "web", createdAt: ago(540), commit: "d955b88c0ffee", status: .failed),
                     OverviewBuild(taskID: t1, buildID: "d955b88c0aaaa", label: "iOS Archiv", platform: "ios", createdAt: ago(300), commit: "a1b2c3d4e5f6", status: .building),
                     OverviewBuild(taskID: t1, buildID: "d955b88c0bbbb", label: "macOS", platform: "macos", createdAt: ago(900), commit: "0f1e2d3c4b5a", status: .succeeded)],
            openQuestions: [OverviewOpenItem(taskID: t3, taskTitle: "Runner-Bindings", text: "Soll der Runner nach Eigentumswechsel pausieren oder weiterlaufen?", createdAt: ago(720))],
            pendingReviews: [OverviewOpenItem(taskID: t4, taskTitle: "Kalender Stufe A", text: "Schedule-API fertig", createdAt: ago(3600))],
            recentActivity: [
                OverviewEvent(taskID: t1, taskTitle: "Passkey-Anmeldung absichern", kind: "progress.posted", createdAt: ago(120)),
                OverviewEvent(taskID: t1, taskTitle: "Passkey-Anmeldung absichern", kind: "plan.approved", createdAt: ago(300)),
                OverviewEvent(taskID: t1, taskTitle: "Passkey-Anmeldung absichern", kind: "pipeline.step", createdAt: ago(420)),
                OverviewEvent(taskID: t3, taskTitle: "Runner-Bindings", kind: "plan.written", createdAt: ago(600)),
                OverviewEvent(taskID: t3, taskTitle: "Runner-Bindings", kind: "question.asked", createdAt: ago(720)),
                OverviewEvent(taskID: t4, taskTitle: "Kalender Stufe A", kind: "zukunft.neu", createdAt: ago(3600))]),
        OverviewProject(
            projectID: UUID(), projectName: "Todolino Apple", lastActivityAt: ago(1080),
            runningTasks: [OverviewRunningTask(taskID: UUID(), title: "Widget „Heute“ für iOS", worker: "Claude Sonnet",
                                               lastProgress: OverviewProgress(note: "Vorschau-Screenshots erzeugt", at: ago(1080)), percent: 85)],
            builds: [OverviewBuild(taskID: t1, buildID: "214", label: "iOS Build 214", platform: "ios", createdAt: ago(3600))]),
        OverviewProject(projectID: UUID(), projectName: "Formular-Backend", lastActivityAt: ago(40_000),
                        pendingReviews: [OverviewOpenItem(taskID: UUID(), taskTitle: "Rate-Limit je Mandant", text: "Rate-Limit fertig", createdAt: ago(40_000))]),
        OverviewProject(projectID: UUID(), projectName: "Kubus Website", lastActivityAt: ago(100_000)),
        OverviewProject(projectID: UUID(), projectName: "Privat", lastActivityAt: ago(300_000))
    ], now: block)
}

struct OverviewNowPreviewHost: View {
    var data: OverviewNow = OverviewNowSample.data
    var body: some View {
        NavigationStack { OverviewNowView(model: OverviewNowModel(stub: data, now: OverviewNowSample.now)) }
            .environment(AppModel())
    }
}

#Preview("Jetzt light") { OverviewNowPreviewHost().preferredColorScheme(.light) }
#Preview("Jetzt dark") { OverviewNowPreviewHost().preferredColorScheme(.dark) }
#Preview("Jetzt accessibility5") { OverviewNowPreviewHost().dynamicTypeSize(.accessibility5) }
#Preview("Jetzt leer") { OverviewNowPreviewHost(data: OverviewNow(serverTime: OverviewNowSample.now)) }
#Preview("Jetzt klein") { OverviewNowPreviewHost().frame(width: 320, height: 568) }
#endif
