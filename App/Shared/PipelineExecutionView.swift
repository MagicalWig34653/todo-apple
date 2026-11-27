import SwiftUI
import TodoCore

// MARK: Pipeline stage 3: section "Ausführung" in the pipeline card (card BEE2417E, contract pipeline 1.2.0)
// Like the PWA (`CardExecution.svelte`): the state of the execution on a runner and, for the project owner, start, continue and stop.
// The buttons are only hidden; the server checks the right. Device, folder and progress texts come from the runner and are shown
// as plain text (`Text(verbatim:)`). Identifiers sit on leaf elements only.

/// The message after start, continue, stop or retry (or why it was refused). Success messages go when the execution moves on.
enum PipelineFeedback: Equatable {
    enum RetryMode: Equatable { case open, running, paused }
    case done(PipelineExecutionAction)
    case retried(step: PipelineStepName, mode: RetryMode)
    case readFirst(version: Int)
    case refused(PipelineExecutionError)
    case failed

    var isSuccess: Bool {
        switch self {
        case .done, .retried: true
        case .readFirst, .refused, .failed: false
        }
    }

    var isError: Bool {
        switch self {
        case .refused, .failed: true
        case .done, .retried, .readFirst: false
        }
    }

    var text: Text {
        switch self {
        case .done(.start): Text("pipeline.exec.feedback.started")
        case .done(.continue): Text("pipeline.exec.feedback.continued")
        case .done(.stop): Text("pipeline.exec.feedback.stopped")
        case .retried(let step, .open): Text("pipeline.feedback.retried \(PipelineNames.step(step.rawValue))")
        case .retried(let step, .running): Text("pipeline.exec.feedback.retriedRunning \(PipelineNames.step(step.rawValue))")
        case .retried(let step, .paused): Text("pipeline.exec.feedback.retriedPaused \(PipelineNames.step(step.rawValue))")
        case .readFirst(let version): Text("pipeline.exec.feedback.readFirst \(version)")
        case .refused(let error): Self.text(for: error)
        case .failed: Text("pipeline.exec.error.generic")
        }
    }

    private static func text(for error: PipelineExecutionError) -> Text {
        switch error {
        case .idConflict: Text("pipeline.exec.error.idConflict")
        case .active: Text("pipeline.exec.error.active")
        case .nothingToRun: Text("pipeline.exec.error.nothing")
        case .noExecution: Text("pipeline.exec.error.none")
        case .planChanged: Text("pipeline.exec.error.planChanged")
        case .stepNotFailed: Text("pipeline.error.stepNotFailed")
        case .fixRoundsExhausted: Text("pipeline.error.fixRoundsExhausted")
        case .stepDisabled: Text("pipeline.error.stepDisabled")
        case .planNotApproved: Text("pipeline.error.planNotApproved")
        case .forbidden: Text("pipeline.exec.error.forbidden")
        case .notFound: Text("pipeline.exec.error.notFound")
        case .network: Text("pipeline.exec.error.network")
        }
    }
}

/// Names of steps and states from the string catalog; unknown values stay as sent.
enum PipelineNames {
    static func lookup(_ key: String, _ raw: String) -> String {
        let found = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return found == key ? raw : found
    }
    static func step(_ step: String) -> String { lookup("pipeline.step.\(step)", step) }
    static func jobState(_ state: String) -> String { lookup("pipeline.exec.job.\(state)", state) }
}

struct PipelineExecutionView: View {
    let pipeline: TaskPipeline
    let state: PipelineCard.Execution

    private var execution: PipelineExecution? { pipeline.execution }
    private var active: Bool { execution?.isActive ?? false }
    private var held: Bool { execution.map { $0.stateKind == .running && $0.isBudgetHold } ?? false }
    private var stepName: String? { execution?.step.map(PipelineNames.step) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            AdaptiveStack(spacing: Space.s, verticalAlignment: .firstTextBaseline) {
                HStack(spacing: Space.s) {
                    Image(systemName: "play.circle.fill").foregroundStyle(Color.brand).accessibilityHidden(true)
                    Text("pipeline.exec.title").font(.sectionTitle).accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: Space.xs)
                if let execution { ExecutionStateChip(execution: execution) }
            }
            if let execution { status(execution) }
            if state.section.start { start } else if showsNothingToRun { Text("pipeline.exec.nothingToRun").font(.footnote).foregroundStyle(Color.textSecondary).accessibilityIdentifier("execution.nothing") }
            if let feedback = state.feedback { PipelineFeedbackLine(feedback: feedback) }
        }
    }

    private var showsNothingToRun: Bool {
        !active && execution?.stateKind != .completed && state.mayStart && !state.bindings.isEmpty && pipeline.nothingToRun
    }

    // MARK: status

    @ViewBuilder private func status(_ execution: PipelineExecution) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if active, let stepName { row("pipeline.exec.step", stepName, id: "execution.step") }
            if let device = execution.deviceLine { row("pipeline.exec.device", device, id: "execution.device") }
            if active, let job = execution.jobState { row("pipeline.exec.job", PipelineNames.jobState(job), id: "execution.job") }
            if let progress = execution.shownProgress { row("pipeline.exec.progress", progress, id: "execution.progress") }
        }
        if held, let text = execution.jobProgress {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: "hourglass").accessibilityHidden(true)
                Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline.weight(.semibold))
            .padding(Space.s).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tileOrange.opacity(0.18), in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("execution.hold")
        }
        hint(execution)
        if active, execution.runnerSupportsPipeline == false {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.tileOrange).accessibilityHidden(true)
                Text("pipeline.exec.unsupported").fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("execution.unsupported")
        }
        if active, state.mayStart { controls(execution) } else if active, execution.stateKind == .paused {
            Text("pipeline.exec.ownerOnly").font(.footnote).foregroundStyle(Color.textSecondary).accessibilityIdentifier("execution.ownerOnly")
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String, id: String) -> some View {
        AdaptiveStack(spacing: Space.s, verticalAlignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Color.textSecondary)
            Text(verbatim: value).fontWeight(.medium).lineLimit(6).fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private func hint(_ execution: PipelineExecution) -> some View {
        let step = stepName ?? PipelineNames.step("")
        Group {
            switch execution.stateKind {
            case .waitingApproval: Text("pipeline.exec.waitingApproval")
            case .blocked:
                execution.reason == "fix_rounds_exhausted" ? Text("pipeline.exec.blocked.fix_rounds_exhausted \(step)") : Text("pipeline.exec.blocked.step_failed \(step)")
            case .paused:
                switch execution.reason {
                case "plan_needs_owner": Text("pipeline.exec.pause.plan_needs_owner")
                case "task_changed": Text("pipeline.exec.pause.task_changed")
                case "continue_required": Text("pipeline.exec.pause.continue_required")
                default: Text("pipeline.exec.pause.other")
                }
            case .completed: state.reviewPending ? Text("pipeline.exec.completedReview") : Text("pipeline.exec.completed")
            case .stopped: Text("pipeline.exec.stopped")
            case .running, .unknown: nil as Text?
            }
        }
        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("execution.hint")
        if execution.stateKind == .blocked, let rounds = pipeline.fixRounds {
            Text("pipeline.exec.fixRounds \(rounds.used) \(rounds.max)").font(.caption).monospacedDigit().foregroundStyle(Color.textSecondary)
                .accessibilityIdentifier("execution.rounds")
        }
    }

    private func controls(_ execution: PipelineExecution) -> some View {
        let busy = state.acting != nil
        let version = pipeline.plan?.version ?? 0
        let resume = Button { state.onAct(.continue) } label: {
            Label {
                if state.acting == .continue { Text("pipeline.exec.sending") }
                else if state.confirming == .continue { Text("pipeline.exec.continueConfirm \(version)") }
                else { Text("pipeline.exec.continue") }
            } icon: { Image(systemName: "play.fill") }
        }
        .buttonStyle(.borderedProminent).tint(Color.brand).foregroundStyle(Color.onBrand).controlSize(.large).disabled(busy)
        .accessibilityIdentifier("execution.continue")
        let stop = Button { state.onAct(.stop) } label: {
            Label { state.acting == .stop ? Text("pipeline.exec.sending") : Text("pipeline.exec.stop") } icon: { Image(systemName: "stop.fill") }
        }
        .buttonStyle(.bordered).controlSize(.large).disabled(busy)
        .accessibilityIdentifier("execution.stop")
        return AdaptiveStack(spacing: Space.s) {
            if execution.stateKind == .paused { resume }
            stop
        }
    }

    // MARK: start

    private var start: some View {
        let version = pipeline.plan?.version ?? 0
        return VStack(alignment: .leading, spacing: Space.s) {
            if execution != nil { Divider() }
            if state.bindings.count > 1 {
                Picker(selection: state.bindingID) {
                    ForEach(state.bindings) { b in Text(verbatim: "\(b.deviceLabel) · \(b.label)").tag(Optional(b.id)) }
                } label: { Text("pipeline.exec.binding") }
                .pickerStyle(.menu)
                .accessibilityIdentifier("execution.binding")
            } else if let only = state.bindings.first {
                AdaptiveStack(spacing: Space.s, verticalAlignment: .firstTextBaseline) {
                    Text("pipeline.exec.binding").foregroundStyle(Color.textSecondary)
                    Text(verbatim: "\(only.deviceLabel) · \(only.label)").fontWeight(.medium)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("execution.binding")
            }
            Button { state.onAct(.start) } label: {
                Label {
                    if state.acting == .start { Text("pipeline.exec.sending") }
                    else if state.confirming == .start { Text("pipeline.exec.startConfirm \(version)") }
                    else { Text("pipeline.exec.start") }
                } icon: { Image(systemName: "play.fill") }
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Color.brand).foregroundStyle(Color.onBrand)
            .controlSize(.large).disabled(state.acting != nil)
            .accessibilityIdentifier("execution.start")
            Text("pipeline.exec.intro").font(.caption).foregroundStyle(Color.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The execution state as a short chip; an unknown state shows as sent.
private struct ExecutionStateChip: View {
    let execution: PipelineExecution

    private var tint: Color {
        switch execution.stateKind {
        case .running: LanePresentation.color("running")
        case .waitingApproval, .paused: Color.chipPurple
        case .blocked: Color.dueOverdue
        case .completed: Color.tileGreen
        case .stopped, .unknown: Color.textSecondary
        }
    }

    var body: some View {
        Group {
            switch execution.stateKind {
            case .running: Text("pipeline.exec.state.running")
            case .waitingApproval: Text("pipeline.exec.state.waiting_approval")
            case .blocked: Text("pipeline.exec.state.blocked")
            case .paused: Text("pipeline.exec.state.paused")
            case .completed: Text("pipeline.exec.state.completed")
            case .stopped: Text("pipeline.exec.state.stopped")
            case .unknown: Text(verbatim: execution.state)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
        .background(tint.opacity(0.18), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.6), lineWidth: 1))
        .accessibilityIdentifier("execution.state")
    }
}

struct PipelineFeedbackLine: View {
    let feedback: PipelineFeedback

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: feedback.isError ? "exclamationmark.circle.fill" : feedback.isSuccess ? "checkmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(feedback.isError ? Color.dueOverdue : feedback.isSuccess ? Color.tileGreen : Color.chipPurple)
                .accessibilityHidden(true)
            feedback.text.fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline.weight(.medium))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("execution.feedback")
    }
}
