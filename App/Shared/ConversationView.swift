import SwiftUI
import TodoCore

// MARK: Model

/// One chat of a card: the task's own chat or the chat of one question or review (like the PWA's `CardConversation`).
/// People and agents write into the same history; the draft stays in the field until the server accepted it.
@MainActor @Observable
final class ConversationModel {
    let taskID: UUID
    let thread: CommentThread
    var items: [Comment] = []
    var draft = ""
    var loaded = false
    var failed = false
    var sending = false
    /// Runs after a message was sent or deleted (for example to refresh the activity list).
    @ObservationIgnored var onChange: (@MainActor () async -> Void)?
    /// Same key for retries of the same draft, so a lost response does not post twice.
    @ObservationIgnored private var sendKey = UUID()

    init(taskID: UUID, thread: CommentThread) {
        self.taskID = taskID
        self.thread = thread
    }

    var canSend: Bool { !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func load(_ app: AppModel) async {
        guard let client = app.client else { return }
        LiveHub.shared.subscribe(self) { [weak self] in await self?.refresh(app) }
        do {
            let list = try await client.comments(taskID: taskID, thread: thread)
            if list != items { items = list }
            failed = false
        } catch APIError.transport {
            failed = true
        } catch {
            failed = true
            await app.handle(error)
        }
        loaded = true
    }

    /// Silent refetch (live refresh): keeps the list when nothing changed and never touches the draft.
    func refresh(_ app: AppModel) async {
        guard loaded, !sending, let client = app.client,
              let list = try? await client.comments(taskID: taskID, thread: thread) else { return }
        if list != items { items = list }
        failed = false
    }

    func send(_ app: AppModel) async {
        let sentDraft = draft
        let text = sentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, let client = app.client else { return }
        sending = true
        defer { sending = false }
        do {
            let created = try await client.addComment(taskID: taskID, body: text, thread: thread, idempotencyKey: sendKey)
            if !items.contains(where: { $0.id == created.id }) { items.append(created) }
            if draft == sentDraft { draft = "" }
            sendKey = UUID()
            Haptics.success()
            await onChange?()
        } catch {
            await app.handle(error)
        }
    }

    func delete(_ comment: Comment, _ app: AppModel) async {
        guard let client = app.client else { return }
        do {
            try await client.deleteComment(taskID: taskID, id: comment.id, version: comment.version)
            items.removeAll { $0.id == comment.id }
            await onChange?()
        } catch { await app.handle(error) }
    }
}

extension CommentThread {
    /// Stable name for accessibility identifiers and UI tests.
    var kindName: String {
        switch self {
        case .all, .task: "task"
        case .question: "question"
        case .review: "review"
        }
    }
}

// MARK: Views

/// Chat of a question or review inside the agent card: owns its model and brings its own composer.
struct ThreadConversation: View {
    @Environment(AppModel.self) private var app
    @State private var model: ConversationModel
    let title: LocalizedStringKey

    init(taskID: UUID, thread: CommentThread, title: LocalizedStringKey) {
        _model = State(initialValue: ConversationModel(taskID: taskID, thread: thread))
        self.title = title
    }

    var body: some View {
        ConversationView(model: model, title: title, emptyKey: "chat.empty.thread", composer: true, bubbleFill: .canvas)
            .task { await model.load(app) }
    }
}

/// History as bubbles (you right, people and agents left, agents marked), author and relative time; optional composer.
struct ConversationView: View {
    @Environment(AppModel.self) private var app
    let model: ConversationModel
    var title: LocalizedStringKey?
    var emptyKey: LocalizedStringKey = "chat.empty"
    var composer = false
    /// Fill of the bubbles of other people; must differ from the surface the chat sits on.
    var bubbleFill: Color = .canvas

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let title {
                HStack(spacing: Space.s) {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(Color.textSecondary)
                    if !model.items.isEmpty {
                        Text(verbatim: String(model.items.count)).font(.caption.weight(.semibold)).foregroundStyle(Color.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            if !model.loaded {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            } else if model.failed && model.items.isEmpty {
                Button { Task { await model.load(app) } } label: {
                    Text("chat.loadFailed").font(.footnote).foregroundStyle(Color.dueOverdue).tapTarget()
                }
                .buttonStyle(.plain)
            } else if model.items.isEmpty {
                Text(emptyKey).font(.footnote).foregroundStyle(Color.textSecondary)
            }
            ForEach(model.items) { c in
                ChatBubble(comment: c, author: c.author(me: app.user?.id), otherFill: bubbleFill)
                    .contextMenu {
                        if c.isMine(app.user?.id) {
                            Button("comment.delete", role: .destructive) { Task { await model.delete(c, app) } }
                        }
                    }
            }
            if composer { ChatComposer(model: model, inline: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.\(model.thread.kindName)")
    }
}

struct ChatBubble: View {
    let comment: Comment
    let author: CommentAuthor
    var otherFill: Color = .canvas
    @Environment(\.dynamicTypeSize) private var typeSize

    private var mine: Bool { author == .me }
    private var agent: Bool { if case .agent = author { true } else { false } }

    private var authorName: Text {
        switch author {
        case .me: Text("chat.author.me")
        case .agent(let label): label.map { Text(verbatim: $0) } ?? Text("chat.author.agent")
        case .person(let name): name.map { Text(verbatim: $0) } ?? Text("chat.author.other")
        }
    }

    private var fill: Color {
        if mine { return Color.brand.opacity(0.14) }
        if agent { return Color.chipPurple.opacity(0.12) }
        return otherFill
    }

    /// Tail corner towards the author's side, like a messenger.
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: Radius.l, bottomLeadingRadius: mine ? Radius.l : Radius.xs,
                               bottomTrailingRadius: mine ? Radius.xs : Radius.l, topTrailingRadius: Radius.l, style: .continuous)
    }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: Space.xxs) {
            HStack(spacing: Space.xs) {
                if agent { Image(systemName: "bolt.fill").foregroundStyle(Color.chipPurple).accessibilityHidden(true) }
                authorName.fontWeight(.semibold)
                if let at = comment.createdAt { Text(verbatim: CommandFormat.relative(at)) }
            }
            .font(.caption).foregroundStyle(Color.textSecondary)
            content
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                .background(fill, in: shape)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        // Leave room on the other side so the sides stay readable; at accessibility sizes use the full width.
        .padding(mine ? .leading : .trailing, typeSize.isAccessibilitySize ? 0 : Space.xxl)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(agent ? "chat.bubble.agent" : mine ? "chat.bubble.mine" : "chat.bubble.other")
    }

    @ViewBuilder private var content: some View {
        if comment.isAttachment {
            VStack(alignment: .leading, spacing: Space.xs) {
                let files = comment.attachments ?? []
                if files.isEmpty {
                    Label { Text(verbatim: comment.body) } icon: { Image(systemName: "paperclip") }
                } else {
                    ForEach(files) { a in
                        Label { Text(verbatim: a.filename).lineLimit(typeSize.isAccessibilitySize ? nil : 2) } icon: {
                            Image(systemName: a.isImage ? "photo" : "doc.richtext")
                        }
                    }
                }
            }
        } else {
            MarkdownText(comment.body)
        }
    }
}

/// Text field with a send button. `inline` sits inside a card (question/review chat); otherwise it is the bar at the
/// bottom of the task detail.
struct ChatComposer: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ConversationModel
    var inline = false

    var body: some View {
        HStack(alignment: .bottom, spacing: Space.s) {
            TextField(accessible: inline ? "chat.reply" : "chat.new", text: $model.draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                .background(inline ? Color.canvas : Color.canvasRaised, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5))
                .accessibilityIdentifier("chat.field.\(model.thread.kindName)")
            Button {
                Task { await model.send(app) }
            } label: {
                // Not `.disabled`: the system would dim the label to about 30 %. The empty state is shown by shape (outline
                // instead of filled) and a secondary-text color (4.5:1), and the action is guarded instead.
                Group {
                    if model.sending { ProgressView() } else {
                        Image(systemName: model.canSend ? "arrow.up.circle.fill" : "arrow.up.circle")
                            .font(inline ? .title2 : .title)
                            .foregroundStyle(model.canSend ? Color.brand : Color.textSecondary)
                    }
                }
                .tapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("chat.send"))
            .accessibilityIdentifier("chat.send.\(model.thread.kindName)")
        }
    }
}

// MARK: Previews

#if DEBUG
private enum ChatPreviewData {
    static let me = UUID()
    @MainActor static var model: ConversationModel {
        let task = UUID(), q = UUID(), other = UUID()
        let json = """
        [{"id":"\(UUID())","taskID":"\(task)","authorID":"\(other)","authorName":"Lino","body":"Bitte die **Startseite** zuerst mobil prüfen.","version":1,"authorKind":"person","createdAt":"2026-11-12T08:00:00Z"},
         {"id":"\(UUID())","taskID":"\(task)","authorID":"\(me)","authorName":"Ich","body":"Mache ich, danach Screenshots.","version":1,"authorKind":"person","createdAt":"2026-11-12T08:05:00Z"},
         {"id":"\(UUID())","taskID":"\(task)","authorID":"\(me)","authorName":"Ich","body":"Farbpalette steht, Kontrast `AA` geprüft. Frage: soll der Header fixiert bleiben?","version":1,"authorKind":"agent","authorLabel":"claude-code@mac","questionID":"\(q)","createdAt":"2026-11-12T08:10:00Z"},
         {"id":"\(UUID())","taskID":"\(task)","authorID":"\(me)","authorName":"Ich","body":"shot.png","version":1,"kind":"attachment","attachments":[{"id":"\(UUID())","filename":"startseite-iphone.png","mediaType":"image/png","size":2048}]}]
        """
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let m = ConversationModel(taskID: task, thread: .task)
        m.items = (try? d.decode([Comment].self, from: Data(json.utf8))) ?? []
        m.loaded = true
        return m
    }
}

private struct ChatPreview: View {
    @State private var model = ChatPreviewData.model
    var body: some View {
        ScrollView {
            ConversationView(model: model, title: "chat.title.question", composer: true)
                .padding(Space.m).cardSurface().pageMargins()
        }
        .background(Color.canvas)
        .environment(AppModel())
    }
}

#Preview("Chat light") { ChatPreview().preferredColorScheme(.light) }
#Preview("Chat dark") { ChatPreview().preferredColorScheme(.dark) }
#Preview("Chat accessibility5") { ChatPreview().dynamicTypeSize(.accessibility5) }
#endif
