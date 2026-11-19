import SwiftUI
import TodoCore

// MARK: Markdown

/// Agents write questions, reviews, progress notes and comments in Markdown. SwiftUI's `Text` only renders inline
/// Markdown from a literal, so dynamic strings were shown raw ("**fett**", "# Ziele"). This renders inline Markdown
/// (bold, italic, code, links), keeps line breaks and turns `#` headings into bold lines; list markers stay as text.
enum MarkdownFormat {
    static func attributed(_ source: String) -> AttributedString {
        let lines = source.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.drop { $0 == " " }
            guard trimmed.hasPrefix("#") else { return line }
            let hashes = trimmed.prefix { $0 == "#" }
            let rest = trimmed.dropFirst(hashes.count)
            guard hashes.count <= 6, rest.hasPrefix(" ") else { return line }
            let heading = rest.trimmingCharacters(in: .whitespaces)
            return heading.isEmpty ? line : "**\(heading)**"
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: lines.joined(separator: "\n"), options: options)) ?? AttributedString(source)
    }
}

/// `Text` for user or agent content that may contain Markdown.
struct MarkdownText: View {
    let source: String
    init(_ source: String) { self.source = source }
    var body: some View { Text(MarkdownFormat.attributed(source)) }
}

// MARK: Agent context in the task detail

/// What agents are doing on this card, shown at the top of the task detail: who works on it, progress, the latest
/// progress note, open questions and the pending review (answerable here, each with its own chat like the PWA), the
/// decided review with its chat, acceptance criteria and build screenshots. Hidden when the card has no agent activity,
/// so plain to-dos keep their short detail.
struct AgentContextCard: View {
    let context: TaskContext
    let busy: Bool
    let onAnswer: (Question, String) -> Void
    let onDecide: (ReviewDecision, String?) -> Void
    /// Chosen variant of a review with variants (accepts the review with it).
    var onChoose: (String) -> Void = { _ in }

    static func hasContent(_ c: TaskContext) -> Bool {
        c.workflow.claimedLabel != nil || c.workflow.blockedReason?.isEmpty == false || !c.progressNotes.isEmpty
            || c.questions.contains(where: \.isOpen) || c.review != nil || !c.builds.isEmpty
    }

    private var openQuestions: [Question] { context.questions.filter(\.isOpen) }
    private var latestNote: ProgressNote? { context.progressNotes.max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) } }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header
            if let reason = context.workflow.blockedReason, !reason.isEmpty {
                Label { MarkdownText(reason) } icon: { Image(systemName: LanePresentation.symbol("blocked")) }
                    .font(.subheadline).foregroundStyle(Color.dueOverdue)
            }
            if context.progress.source != "none" { progress }
            ForEach(openQuestions) { q in
                QuestionAnswerView(prompt: q.prompt, options: q.options, asker: q.askerDisplay, blocking: q.blocking,
                                   askedAt: q.createdAt, busy: busy) { onAnswer(q, $0) }
                ThreadConversation(taskID: context.task.id, thread: .question(q.id), title: "chat.title.question").id(q.id)
            }
            if let review = context.review {
                if review.isPending {
                    ReviewDecisionView(summary: review.summary, requestedBy: review.requestedByLabel, requestedAt: review.createdAt,
                                       variants: review.variants, busy: busy, onDecision: onDecide, onChoose: onChoose)
                } else {
                    reviewResult(review)
                }
                ThreadConversation(taskID: context.task.id, thread: .review(review.id), title: "chat.title.review").id(review.id)
            }
            if !context.builds.isEmpty { BuildStrip(builds: context.builds, total: context.builds.count) }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: "bolt.fill").foregroundStyle(LanePresentation.color("running")).accessibilityHidden(true)
            Text("agent.section.title").font(.sectionTitle)
            Spacer(minLength: Space.xs)
            if let who = context.workflow.claimedLabel {
                Text(verbatim: who).font(.caption.weight(.semibold)).foregroundStyle(Color.textSecondary).lineLimit(1)
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text(verbatim: "\(context.progress.percent) %").font(.subheadline.weight(.semibold)).monospacedDigit()
                CommandFormat.progressText(context.progress).font(.caption).foregroundStyle(Color.textSecondary)
            }
            ProgressView(value: Double(min(max(context.progress.percent, 0), 100)), total: 100).tint(LanePresentation.color("running"))
            if let note = latestNote {
                MarkdownText(note.note).font(.subheadline).lineLimit(6).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.s) {
                    if let who = note.actorLabel { Text(verbatim: who) }
                    if note.createdAt != nil { Text(verbatim: CommandFormat.relative(note.createdAt)) }
                }
                .font(.caption).foregroundStyle(Color.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Decided or withdrawn review: outcome, who and when, the summary and the decision note.
    private func reviewResult(_ review: Review) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Label {
                switch review.state {
                case "accepted": Text("agent.review.accepted")
                case "changes_requested": Text("agent.review.changes")
                default: Text("agent.review.withdrawn")
                }
            } icon: {
                Image(systemName: review.state == "accepted" ? "checkmark.seal.fill" : review.state == "changes_requested" ? "arrow.uturn.backward.circle.fill" : "xmark.circle")
                    .foregroundStyle(review.state == "accepted" ? Color.tileGreen : Color.textSecondary)
            }
            .font(.subheadline.weight(.semibold))
            HStack(spacing: Space.s) {
                if let who = review.requestedByLabel { Text(verbatim: who) }
                if let at = review.decidedAt ?? review.createdAt { Text(verbatim: CommandFormat.relative(at)) }
            }
            .font(.caption).foregroundStyle(Color.textSecondary)
            MarkdownText(review.summary).font(.subheadline).lineLimit(8).fixedSize(horizontal: false, vertical: true)
            if review.state == "accepted", let chosen = review.chosenVariant, let text = review.chosenText {
                Text(verbatim: text).font(.subheadline.weight(.semibold))
                ChosenVariantView(review: review, chosen: chosen)
            }
            if let note = review.decisionNote, !note.isEmpty {
                MarkdownText(note).font(.subheadline)
                    .padding(.leading, Space.s)
                    .overlay(alignment: .leading) { Capsule().fill(Color.hairline).frame(width: Space.xxs) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.review.result")
    }
}

// MARK: Previews

#if DEBUG
private enum AgentPreviewData {
    static let json = """
    {"task":{"id":"7A0C3B8E-6B3B-4E64-9A43-2C0B8C5C2C11","projectID":"0C1B3B8E-6B3B-4E64-9A43-2C0B8C5C2C11","title":"Startseite","description":"","status":"in_progress","version":3},
     "projectID":"0C1B3B8E-6B3B-4E64-9A43-2C0B8C5C2C11",
     "workflow":{"taskID":"7A0C3B8E-6B3B-4E64-9A43-2C0B8C5C2C11","kind":"task","isFeature":false,"claimedLabel":"claude-code@mac"},
     "progress":{"percent":40,"source":"agent","subtasksDone":0,"subtasksTotal":0,"criteriaDone":1,"criteriaTotal":2},
     "progressNotes":[{"id":"1A0C3B8E-6B3B-4E64-9A43-2C0B8C5C2C11","taskID":"7A0C3B8E-6B3B-4E64-9A43-2C0B8C5C2C11","actorType":"Integration","actorID":"2A0C3B8E-6B3B-4E64-9A43-2C0B8C5C2C11","actorLabel":"Claude","note":"**Farbpalette** steht, Typografie im Entwurf.","percent":40}],
     "criteria":[{"id":"3A0C3B8E-6B3B-4E64-9A43-2C0B8C5C2C11","taskID":"7A0C3B8E-6B3B-4E64-9A43-2C0B8C5C2C11","text":"Mobil zuerst","completed":true,"version":1},
                 {"id":"4A0C3B8E-6B3B-4E64-9A43-2C0B8C5C2C11","taskID":"7A0C3B8E-6B3B-4E64-9A43-2C0B8C5C2C11","text":"Kontrast `AA`","completed":false,"version":1}],
     "subtasks":[],"comments":[],"questions":[],"builds":[]}
    """
    static var context: TaskContext? {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(TaskContext.self, from: Data(json.utf8))
    }
}

private struct AgentCardPreview: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                if let c = AgentPreviewData.context { AgentContextCard(context: c, busy: false, onAnswer: { _, _ in }, onDecide: { _, _ in }) }
                MarkdownText("# Ziele\n**Fett**, `Code` und ein [Link](https://example.com)\n- Punkt eins\n- Punkt zwei").font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .pageMargins()
        }
        .background(Color.canvas)
    }
}

#Preview("Agent card light") { AgentCardPreview().preferredColorScheme(.light) }
#Preview("Agent card dark") { AgentCardPreview().preferredColorScheme(.dark) }
#Preview("Agent card accessibility5") { AgentCardPreview().dynamicTypeSize(.accessibility5) }
#endif
