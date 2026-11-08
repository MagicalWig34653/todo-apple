import SwiftUI
import TodoCore

/// First tab: "Für dich". Cards in the app's design system, no list chrome.
struct FeedView: View {
    @Environment(AppModel.self) private var app
    @State private var model = FeedModel()
    @State private var shown: FeedImage?

    /// DEBUG only: `TODO_DEBUG_FEED_POSTS=1` hides the needs-you section so screenshots can reach the posts (no touch input in the simulator).
    private static var debugPostsOnly: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["TODO_DEBUG_FEED_POSTS"] == "1"
        #else
        false
        #endif
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.m) {
                if model.unsupported {
                    EmptyState(symbol: "icloud.slash", title: "feed.unsupported", message: "feed.unsupportedHint").padding(.top, Space.xxl)
                } else if !model.state.loaded {
                    if model.failed { EmptyState(symbol: "wifi.exclamationmark", title: "feed.failed", message: "feed.failedHint").padding(.top, Space.xxl) }
                    else { SkeletonRows(count: 5) }
                } else if model.state.isEmpty {
                    EmptyState(symbol: "sparkles", title: "feed.empty", message: "feed.emptyHint").padding(.top, Space.xxl)
                } else {
                    if !model.state.needsYou.isEmpty, !Self.debugPostsOnly { needsYou }
                    if !model.state.posts.isEmpty { posts }
                }
            }
            .pageMargins().padding(.vertical, Space.m)
            .readableWidth()
        }
        .background(Color.canvas)
        .navigationTitle("view.feed")
        .refreshable { await model.load(app) }
        .task { await model.load(app) }
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

    private var needsYou: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text("feed.needsYou").font(Font.sectionTitle).foregroundStyle(Color.textSecondary).accessibilityAddTraits(.isHeader)
                if model.state.needsYouTotal > model.state.needsYou.count {
                    Text("feed.needsYou.more \(model.state.needsYouTotal - model.state.needsYou.count)").font(.caption).foregroundStyle(Color.textSecondary)
                }
            }
            ForEach(model.state.needsYou) { item in
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
                        Text(verbatim: item.title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading).lineLimit(5).fixedSize(horizontal: false, vertical: true)
                        if let detail = item.detail { Text(verbatim: detail).font(.footnote).foregroundStyle(Color.textSecondary).multilineTextAlignment(.leading).lineLimit(3) }
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
                        if let text = post.text, !text.isEmpty { Text(verbatim: text).font(.subheadline).multilineTextAlignment(.leading).lineLimit(3).truncationMode(.tail) }
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
#Preview("Feed, Light") { NavigationStack { FeedView() }.environment(AppModel()) }

#Preview("Feed lange Antworten, Light") { ScrollView { FeedLongPreviewCards() } }
#Preview("Feed lange Antworten, Dark") { ScrollView { FeedLongPreviewCards() }.preferredColorScheme(.dark) }
#Preview("Feed lange Antworten, accessibility5") { ScrollView { FeedLongPreviewCards() }.dynamicTypeSize(.accessibility5) }
