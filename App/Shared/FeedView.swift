import SwiftUI
import TodoCore

/// First tab: "Für dich". Cards in the app's design system, no list chrome.
struct FeedView: View {
    @Environment(AppModel.self) private var app
    @State private var model = FeedModel()
    @State private var shown: FeedImage?

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
                    if !model.state.needsYou.isEmpty { needsYou }
                    if !model.state.posts.isEmpty { posts }
                }
            }
            .padding(.horizontal, Space.l).padding(.vertical, Space.m)
            .frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .background(Color.canvas)
        .navigationTitle("view.feed")
        .refreshable { await model.load(app) }
        .task { await model.load(app) }
        .sheet(item: $shown) { image in
            NavigationStack {
                RemoteImage(attachmentID: image.attachmentID, contentMode: .fit).padding()
                    .navigationTitle(Text(verbatim: image.label ?? image.filename))
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("done") { shown = nil } } }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 520)
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
                    Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kindLabel).font(.caption.weight(.semibold)).foregroundStyle(tint)
                        Text(verbatim: item.title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        if let detail = item.detail { Text(verbatim: detail).font(.footnote).foregroundStyle(Color.textSecondary).multilineTextAlignment(.leading) }
                        Text(verbatim: [item.projectName, item.kind == "question" || item.kind == "review" ? item.taskTitle : nil, due].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Color.textSecondary).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
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
                            Button { if action.requiresInput { input = action } else { act(action, nil) } } label: { Text(verbatim: action.label).lineLimit(2) }
                                .buttonStyle(.bordered).controlSize(.large).disabled(busy)
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
                    Image(systemName: symbol).foregroundStyle(Color.brand).frame(width: 24).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        (Text(verbatim: actor.isEmpty ? "" : actor + " ") + Text(title)).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                        if let text = post.text, !text.isEmpty { Text(verbatim: text).font(.subheadline).multilineTextAlignment(.leading).lineLimit(6) }
                        if let detail = post.detail { Text(verbatim: "→ " + detail).font(.footnote).foregroundStyle(Color.textSecondary).multilineTextAlignment(.leading) }
                        if let p = post.percent { ProgressView(value: Double(p), total: 100).tint(.brand).accessibilityLabel(Text("\(p) %")) }
                        Text(verbatim: [post.projectName, post.taskTitle, CommandFormat.relative(post.createdAt)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Color.textSecondary).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !post.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s) {
                        ForEach(post.images) { image in
                            Button { showImage(image) } label: {
                                RemoteImage(attachmentID: image.attachmentID)
                                    .frame(width: post.images.count == 1 ? 220 : 150, height: post.images.count == 1 ? 300 : 200)
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
