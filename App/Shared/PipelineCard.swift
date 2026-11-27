import SwiftUI
import TodoCore

// MARK: Plan approval and pipeline status in the task detail (card B6FC965A, contract pipeline 1.0.0)

/// The plan of a card (Markdown), the actions "Plan freigeben" / "Änderungen" while it waits for a decision, and the status of the
/// six pipeline steps. Shown only when the card has a plan or a step beyond "offen"; plain to-dos keep their short detail.
/// Identifiers sit on leaf elements only (a container identifier would hide the children's).
struct PipelineCard: View {
    /// Stage 3 (card BEE2417E): what the section "Ausführung" and the retry at the steps need.
    struct Execution {
        var section = PipelineExecutionSection(show: false, start: false)
        var bindings: [PipelineStartBinding] = []
        var bindingID: Binding<UUID?> = .constant(nil)
        var mayStart = false
        /// Edit right: the retry at a failed step (the app does not know it yet, the server checks it).
        var canEdit = false
        var acting: PipelineExecutionAction?
        var retrying: PipelineStepName?
        var confirming: PipelineExecutionAction?
        var feedback: PipelineFeedback?
        var reviewPending = false
        var onAct: (PipelineExecutionAction) -> Void = { _ in }
        var onRetry: (PipelineStepName) -> Void = { _ in }
    }

    let pipeline: TaskPipeline
    let busy: Bool
    var execution = Execution()
    let onDecide: (PlanDecision, String?) -> Void
    @State private var asking = false
    @State private var comment = ""
    @State private var expanded = false

    /// Blocks shown before "Ganzen Plan zeigen".
    private static let collapsedBlocks = 8

    static func hasContent(_ pipeline: TaskPipeline?) -> Bool {
        guard let pipeline else { return false }
        return pipeline.plan != nil || pipeline.steps.contains { $0.stateKind != .pending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            // First, like the PWA: what runs now and the start.
            if execution.section.show || execution.feedback != nil {
                PipelineExecutionView(pipeline: pipeline, state: execution)
                Divider()
            }
            if let plan = pipeline.plan {
                planSection(plan)
            }
            stepsSection
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: plan

    private func planSection(_ plan: PipelinePlan) -> some View {
        let blocks = PlanMarkdown.blocks(plan.body)
        let shown = expanded ? blocks : Array(blocks.prefix(Self.collapsedBlocks))
        return VStack(alignment: .leading, spacing: Space.s) {
            AdaptiveStack(spacing: Space.s, verticalAlignment: .firstTextBaseline) {
                HStack(spacing: Space.s) {
                    Image(systemName: "list.clipboard.fill").foregroundStyle(Color.chipPurple).accessibilityHidden(true)
                    Text("pipeline.plan.title").font(.sectionTitle).accessibilityAddTraits(.isHeader)
                    Text("pipeline.plan.version \(plan.version)").font(.caption.weight(.semibold)).foregroundStyle(Color.textSecondary)
                }
                Spacer(minLength: Space.xs)
                PlanStateChip(state: plan.state)
            }
            HStack(spacing: Space.s) {
                if let who = plan.authorLabel { Text(verbatim: who) }
                if let at = plan.writtenAt { Text(at, format: .dateTime.day().month().hour().minute()) }
            }
            .font(.caption).foregroundStyle(Color.textSecondary)

            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, block in PlanBlockView(block: block) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("plan.body")

            if blocks.count > Self.collapsedBlocks {
                Button { withAnimation { expanded.toggle() } } label: {
                    Text(expanded ? "pipeline.plan.showLess" : "pipeline.plan.showAll").font(.subheadline.weight(.semibold)).tapTarget()
                }
                .buttonStyle(.plain).foregroundStyle(Color.brand)
                .accessibilityIdentifier("plan.expand")
            }

            if plan.isProposed {
                decision(plan)
            } else {
                decided(plan)
            }
        }
    }

    @ViewBuilder private func decision(_ plan: PipelinePlan) -> some View {
        if asking {
            TextField(accessible: "pipeline.plan.commentPlaceholder", text: $comment, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...6)
                .accessibilityIdentifier("plan.changes.comment")
            AdaptiveStack(spacing: Space.s) {
                Button { onDecide(.requestChanges, comment); asking = false; comment = "" } label: { Text("pipeline.plan.sendChanges") }
                    .buttonStyle(.borderedProminent).tint(Color.chipPurple).controlSize(.large)
                    .disabled(busy || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("plan.changes.send")
                Button("cancel") { asking = false }.buttonStyle(.bordered).controlSize(.large)
                    .accessibilityIdentifier("plan.changes.cancel")
            }
        } else {
            let approve = Button { onDecide(.approve, nil) } label: { Label("pipeline.plan.approve", systemImage: "checkmark") }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Color.brand).foregroundStyle(Color.onBrand)
                .controlSize(.large).disabled(busy).accessibilityIdentifier("plan.approve")
            let changes = Button { asking = true } label: { Label("pipeline.plan.changes", systemImage: "arrow.uturn.backward") }
                .buttonStyle(.bordered).controlSize(.large).disabled(busy).accessibilityIdentifier("plan.changes")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.s) { approve.lineLimit(1).fixedSize(); changes.lineLimit(1).fixedSize() }
                VStack(alignment: .leading, spacing: Space.s) { approve; changes }
            }
        }
    }

    @ViewBuilder private func decided(_ plan: PipelinePlan) -> some View {
        if plan.isApproved || plan.isChangesRequested {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    if let who = plan.decidedByLabel {
                        if plan.isApproved { Text("pipeline.plan.approvedBy \(who)") } else { Text("pipeline.plan.changesBy \(who)") }
                    }
                    if let at = plan.decidedAt { Text(at, format: .dateTime.day().month().hour().minute()) }
                }
                .font(.caption).foregroundStyle(Color.textSecondary)
                if let note = plan.decisionComment, !note.isEmpty {
                    MarkdownText(note).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("plan.decision.comment")
                }
            }
        }
    }

    // MARK: steps

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("pipeline.steps.title").font(.sectionTitle).accessibilityAddTraits(.isHeader)
            let live = pipeline.liveStep
            let hint = pipeline.retryHint(mayStart: execution.mayStart)
            ForEach(pipeline.steps) { step in
                StepRow(step: step, live: live?.step == step.step ? live : nil)
                if let name = step.name { retry(name, offer: pipeline.retryOffer(name, canEdit: execution.canEdit), hint: hint) }
            }
        }
    }
}

extension PipelineCard {
    /// "Wiederholen" below a failed step (outside the step's combined accessibility element, so it stays a button).
    @ViewBuilder func retry(_ step: PipelineStepName, offer: PipelineRetryOffer, hint: PipelineRetryHint?) -> some View {
        switch offer {
        case .hidden: EmptyView()
        case .ready(let round, let max):
            VStack(alignment: .leading, spacing: Space.xs) {
                AdaptiveStack(spacing: Space.s) {
                    Button { execution.onRetry(step) } label: {
                        Label { execution.retrying == step ? Text("pipeline.retry.sending") : Text("pipeline.retry") } icon: { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(.bordered).controlSize(.regular).disabled(execution.retrying != nil || execution.acting != nil)
                    .accessibilityIdentifier("pipeline.retry.\(step.rawValue)")
                    Text("pipeline.retry.round \(round) \(max)").font(.caption).monospacedDigit().foregroundStyle(Color.textSecondary)
                }
                if let hint {
                    Group { hint == .runs ? Text("pipeline.exec.retryRuns") : Text("pipeline.exec.retryNeedsOwner") }
                        .font(.caption).foregroundStyle(Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("pipeline.retry.hint")
                }
            }
            .padding(.leading, Space.xl + Space.s)
        case .exhausted(let max):
            Group { max == 0 ? Text("pipeline.retry.disabled") : Text("pipeline.retry.exhausted \(max)") }
                .font(.caption).foregroundStyle(Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Space.xl + Space.s)
                .accessibilityIdentifier("pipeline.retry.exhausted")
        }
    }
}

// MARK: Parts

/// Plan state as a short chip ("Wartet auf dich", "Freigegeben", "Änderungen verlangt"); an unknown state shows as sent.
private struct PlanStateChip: View {
    let state: String

    private var tint: Color {
        switch state {
        case "approved": Color.tileGreen
        case "changes_requested": Color.tileOrange
        default: Color.chipPurple
        }
    }

    var body: some View {
        Group {
            switch state {
            case "proposed": Text("pipeline.plan.state.proposed")
            case "approved": Text("pipeline.plan.state.approved")
            case "changes_requested": Text("pipeline.plan.state.changes_requested")
            default: Text(verbatim: state)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
        .background(tint.opacity(0.18), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.6), lineWidth: 1))
        .accessibilityIdentifier("plan.state")
    }
}

private struct PlanBlockView: View {
    let block: PlanBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            MarkdownText(text).font(level == 1 ? .headline : .subheadline.weight(.bold)).padding(.top, Space.xs)
                .accessibilityAddTraits(.isHeader)
        case .bullet(let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(verbatim: "•").accessibilityHidden(true)
                MarkdownText(text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline).padding(.leading, CGFloat(indent) * Space.l)
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(verbatim: "\(number).").monospacedDigit().foregroundStyle(Color.textSecondary)
                MarkdownText(text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
        case .code(let text):
            Text(verbatim: text).font(.footnote.monospaced()).textSelection(.enabled)
                .padding(Space.s).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.hairline.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        case .paragraph(let text):
            MarkdownText(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StepRow: View {
    let step: PipelineStepStatus
    /// Set when the execution is at this step: what its job does right now.
    var live: PipelineLiveStep?

    private var symbol: String {
        switch step.stateKind {
        case .done: "checkmark.circle.fill"
        case .running: "bolt.fill"
        case .waiting: "hourglass"
        case .changesRequested: "arrow.uturn.backward.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "arrow.uturn.right.circle"
        case .pending, .unknown: "circle"
        }
    }

    private var tint: Color {
        switch step.stateKind {
        case .done: Color.tileGreen
        case .running: LanePresentation.color("running")
        case .waiting: Color.chipPurple
        case .changesRequested: Color.tileOrange
        case .failed: Color.dueOverdue
        case .skipped, .pending, .unknown: Color.textSecondary
        }
    }

    private var stateText: String {
        let key = "pipeline.state.\(step.state)"
        let found = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return found == key ? step.state : found
    }

    private var stepName: String {
        let key = "pipeline.step.\(step.step)"
        let found = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return found == key ? step.step : found
    }

    private var liveTint: Color {
        switch live?.tone {
        case .running?: LanePresentation.color("running")
        case .warning?: Color.tileOrange
        case .waiting?, nil: Color.textSecondary
        }
    }

    private var liveText: Text? {
        guard let live else { return nil }
        let base: Text = switch live.kind {
        case .queued: Text("pipeline.exec.live.queued")
        case .claimed: Text("pipeline.exec.live.claimed")
        case .running: Text("pipeline.exec.live.running")
        case .answer: Text("pipeline.exec.live.answer")
        case .held: Text("pipeline.exec.live.held")
        }
        guard let progress = live.progress else { return base }
        return base + Text(verbatim: ": \(progress)")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: live == nil ? symbol : live?.tone == .running ? "bolt.fill" : "hourglass")
                .foregroundStyle(live == nil ? tint : liveTint)
                .symbolEffect(.pulse, isActive: live?.tone == .running)
                .scaledSquare(22, relativeTo: .subheadline).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                AdaptiveStack(spacing: Space.s, verticalAlignment: .firstTextBaseline) {
                    Text(verbatim: stepName).font(.subheadline.weight(.semibold))
                    Text(verbatim: stateText).font(.subheadline).foregroundStyle(Color.textSecondary)
                }
                if let liveText {
                    liveText.font(.footnote.weight(.semibold)).foregroundStyle(live?.tone == .waiting ? Color.textSecondary : Color.primary)
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
                if let note = step.note, !note.isEmpty {
                    MarkdownText(note).font(.footnote).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
                if step.actorLabel != nil || step.updatedAt != nil {
                    HStack(spacing: Space.s) {
                        if let who = step.actorLabel { Text(verbatim: who) }
                        if let at = step.updatedAt { Text(at, format: .dateTime.day().month().hour().minute()) }
                    }
                    .font(.caption).foregroundStyle(Color.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: stateText))
        .accessibilityIdentifier("pipeline.step.\(step.step)")
    }
}

#if DEBUG
private enum PipelinePreviewData {
    static func date(_ minutesAgo: Int) -> Date { Date().addingTimeInterval(TimeInterval(-minutesAgo * 60)) }
    static let body = "# Ziel\nPlan und Schritte je Karte anzeigen.\n\n## Schritte\n- TodoCore: Dekodierung\n- Karte in der Detailansicht\n  - Freigabe und Änderungen\n1. Test zuerst\n2. Umsetzung\n\n```\nswift test\n```\nAbschluss mit **Bildern**."

    static func steps(_ overrides: [String: PipelineStepStatus] = [:]) -> [PipelineStepStatus] {
        PipelineStepName.allCases.map { overrides[$0.rawValue] ?? PipelineStepStatus(step: $0.rawValue, state: "pending") }
    }

    static var proposed: TaskPipeline {
        TaskPipeline(taskID: UUID(), plan: PipelinePlan(version: 2, body: body, state: "proposed", authorType: "integration", authorLabel: "Claude", writtenAt: date(20)),
                     steps: steps(["planner": .init(step: "planner", state: "done", actorLabel: "Claude", updatedAt: date(20)),
                                   "approval": .init(step: "approval", state: "waiting", actorLabel: "Claude", updatedAt: date(20))]))
    }

    static var running: TaskPipeline {
        TaskPipeline(taskID: UUID(), plan: PipelinePlan(version: 2, body: body, state: "approved", authorType: "integration", authorLabel: "Claude", writtenAt: date(90),
                                                         decidedAt: date(60), decidedByLabel: "Lino", decisionComment: "Los, aber Tests zuerst."),
                     steps: steps(["planner": .init(step: "planner", state: "done"), "approval": .init(step: "approval", state: "done", actorLabel: "Lino"),
                                   "developer": .init(step: "developer", state: "running", note: "Baut die Karte", actorLabel: "claude-code@apple", updatedAt: date(5)),
                                   "validation": .init(step: "validation", state: "failed", note: "1 Test rot")]))
    }
}

extension PipelinePreviewData {
    static let binding = PipelineStartBinding(id: UUID(), label: "todo-apple", deviceLabel: "Linos Mac")

    static func execution(_ state: String, step: String, reason: String? = nil, job: String? = nil, progress: String? = nil) -> PipelineExecution {
        PipelineExecution(id: UUID(), state: state, reason: reason, step: step, bindingID: binding.id, bindingLabel: "todo-apple", deviceLabel: "Linos Mac",
                          runnerSupportsPipeline: true, jobID: job == nil ? nil : UUID(), jobState: job, jobProgress: progress, createdAt: date(10), updatedAt: date(1))
    }

    static func withExecution(_ execution: PipelineExecution?, failed: String? = nil) -> TaskPipeline {
        let base = running
        let steps = base.steps.map { s in
            s.step == failed ? PipelineStepStatus(step: s.step, state: "failed", note: "1 Test rot", enabled: true)
                : s.step == "developer" ? PipelineStepStatus(step: s.step, state: failed == nil ? "running" : "done", enabled: true)
                : s.step == "validation" && failed == nil ? PipelineStepStatus(step: s.step, state: "pending", enabled: true) : s
        }
        return TaskPipeline(taskID: base.taskID, plan: base.plan, steps: steps, events: [], fixRounds: PipelineFixRounds(used: 0, max: 3, remaining: 3),
                            execution: execution)
    }

    static func state(_ p: TaskPipeline) -> PipelineCard.Execution {
        PipelineCard.Execution(section: p.executionSection(bindings: [binding], mayStart: true), bindings: [binding], mayStart: true, canEdit: true,
                               feedback: p.execution == nil ? nil : .done(.start))
    }

    static var startable: TaskPipeline { withExecution(nil, failed: nil) }
    static var held: TaskPipeline { withExecution(execution("running", step: "developer", job: "queued", progress: "Kontingent-Bremse: Ampel rot bis 14:00")) }
    static var progressing: TaskPipeline { withExecution(execution("running", step: "developer", job: "running", progress: "Schreibe die Tests")) }
    static var blocked: TaskPipeline { withExecution(execution("blocked", step: "validation", reason: "step_failed"), failed: "validation") }
}

@MainActor private func pipelinePreview(_ pipeline: TaskPipeline, execution: PipelineCard.Execution = .init()) -> some View {
    ScrollView { PipelineCard(pipeline: pipeline, busy: false, execution: execution) { _, _ in }.padding(Space.page) }.background(Color.canvas)
}
#Preview("Pipeline execution light") { pipelinePreview(PipelinePreviewData.progressing, execution: PipelinePreviewData.state(PipelinePreviewData.progressing)).preferredColorScheme(.light) }
#Preview("Pipeline execution dark") { pipelinePreview(PipelinePreviewData.held, execution: PipelinePreviewData.state(PipelinePreviewData.held)).preferredColorScheme(.dark) }
#Preview("Pipeline execution accessibility5") { pipelinePreview(PipelinePreviewData.blocked, execution: PipelinePreviewData.state(PipelinePreviewData.blocked)).dynamicTypeSize(.accessibility5) }
#Preview("Pipeline start light") { pipelinePreview(PipelinePreviewData.startable, execution: PipelinePreviewData.state(PipelinePreviewData.startable)).preferredColorScheme(.light) }
#Preview("Pipeline proposed light") { pipelinePreview(PipelinePreviewData.proposed).preferredColorScheme(.light) }
#Preview("Pipeline proposed dark") { pipelinePreview(PipelinePreviewData.proposed).preferredColorScheme(.dark) }
#Preview("Pipeline proposed accessibility5") { pipelinePreview(PipelinePreviewData.proposed).dynamicTypeSize(.accessibility5) }
#Preview("Pipeline running light") { pipelinePreview(PipelinePreviewData.running).preferredColorScheme(.light) }
#Preview("Pipeline running dark") { pipelinePreview(PipelinePreviewData.running).preferredColorScheme(.dark) }
#Preview("Pipeline running accessibility5") { pipelinePreview(PipelinePreviewData.running).dynamicTypeSize(.accessibility5) }
#endif
