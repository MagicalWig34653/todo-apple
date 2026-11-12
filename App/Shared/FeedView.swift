import SwiftUI
import TodoCore

/// First tab: "Für dich". Cards in the app's design system, no list chrome. With `showsAgentOverview` (iPhone tab,
/// navigation variant A) it starts with the agent overview (Läuft, Fragen, Reviews; one tap to the Steuerzentrale),
/// then what needs you, then today's tasks, then the news.
struct FeedView: View {
    @Environment(AppModel.self) private var app
    @Environment(TaskMeta.self) private var meta
    @Environment(\.scenePhase) private var scenePhase
    var showsAgentOverview = true
    /// iPhone tab only; on iPad and Mac the sidebar carries the Lage-Ampel.
    var showsSystemStatus = false
    @State private var model = FeedModel()
    @State private var shown: FeedImage?

    /// Today's rows shown inline; the rest is one tap away in "Planen".
    private static let todayLimit = 5

    /// DEBUG only: `TODO_DEBUG_FEED_POSTS=1` hides the needs-you section so screenshots can reach the posts (no touch input in the simulator).
    private static var debugPostsOnly: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["TODO_DEBUG_FEED_POSTS"] == "1"
        #else
        false
        #endif
    }

    /// With the today section below, due and overdue items would show twice; agent items (question, review, blocked) stay.
    private var needsYouItems: [FeedNeedsYou] {
        guard showsAgentOverview else { return model.state.needsYou }
        return model.state.needsYou.filter { $0.kind != "due" && $0.kind != "overdue" }
    }

    private var todayTasks: [TodoTask] {
        let overdue = meta.overdue.map(\.task)
        let today = app.today.sorted { ($0.planning.dueAt ?? .distantFuture) < ($1.planning.dueAt ?? .distantFuture) }.map(\.task)
        return (overdue + today).filter { !$0.isDone }
    }

    var body: some View {
        let today = showsAgentOverview ? todayTasks : []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.m) {
                if showsSystemStatus { SystemStatusBar() }
                if showsAgentOverview { AgentOverviewCard() }
                if model.unsupported {
                    EmptyState(symbol: "icloud.slash", title: "feed.unsupported", message: "feed.unsupportedHint").padding(.top, Space.xxl)
                } else if !model.state.loaded {
                    if model.failed { EmptyState(symbol: "wifi.exclamationmark", title: "feed.failed", message: "feed.failedHint").padding(.top, Space.xxl) }
                    else { SkeletonRows(count: 5) }
                } else if model.state.isEmpty && today.isEmpty && model.confirmationCards.isEmpty {
                    EmptyState(symbol: "sparkles", title: "feed.empty", message: "feed.emptyHint").padding(.top, Space.xxl)
                } else {
                    if !model.confirmationCards.isEmpty, !Self.debugPostsOnly { confirmations }
                    if !needsYouItems.isEmpty, !Self.debugPostsOnly { needsYou }
                    if !today.isEmpty { todaySection(today) }
                    if !model.state.posts.isEmpty { posts }
                }
            }
            .pageMargins().padding(.top, Space.m)
            // Extra room below the last card: the floating "+" must never sit on the card's buttons at the end of the scroll.
            .padding(.bottom, Space.xl + Space.m)
            .readableWidth()
        }
        .background(Color.canvas)
        // Start tab on iPhone: capture from here too, like the PWA's global "+" (it was the only main tab without it).
        .quickAdd()
        .navigationTitle("view.feed")
        .refreshable { await reload() }
        .task { await reload() }
        .task { if showsSystemStatus { await app.systemStatus.poll(app) } }
        .onChange(of: scenePhase) { _, phase in if phase == .active, showsAgentOverview { Task { await app.refreshCommandSummary() } } }
        .sheet(item: $shown) { image in
            NavigationStack {
                RemoteImage(attachmentID: image.attachmentID, contentMode: .fit).padding(Space.l)
                    .navigationTitle(Text(verbatim: image.label ?? image.filename))
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("done") { shown = nil } } }
            }
            #if os(macOS)
            .frame(minWidth: 420, idealWidth: 520, minHeight: 520, idealHeight: 640)
            #endif
        }
        .alert(LocalizedStringKey(model.errorKey ?? ""), isPresented: Binding(get: { model.errorKey != nil }, set: { if !$0 { model.errorKey = nil } })) {
            Button("ok") {}
        }
    }

    private func reload() async {
        guard showsAgentOverview else { await model.load(app); return }
        async let feed: Void = model.load(app)
        async let summary: Void = app.refreshCommandSummary()
        async let agenda: Void = app.reloadAgenda()
        _ = await (feed, summary, agenda)
    }

    private func todaySection(_ tasks: [TodoTask]) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("view.today").font(Font.sectionTitle).foregroundStyle(Color.textSecondary).accessibilityAddTraits(.isHeader)
                CountBadge(count: tasks.count)
                Spacer(minLength: Space.s)
                Button { app.selection = .today } label: {
                    HStack(spacing: Space.xxs) {
                        Text("forYou.today.all")
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).accessibilityHidden(true)
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
                    .tapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("forYou.today.all")
            }
            .padding(.top, Space.s)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(tasks.prefix(Self.todayLimit).enumerated()), id: \.element.id) { index, task in
                    if index > 0 { Divider().padding(.leading, TapTarget.minimum) }
                    TaskRow(task: task).padding(.vertical, Space.xxs).padding(.trailing, Space.s)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    /// Agents asking to do something large or irreversible (ADR 0026); first, because nothing happens until decided.
    private var confirmations: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("confirm.section").font(Font.sectionTitle).foregroundStyle(Color.textSecondary).accessibilityAddTraits(.isHeader)
            ForEach(model.confirmationCards, id: \.item.id) { card in
                ConfirmationCard(item: card.item, outcome: card.result, busy: model.deciding.contains(card.item.id)) { confirm in
                    Task { await model.decide(card.item, confirm: confirm, app) }
                }
            }
        }
    }

    private var needsYou: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text("feed.needsYou").font(Font.sectionTitle).foregroundStyle(Color.textSecondary).accessibilityAddTraits(.isHeader)
                // With the agent overview the counters above carry the totals; the server's remainder may be only due items.
                if !showsAgentOverview, model.state.needsYouTotal > model.state.needsYou.count {
                    Text("feed.needsYou.more \(model.state.needsYouTotal - model.state.needsYou.count)").font(.caption).foregroundStyle(Color.textSecondary)
                }
            }
            ForEach(needsYouItems) { item in
                NeedsYouCard(item: item, busy: model.busy.contains(item.id)) { action, input in
                    Task { await model.perform(item, action, input: input, app) }
                } open: { openTask(item.taskID, item.projectID, item.taskTitle) }
            }
        }
    }

    private var posts: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("feed.posts").font(Font.sectionTitle).foregroundStyle(Color.textSecondary).accessibilityAddTraits(.isHeader).padding(.top, Space.s)
            ForEach(model.state.posts) { post in
                PostCard(post: post, showImage: { shown = $0 }) { openTask(post.taskID, post.projectID, post.taskTitle) }
                    .onAppear { if post.id == model.state.posts.last?.id { Task { await model.loadMore(app) } } }
            }
            if model.loadingMore { ProgressView().frame(maxWidth: .infinity) }
        }
    }

    private func openTask(_ id: UUID, _ projectID: UUID, _ title: String) {
        app.path = [app.tasks.first { $0.id == id } ?? TodoTask(id: id, projectID: projectID, title: title)]
    }
}

/// Top of "Für dich": what the agents are doing. The header with the three counters opens the Steuerzentrale
/// (one tap from the start tab); below it up to three running cards with progress, each opening its task.
struct AgentOverviewCard: View {
    @Environment(AppModel.self) private var app

    private var summary: CommandSummary { app.commandSummary ?? CommandSummary() }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Button { app.selection = .commandCenter } label: {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Text("forYou.agents").font(Font.sectionTitle).foregroundStyle(Color.textSecondary)
                        Spacer(minLength: Space.s)
                        HStack(spacing: Space.xxs) {
                            Text("forYou.openCommandCenter")
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
                    }
                    AdaptiveStack(spacing: Space.s) {
                        stat("running", count: summary.running, title: "cc.lane.running")
                        stat("question", count: summary.openQuestions, title: "forYou.questions")
                        stat("review", count: summary.pendingReviews, title: "forYou.reviews")
                    }
                }
                .contentShape(Rectangle())
                .tapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("forYou.openCommandCenter"))
            .accessibilityValue(Text("forYou.a11y.summary \(summary.running) \(summary.openQuestions) \(summary.pendingReviews)"))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("forYou.commandCenter")
            if !app.runningCards.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(app.runningCards.enumerated()), id: \.element.id) { index, card in
                        if index > 0 { Divider() }
                        RunningCardRow(card: card)
                    }
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func stat(_ lane: String, count: Int, title: LocalizedStringKey) -> some View {
        let color = count > 0 ? LanePresentation.color(lane) : Color.textSecondary
        // Count above the label: three tiles fit the iPhone width without truncating "Reviews".
        return VStack(alignment: .leading, spacing: Space.xxs) {
            Text(verbatim: String(count)).font(.title2.weight(.bold)).monospacedDigit()
            HStack(spacing: Space.xs) {
                Image(systemName: LanePresentation.symbol(lane)).font(.caption2).accessibilityHidden(true)
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
    }
}

/// One card of the "Läuft" lane: title, project and agent, progress, latest note.
private struct RunningCardRow: View {
    @Environment(AppModel.self) private var app
    let card: CommandCard

    private var subtitle: String {
        [card.project.name, card.agent?.claimedLabel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        Button {
            app.path = [app.tasks.first { $0.id == card.task.id } ?? TodoTask(id: card.task.id, projectID: card.project.id, title: card.task.title)]
        } label: {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(verbatim: card.task.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: Space.s)
                    Text(verbatim: "\(card.progress.percent) %").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(Color.textSecondary)
                }
                ProgressView(value: Double(card.progress.percent), total: 100).tint(LanePresentation.color("running")).accessibilityHidden(true)
                if let note = card.latestUpdate?.text, !note.isEmpty {
                    MarkdownText(note).font(.footnote).foregroundStyle(Color.textSecondary).lineLimit(2).multilineTextAlignment(.leading)
                }
                if !subtitle.isEmpty {
                    Text(verbatim: subtitle).font(.caption).foregroundStyle(Color.textSecondary).lineLimit(1)
                }
            }
            .padding(.vertical, Space.s)
            .contentShape(Rectangle())
            .tapTarget()
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("feed.openTask"))
    }
}

/// The leading action of a card is filled (brand with on-brand text); the others stay quiet and neutral.
private struct ActionStyle: ViewModifier {
    let primary: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if primary {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large).tint(Color.brand)
                .foregroundStyle(Color.onBrand)
        } else {
            content.buttonStyle(AnswerChipStyle())
        }
    }
}

private struct NeedsYouCard: View {
    let item: FeedNeedsYou
    let busy: Bool
    let act: (FeedAction, String?) -> Void
    let open: () -> Void
    @State private var text = ""
    @State private var input: FeedAction?

    /// Questions and reviews are written by agents in Markdown; task titles stay verbatim.
    private var titleText: Text {
        item.kind == "question" || item.kind == "review" ? Text(MarkdownFormat.attributed(item.title)) : Text(verbatim: item.title)
    }

    private var symbol: String {
        switch item.kind {
        case "question": "questionmark.bubble.fill"
        case "review": "checkmark.seal.fill"
        case "blocked": "exclamationmark.octagon.fill"
        default: "clock.badge.exclamationmark.fill"
        }
    }
    private var tint: Color { item.kind == "overdue" || item.kind == "blocked" ? .dueOverdue : item.kind == "due" ? .dueToday : .priority(2) }
    private var kindLabel: LocalizedStringKey {
        switch item.kind {
        case "question": "feed.kind.question"
        case "review": "feed.kind.review"
        case "blocked": "feed.kind.blocked"
        case "overdue": "feed.kind.overdue"
        default: "feed.kind.due"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button(action: open) {
                HStack(alignment: .top, spacing: Space.s) {
                    Image(systemName: symbol).font(.subheadline).foregroundStyle(tint).scaledSquare(24, relativeTo: .subheadline).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(kindLabel).font(.caption.weight(.semibold)).foregroundStyle(tint)
                        titleText.font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading).lineLimit(5).fixedSize(horizontal: false, vertical: true)
                        if let detail = item.detail { MarkdownText(detail).font(.footnote).foregroundStyle(Color.textSecondary).multilineTextAlignment(.leading).lineLimit(3) }
                        Text(verbatim: [item.projectName, item.kind == "question" || item.kind == "review" ? item.taskTitle : nil, due].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Color.textSecondary).multilineTextAlignment(.leading).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .tapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("feed.openTask"))
            if !item.actions.isEmpty {
                if item.kind == "question", item.actions.count == 1, item.actions[0].requiresInput {
                    HStack(alignment: .bottom, spacing: Space.s) {
                        TextField(accessible: "cc.question.placeholder", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...5)
                        Button { act(item.actions[0], text); text = "" } label: { Image(systemName: "paperplane.fill").tapTarget() }
                            .buttonStyle(.borderedProminent).disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel(Text("cc.question.send"))
                    }
                } else {
                    FlowLayout(spacing: Space.s) {
                        ForEach(item.actions) { action in
                            let primary = item.kind != "question" && action.id == item.actions.first?.id
                            Button { if action.requiresInput { input = action } else { act(action, nil) } } label: {
                                Text(verbatim: action.label)
                            }
                            .modifier(ActionStyle(primary: primary)).disabled(busy)
                        }
                    }
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .overlay(alignment: .topTrailing) { if busy { ProgressView().controlSize(.small).padding(Space.s) } }
        .alert(Text(verbatim: input?.label ?? ""), isPresented: Binding(get: { input != nil }, set: { if !$0 { input = nil } })) {
            TextField(accessible: "feed.note", text: $text)
            Button("save") { if let input { act(input, text) }; text = ""; input = nil }
            Button("cancel", role: .cancel) { text = ""; input = nil }
        }
    }

    private var due: String? {
        guard let d = item.dueAt else { return nil }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct PostCard: View {
    let post: FeedPost
    let showImage: (FeedImage) -> Void
    let open: () -> Void
    @ScaledMetric(relativeTo: .body) private var singleWidth: CGFloat = 220
    @ScaledMetric(relativeTo: .body) private var multiWidth: CGFloat = 150
    private static let imageAspect: CGFloat = 11.0 / 15.0

    private var title: LocalizedStringKey {
        switch (post.postKind, post.state) {
        case (.progress, _): "feed.post.progress"
        case (.build, _): "feed.post.build"
        case (.done, _): "feed.post.done"
        case (.review, "accepted"): "feed.post.reviewAccepted"
        case (.review, _): "feed.post.reviewChanges"
        case (.question, _): "feed.post.answered"
        case (.comment, _): "feed.post.comment"
        case (.agentRun, "started"): "feed.post.runStarted"
        case (.agentRun, "failed"): "feed.post.runFailed"
        case (.agentRun, "stopped"): "feed.post.runStopped"
        case (.agentRun, _): "feed.post.runFinished"
        default: "feed.post.other"
        }
    }
    private var symbol: String {
        switch post.postKind {
        case .progress: "chart.bar.fill"
        case .build: "photo.fill"
        case .done: "checkmark.circle.fill"
        case .review: "checkmark.seal.fill"
        case .question: "bubble.left.and.bubble.right.fill"
        case .comment: "text.bubble.fill"
        case .agentRun: "terminal.fill"
        case nil: "circle.fill"
        }
    }
    private var actor: String { post.actor.name ?? (post.actor.isAgent ? String(localized: "feed.agent") : "") }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button(action: open) {
                HStack(alignment: .top, spacing: Space.s) {
                    Image(systemName: symbol).font(.subheadline).foregroundStyle(Color.brand).scaledSquare(24, relativeTo: .subheadline).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        (Text(verbatim: actor.isEmpty ? "" : actor + " ") + Text(title)).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                        if let text = post.text, !text.isEmpty { MarkdownText(text).font(.subheadline).multilineTextAlignment(.leading).lineLimit(3).truncationMode(.tail) }
                        if let detail = post.detail { Text(verbatim: "→ " + detail).font(.footnote).foregroundStyle(Color.textSecondary).multilineTextAlignment(.leading).lineLimit(2) }
                        if let p = post.percent { ProgressView(value: Double(p), total: 100).tint(.brand).accessibilityLabel(Text("\(p) %")) }
                        Text(verbatim: [post.projectName, post.taskTitle, CommandFormat.relative(post.createdAt)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Color.textSecondary).multilineTextAlignment(.leading).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .tapTarget()
            }
            .buttonStyle(.plain)
            if !post.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s) {
                        ForEach(post.images) { image in
                            Button { showImage(image) } label: {
                                RemoteImage(attachmentID: image.attachmentID)
                                    .aspectRatio(Self.imageAspect, contentMode: .fit)
                                    .frame(width: post.images.count == 1 ? singleWidth : multiWidth)
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).stroke(Color.hairline, lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: image.label ?? image.filename))
                            .accessibilityHint(Text("cc.build.open"))
                        }
                    }
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

// MARK: Previews

private enum FeedPreviewData {
    static let needsYou: FeedNeedsYou? = {
        let json = """
        {"id":"q1","kind":"review","projectID":"\(UUID())","projectName":"Website-Relaunch","taskID":"\(UUID())","taskTitle":"Texte für Startseite freigeben","taskVersion":1,
         "title":"Texte sind eingebaut und getestet.","options":[],"blocking":false,
         "actions":[{"key":"accept","label":"Annehmen","method":"POST","path":"/x","requiresInput":false},{"key":"changes","label":"Änderungen anfordern","method":"POST","path":"/x","requiresInput":true}]}
        """
        return try? JSONDecoder().decode(FeedNeedsYou.self, from: Data(json.utf8))
    }()

    static let post: FeedPost? = {
        let json = """
        {"id":"\(UUID())","kind":"progress","event":"progress.posted","projectID":"\(UUID())","projectName":"Website-Relaunch","taskID":"\(UUID())","taskTitle":"Design-Review vorbereiten",
         "actor":{"type":"Agent","id":"\(UUID())","name":"Claude"},"text":"Farbpalette und Typografie sind im Entwurf.","percent":40,
         "images":[{"attachmentID":"\(UUID())","filename":"a.png","mediaType":"image/png","previewURL":"/x","label":"Entwurf"}]}
        """
        return try? JSONDecoder().decode(FeedPost.self, from: Data(json.utf8))
    }()
}

private enum FeedLongPreviewData {
    static let question: FeedNeedsYou? = {
        let json = """
        {"id":"q2","kind":"question","projectID":"\(UUID())","projectName":"Website-Relaunch","taskID":"\(UUID())","taskTitle":"Design-Review vorbereiten","taskVersion":1,
         "title":"Welche Variante der Arbeitsplatte soll ich für die Küche vorbereiten, und soll ich die Angebote der drei Anbieter vorher noch einmal vergleichen lassen?",
         "options":["Ja, bitte zuerst die Startseite für Mobilgeräte optimieren und danach erst die Desktop-Ansicht samt Tablet-Zwischengrößen überarbeiten, weil die meisten Besucher mobil kommen","Nein","Donaudampfschifffahrtsgesellschaftskapitänsmützenvariante"],"blocking":false,
         "actions":[{"key":"a","label":"Ja, bitte zuerst die Startseite für Mobilgeräte optimieren und danach erst die Desktop-Ansicht samt Tablet-Zwischengrößen überarbeiten, weil die meisten Besucher mobil kommen","method":"POST","path":"/x","requiresInput":false},{"key":"b","label":"Nein","method":"POST","path":"/x","requiresInput":false},{"key":"c","label":"Donaudampfschifffahrtsgesellschaftskapitänsmützenvariante","method":"POST","path":"/x","requiresInput":false}]}
        """
        return try? JSONDecoder().decode(FeedNeedsYou.self, from: Data(json.utf8))
    }()

    static let answered: FeedPost? = {
        let json = """
        {"id":"\(UUID())","kind":"question","event":"question.answered","projectID":"\(UUID())","projectName":"Website-Relaunch","taskID":"\(UUID())","taskTitle":"Texte für Startseite freigeben",
         "actor":{"type":"User","id":"\(UUID())","name":"Lino"},"text":"Ja, bitte kürzen. Die Einleitung ist zu lang und wiederholt sich im zweiten Absatz.\\n\\nZusätzlich sollen die drei Kernaussagen als Liste erscheinen, nicht als Fließtext. Bitte außerdem den Abschnitt zur Firmengeschichte komplett nach unten verschieben und die Überschriften auf maximal sechs Wörter beschränken.\\n\\nUnd bitte nichts am Impressum ändern.","images":[]}
        """
        return try? JSONDecoder().decode(FeedPost.self, from: Data(json.utf8))
    }()
}

private struct FeedLongPreviewCards: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let item = FeedLongPreviewData.question { NeedsYouCard(item: item, busy: false, act: { _, _ in }, open: {}) }
            if let post = FeedLongPreviewData.answered { PostCard(post: post, showImage: { _ in }, open: {}) }
        }
        .environment(AppModel())
        .pageMargins().padding(.vertical, Space.l).readableWidth().background(Color.canvas)
    }
}

private struct FeedPreviewCards: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let item = FeedPreviewData.needsYou { NeedsYouCard(item: item, busy: false, act: { _, _ in }, open: {}) }
            if let post = FeedPreviewData.post { PostCard(post: post, showImage: { _ in }, open: {}) }
        }
        .environment(AppModel())
        .pageMargins().padding(.vertical, Space.l).readableWidth().background(Color.canvas)
    }
}

#Preview("Feed Karten, Light") { ScrollView { FeedPreviewCards() } }
#Preview("Feed Karten, Dark") { ScrollView { FeedPreviewCards() }.preferredColorScheme(.dark) }
#Preview("Feed Karten, accessibility5") { ScrollView { FeedPreviewCards() }.dynamicTypeSize(.accessibility5) }
#Preview("Feed, Light") { NavigationStack { FeedView() }.environment(AppModel()).environment(TaskMeta()) }
#Preview("Feed, Dark") { NavigationStack { FeedView() }.environment(AppModel()).environment(TaskMeta()).preferredColorScheme(.dark) }
#Preview("Feed, accessibility5") { NavigationStack { FeedView() }.environment(AppModel()).environment(TaskMeta()).dynamicTypeSize(.accessibility5) }

#Preview("Feed lange Antworten, Light") { ScrollView { FeedLongPreviewCards() } }
#Preview("Feed lange Antworten, Dark") { ScrollView { FeedLongPreviewCards() }.preferredColorScheme(.dark) }
#Preview("Feed lange Antworten, accessibility5") { ScrollView { FeedLongPreviewCards() }.dynamicTypeSize(.accessibility5) }
