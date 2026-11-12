import SwiftUI
import TodoCore

// MARK: Lane presentation

enum LanePresentation {
    static func color(_ key: String) -> Color {
        switch key {
        case "running": Color.priority(1)
        case "question": Color.priority(2)
        case "review": Color.chipPurple
        case "ready": Color.chipTeal
        case "blocked": Color.dueOverdue
        case "done": Color.dueToday
        default: Color.textSecondary
        }
    }

    static func symbol(_ key: String) -> String {
        switch key {
        case "running": "bolt.fill"
        case "question": "questionmark.bubble.fill"
        case "review": "eye.fill"
        case "ready": "tray.full.fill"
        case "blocked": "hand.raised.fill"
        case "done": "checkmark.circle.fill"
        default: "circle"
        }
    }

    /// Plain-string lane name for VoiceOver values.
    static func name(_ key: String) -> String {
        switch key {
        case "running": String(localized: "cc.lane.running")
        case "question": String(localized: "cc.lane.question")
        case "review": String(localized: "cc.lane.review")
        case "ready": String(localized: "cc.lane.ready")
        case "blocked": String(localized: "cc.lane.blocked")
        case "done": String(localized: "cc.lane.done")
        default: key
        }
    }

    static func title(_ key: String, fallback: String) -> Text {
        switch key {
        case "running": Text("cc.lane.running")
        case "question": Text("cc.lane.question")
        case "review": Text("cc.lane.review")
        case "ready": Text("cc.lane.ready")
        case "blocked": Text("cc.lane.blocked")
        case "done": Text("cc.lane.done")
        default: Text(verbatim: fallback)
        }
    }
}

enum CommandFormat {
    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// Localized label for the runner job state; unknown states show the raw value.
    static func jobState(_ state: String) -> Text {
        switch state {
        case "running", "claimed": Text("cc.job.running")
        case "waiting_for_answer": Text("cc.job.waiting")
        case "awaiting_review": Text("cc.job.awaitingReview")
        case "queued", "approved", "pending": Text("cc.job.queued")
        case "failed": Text("cc.job.failed")
        case "stopped", "cancelled": Text("cc.job.stopped")
        case "completed", "accepted": Text("cc.job.completed")
        default: Text(verbatim: state)
        }
    }

    static func progressText(_ p: CommandProgress) -> Text {
        switch p.source {
        case "subtasks": Text("cc.progress.subtasks \(p.subtasksDone) \(p.subtasksTotal)")
        case "criteria": Text("cc.progress.criteria \(p.criteriaDone) \(p.criteriaTotal)")
        case "agent": Text("cc.progress.agent")
        case "status": Text("cc.progress.done")
        default: Text("cc.progress.none")
        }
    }

    /// Localized text for an update kind (`progress.posted`, `question.asked`, ...).
    static func updateKind(_ kind: String) -> Text {
        switch kind {
        case "progress.posted": Text("cc.update.progress")
        case "question.asked": Text("cc.update.questionAsked")
        case "question.answered": Text("cc.update.questionAnswered")
        case "question.withdrawn": Text("cc.update.questionWithdrawn")
        case "review.requested": Text("cc.update.reviewRequested")
        case "review.accepted": Text("cc.update.reviewAccepted")
        case "review.changes_requested": Text("cc.update.reviewChanges")
        case "build.registered", "build.added": Text("cc.update.build")
        case "task.claimed": Text("cc.update.claimed")
        case "task.released": Text("cc.update.released")
        case "task.created": Text("cc.update.created")
        case "task.status_changed": Text("cc.update.status")
        default: Text(verbatim: kind)
        }
    }

    static func updateSymbol(_ kind: String) -> String {
        if kind.hasPrefix("question") { return "questionmark.bubble" }
        if kind.hasPrefix("review") { return "eye" }
        if kind.hasPrefix("progress") { return "chart.bar" }
        if kind.hasPrefix("build") { return "photo" }
        if kind.hasPrefix("task.claim") || kind.hasPrefix("agent") { return "bolt" }
        return "circle.dotted"
    }
}

// MARK: Flow layout (option buttons wrap onto several lines)

struct FlowLayout: Layout {
    var spacing: CGFloat = Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (i, origin) in result.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                              proposal: ProposedViewSize(result.sizes[i]))
        }
    }

    /// Every child is measured with the available width as its proposal, so long labels wrap (or truncate) inside the
    /// row instead of growing to their one-line width and running off the screen.
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint], sizes: [CGSize]) {
        var origins: [CGPoint] = [], sizes: [CGSize] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxWidth: CGFloat = 0
        let limit = width.isFinite ? width : nil
        for view in subviews {
            var size = view.sizeThatFits(ProposedViewSize(width: limit, height: nil))
            if let limit { size.width = min(size.width, limit) }
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y)); sizes.append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, x - spacing)
        }
        return (CGSize(width: min(maxWidth, width.isFinite ? width : maxWidth), height: y + rowHeight), origins, sizes)
    }
}

/// Quiet answer chip for question options: brand tint with a brand outline and primary text (readable on the tinted
/// question card), wraps to at most three lines and never grows wider than its container.
struct AnswerChipStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.primary)
            .multilineTextAlignment(.leading)
            .lineLimit(3)
            .truncationMode(.tail)
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .frame(minHeight: TapTarget.minimum)
            .background(Color.brand.opacity(configuration.isPressed ? 0.24 : 0.12), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).stroke(Color.brand.opacity(0.6), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

// MARK: Authenticated images (build screenshots)

#if canImport(UIKit)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif

@MainActor
private enum ImageCache {
    static let cache: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        c.countLimit = 60
        return c
    }()
}

/// Loads an attachment through the authenticated preview route (AsyncImage cannot send the Bearer token).
struct RemoteImage: View {
    @Environment(AppModel.self) private var app
    let attachmentID: UUID
    var contentMode: ContentMode = .fill
    @State private var image: PlatformImage?
    @State private var failed = false
    /// Images this small (placeholder pixels, broken uploads) would be stretched into a flat colour block.
    private static let minUsableSide: CGFloat = 16

    private func isUsable(_ image: PlatformImage) -> Bool { min(image.size.width, image.size.height) >= Self.minUsableSide }

    var body: some View {
        Group {
            if let image, isUsable(image) {
                #if canImport(UIKit)
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                #else
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
                #endif
            } else {
                ZStack {
                    Color.hairline.opacity(0.4)
                    if image != nil {
                        Image(systemName: "photo").foregroundStyle(Color.textSecondary).accessibilityHidden(true)
                    } else if failed {
                        Image(systemName: "photo.badge.exclamationmark").foregroundStyle(Color.textSecondary)
                            .accessibilityLabel(Text("cc.loadFailed"))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .task(id: attachmentID) {
            let key = attachmentID.uuidString as NSString
            if let cached = ImageCache.cache.object(forKey: key) { image = cached; return }
            guard let client = app.client else { return }
            do {
                let data = try await client.previewAttachment(attachmentID)
                if let decoded = PlatformImage(data: data) {
                    ImageCache.cache.setObject(decoded, forKey: key)
                    image = decoded
                } else { failed = true }
            } catch { failed = true }
        }
    }
}

/// Strip of build screenshots on a card; tapping one opens it full size.
struct BuildStrip: View {
    let builds: [BuildArtifact]
    let total: Int
    @State private var shown: BuildArtifact?
    @ScaledMetric(relativeTo: .caption) private var thumbWidth: CGFloat = 84
    private static let thumbAspect: CGFloat = 3.0 / 4.0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s) {
                ForEach(builds) { b in
                    Button { shown = b } label: {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            RemoteImage(attachmentID: b.attachmentID)
                                .aspectRatio(Self.thumbAspect, contentMode: .fit)
                                .frame(width: thumbWidth)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).stroke(Color.hairline, lineWidth: 1))
                            if let label = b.label ?? b.platform {
                                Text(verbatim: label).font(.caption2).foregroundStyle(Color.textSecondary).lineLimit(1).frame(width: thumbWidth, alignment: .leading)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("cc.build.open"))
                }
                if total > builds.count {
                    Text("cc.build.more \(total - builds.count)").font(.caption).foregroundStyle(Color.textSecondary).padding(.horizontal, Space.xs)
                }
            }
        }
        .sheet(item: $shown) { b in BuildViewer(build: b) }
    }
}

struct BuildViewer: View {
    @Environment(\.dismiss) private var dismiss
    let build: BuildArtifact

    var body: some View {
        NavigationStack {
            RemoteImage(attachmentID: build.attachmentID, contentMode: .fit)
                .padding(Space.l)
                .navigationTitle(Text(verbatim: build.label ?? build.filename))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 520, minHeight: 520, idealHeight: 640)
        #endif
    }
}

// MARK: Questions

/// One open question with answer controls: options as buttons, otherwise a free-text field.
struct QuestionAnswerView: View {
    let prompt: String
    let options: [String]
    let asker: String?
    let blocking: Bool
    let askedAt: Date?
    var taskTitle: String?
    let busy: Bool
    let onAnswer: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(Color.priority(2)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    if let taskTitle { Text(verbatim: taskTitle).font(.caption).foregroundStyle(Color.textSecondary).lineLimit(1) }
                    MarkdownText(prompt).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Space.s) {
                        if let asker { Text(verbatim: asker) }
                        if askedAt != nil { Text(verbatim: CommandFormat.relative(askedAt)) }
                        if blocking { Text("cc.question.blocking").foregroundStyle(Color.priority(2)) }
                    }
                    .font(.caption).foregroundStyle(Color.textSecondary)
                }
            }
            if options.isEmpty {
                HStack(alignment: .bottom, spacing: Space.s) {
                    TextField(accessible: "cc.question.placeholder", text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...5)
                        .onSubmit(send)
                    Button(action: send) { Image(systemName: "paperplane.fill").tapTarget() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(Text("cc.question.send"))
                }
            } else {
                FlowLayout(spacing: Space.s) {
                    ForEach(options, id: \.self) { option in
                        Button { onAnswer(option) } label: { Text(verbatim: option) }
                            .buttonStyle(AnswerChipStyle()).disabled(busy)
                    }
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.priority(2).opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .overlay(alignment: .topTrailing) { if busy { ProgressView().controlSize(.small).padding(Space.s) } }
    }

    private func send() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !busy else { return }
        onAnswer(value)
        text = ""
    }
}

// MARK: Reviews

/// Pending review with summary and the two decisions.
struct ReviewDecisionView: View {
    let summary: String
    let requestedBy: String?
    let requestedAt: Date?
    var taskTitle: String?
    let busy: Bool
    let onDecision: (ReviewDecision, String?) -> Void
    @State private var asking = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: "eye.fill").foregroundStyle(Color.chipPurple).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    if let taskTitle { Text(verbatim: taskTitle).font(.caption).foregroundStyle(Color.textSecondary).lineLimit(1) }
                    Text("cc.review.title").font(.subheadline.weight(.semibold))
                    MarkdownText(summary).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Space.s) {
                        if let requestedBy { Text(verbatim: requestedBy) }
                        if requestedAt != nil { Text(verbatim: CommandFormat.relative(requestedAt)) }
                    }
                    .font(.caption).foregroundStyle(Color.textSecondary)
                }
            }
            if asking {
                TextField(accessible: "cc.review.notePlaceholder", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...6)
                AdaptiveStack(spacing: Space.s) {
                    Button("cc.review.sendChanges") { onDecision(.requestChanges, note); asking = false; note = "" }
                        .buttonStyle(.borderedProminent).tint(Color.chipPurple).controlSize(.large)
                        .disabled(busy || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("cancel") { asking = false }.buttonStyle(.bordered).controlSize(.large)
                }
            } else {
                // Narrow board columns: side by side only when both labels fit on one line, otherwise stacked
                // (a squeezed prominent button degrades into a circle).
                let accept = Button { onDecision(.accept, nil) } label: { Label("cc.review.accept", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).tint(Color.tileGreen).controlSize(.large).disabled(busy)
                let changes = Button { asking = true } label: { Label("cc.review.requestChanges", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.bordered).controlSize(.large).disabled(busy)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.s) { accept.lineLimit(1).fixedSize(); changes.lineLimit(1).fixedSize() }
                    VStack(alignment: .leading, spacing: Space.s) { accept; changes }
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.chipPurple.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .overlay(alignment: .topTrailing) { if busy { ProgressView().controlSize(.small).padding(Space.s) } }
    }
}

// MARK: Card

/// One task / feature as the command center shows it.
struct CommandCardView: View {
    @Environment(AppModel.self) private var app
    let cc: CommandCenterModel
    let card: CommandCard
    var showProject = true

    private var laneColor: Color { LanePresentation.color(card.lane) }

    /// Lane, progress and agent as one phrase on the title (VoiceOver reads the card as title + state).
    private var spokenState: String {
        var parts = [LanePresentation.name(card.lane)]
        if card.progress.source != "none" { parts.append("\(card.progress.percent) %") }
        if let who = card.agent?.claimedLabel { parts.append(who) }
        if card.blockedReason?.isEmpty == false { parts.append(String(localized: "cc.lane.blocked")) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header
            Button { open() } label: {
                Text(verbatim: card.task.title).font(.headline).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading).tapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(verbatim: spokenState))
            .accessibilityHint(Text("a11y.openTask"))
            if card.isFeature || card.progress.source != "none" { progress }
            if let agent = card.agent, agent.claimedLabel != nil || agent.jobState != nil { agentRow(agent) }
            if let reason = card.blockedReason, !reason.isEmpty {
                Label { Text(verbatim: reason) } icon: { Image(systemName: "hand.raised.fill") }
                    .font(.footnote).foregroundStyle(Color.dueOverdue)
            }
            if let update = card.latestUpdate { latest(update) }
            ForEach(card.questions) { q in
                QuestionAnswerView(prompt: q.prompt, options: q.options, asker: q.askedByLabel, blocking: q.blocking, askedAt: q.createdAt,
                    busy: cc.busy.contains(q.id)) { answer in
                    Task { await cc.answer(questionID: q.id, with: answer, app) }
                }
            }
            if card.openQuestionCount > card.questions.count {
                Text("cc.question.moreOpen \(card.openQuestionCount - card.questions.count)").font(.caption).foregroundStyle(Color.textSecondary)
            }
            if let review = card.pendingReview {
                ReviewDecisionView(summary: review.summary, requestedBy: review.requestedByLabel, requestedAt: review.createdAt,
                    busy: cc.busy.contains(card.task.id)) { decision, note in
                    Task { await cc.decide(taskID: card.task.id, decision, note: note, app) }
                }
            }
            if !card.builds.isEmpty { BuildStrip(builds: card.builds, total: card.buildCount) }
            if !card.subtasks.isEmpty { subtasks }
            footer
        }
        .padding(Space.m)
        .padding(.leading, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.m)
        .overlay(alignment: .leading) {
            Capsule().fill(laneColor).frame(width: Space.xs - 1).padding(.vertical, Space.m)
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            if showProject {
                Text(verbatim: "#").font(.caption.weight(.bold)).foregroundStyle(Color.project(card.project.id))
                Text(verbatim: card.project.name).font(.caption).foregroundStyle(Color.textSecondary).lineLimit(1)
            }
            Spacer(minLength: Space.xs)
            if card.isFeature {
                Label("cc.feature", systemImage: "square.stack.3d.up.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Color.chipPurple)
                    .padding(.horizontal, Space.s).padding(.vertical, Space.xxs).background(Color.chipPurple.opacity(0.10), in: Capsule())
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ProgressView(value: Double(max(0, min(100, card.progress.percent))), total: 100).tint(laneColor).frame(minHeight: 6)
            HStack(spacing: Space.s) {
                Text(verbatim: "\(card.progress.percent) %").monospacedDigit().fontWeight(.semibold)
                CommandFormat.progressText(card.progress)
            }
            .font(.caption).foregroundStyle(Color.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func agentRow(_ agent: CommandCardAgent) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: "cpu").foregroundStyle(Color.priority(1)).accessibilityHidden(true)
            if let label = agent.claimedLabel { Text(verbatim: label).fontWeight(.medium) }
            if let state = agent.jobState { CommandFormat.jobState(state).foregroundStyle(Color.textSecondary) }
        }
        .font(.footnote)
    }

    private func latest(_ update: CommandCardUpdate) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            MarkdownText(update.text).font(.footnote).lineLimit(3).foregroundStyle(.primary.opacity(0.85))
            HStack(spacing: Space.xs) {
                if let who = update.actorLabel { Text(verbatim: who) }
                if update.at != nil { Text(verbatim: CommandFormat.relative(update.at)) }
            }
            .font(.caption2).foregroundStyle(Color.textSecondary)
        }
    }

    private var subtasks: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(card.subtasks) { s in
                HStack(spacing: Space.s) {
                    Image(systemName: s.status == "done" ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(s.status == "done" ? Color.dueToday : Color.textSecondary)
                    Text(verbatim: s.title).lineLimit(1).strikethrough(s.status == "done")
                    Spacer(minLength: Space.xs)
                    Text(verbatim: "\(s.progressPercent) %").foregroundStyle(Color.textSecondary).monospacedDigit()
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if card.nextDue != nil || card.priority > 1 {
            HStack(spacing: Space.s) {
                if let due = card.nextDue {
                    Label { Text(verbatim: DueFormat.text(due)) } icon: { Image(systemName: "calendar") }
                        .foregroundStyle(DueFormat.style(due).color)
                }
                if card.priority > 1 { Image(systemName: "flag.fill").foregroundStyle(Color.priority(card.priority)) }
            }
            .font(.caption)
        }
    }

    private func open() {
        let known = app.tasks.first { $0.id == card.task.id }
        app.path = [known ?? TodoTask(id: card.task.id, projectID: card.project.id, title: card.task.title, status: card.task.status, version: card.task.version)]
    }
}

// MARK: Previews

#Preview("Question, Light") {
    QuestionAnswerView(prompt: "Soll die Startseite zuerst auf Mobil optimiert werden?", options: ["Ja, mobil zuerst", "Desktop zuerst"], asker: "Claude", blocking: true, askedAt: nil, taskTitle: "Design-Review vorbereiten", busy: false) { _ in }
        .pageMargins().padding(.vertical, Space.l).background(Color.canvas)
}

#Preview("Question, Dark, klein") {
    QuestionAnswerView(prompt: "Welche Farbe?", options: [], asker: "Claude", blocking: false, askedAt: nil, busy: false) { _ in }
        .pageMargins().padding(.vertical, Space.l).background(Color.canvas)
        .preferredColorScheme(.dark)
}

#Preview("Review, accessibility5") {
    ReviewDecisionView(summary: "Texte sind eingebaut und getestet. Bitte die Datenschutzerklärung prüfen.", requestedBy: "Claude", requestedAt: nil, taskTitle: "Texte für Startseite freigeben", busy: false) { _, _ in }
        .pageMargins().padding(.vertical, Space.l).background(Color.canvas)
        .dynamicTypeSize(.accessibility5)
}

#Preview("Build strip, Light") {
    let json = """
    [{"id":"\(UUID())","attachmentID":"\(UUID())","taskID":"\(UUID())","buildID":"b1","label":"Entwurf Startseite","platform":"iOS","filename":"a.png","mediaType":"image/png","size":1,"previewURL":"/x"}]
    """
    let builds = (try? JSONDecoder().decode([BuildArtifact].self, from: Data(json.utf8))) ?? []
    BuildStrip(builds: builds, total: 3)
        .environment(AppModel())
        .pageMargins().padding(.vertical, Space.l).background(Color.canvas)
}
