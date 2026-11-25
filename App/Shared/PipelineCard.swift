import SwiftUI
import TodoCore

// MARK: Plan approval and pipeline status in the task detail (card B6FC965A, contract pipeline 1.0.0)

/// The plan of a card (Markdown), the actions "Plan freigeben" / "Änderungen" while it waits for a decision, and the status of the
/// six pipeline steps. Shown only when the card has a plan or a step beyond "offen"; plain to-dos keep their short detail.
/// Identifiers sit on leaf elements only (a container identifier would hide the children's).
struct PipelineCard: View {
    let pipeline: TaskPipeline
    let busy: Bool
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
            ForEach(pipeline.steps) { step in StepRow(step: step) }
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: symbol).foregroundStyle(tint).scaledSquare(22, relativeTo: .subheadline).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                AdaptiveStack(spacing: Space.s, verticalAlignment: .firstTextBaseline) {
                    Text(verbatim: stepName).font(.subheadline.weight(.semibold))
                    Text(verbatim: stateText).font(.subheadline).foregroundStyle(Color.textSecondary)
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

@MainActor private func pipelinePreview(_ pipeline: TaskPipeline) -> some View {
    ScrollView { PipelineCard(pipeline: pipeline, busy: false) { _, _ in }.padding(Space.page) }.background(Color.canvas)
}
#Preview("Pipeline proposed light") { pipelinePreview(PipelinePreviewData.proposed).preferredColorScheme(.light) }
#Preview("Pipeline proposed dark") { pipelinePreview(PipelinePreviewData.proposed).preferredColorScheme(.dark) }
#Preview("Pipeline proposed accessibility5") { pipelinePreview(PipelinePreviewData.proposed).dynamicTypeSize(.accessibility5) }
#Preview("Pipeline running light") { pipelinePreview(PipelinePreviewData.running).preferredColorScheme(.light) }
#Preview("Pipeline running dark") { pipelinePreview(PipelinePreviewData.running).preferredColorScheme(.dark) }
#Preview("Pipeline running accessibility5") { pipelinePreview(PipelinePreviewData.running).dynamicTypeSize(.accessibility5) }
#endif
