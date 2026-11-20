import SwiftUI
import TodoCore

/// Card of a confirmation request (backend ADR 0026), like the PWA's `ConfirmationCard.svelte`: what the agent wants
/// to do, "Bestätigen"/"Ablehnen", for irreversible actions a second step (type the project name or tick a box), and
/// the outcome once decided.
struct ConfirmationCard: View {
    let item: FeedConfirmation
    /// Set once decided; the card then shows only the outcome.
    let outcome: ActionRequest?
    let busy: Bool
    /// Brought up by a tapped push notification: a brand outline and its own accessibility identifier.
    var highlighted = false
    let decide: (Bool) -> Void
    @State private var step = Step.ask
    @State private var typed = ""
    @State private var ticked = false

    enum Step { case ask, confirm }

    private var gate: ConfirmationRules.Gate { ConfirmationRules.gate(tool: item.tool) }
    private var ready: Bool {
        ConfirmationRules.ready(destructive: item.impact.destructive, tool: item.tool, typed: typed, ticked: ticked, name: item.impact.targetName)
    }

    private var kindKey: LocalizedStringKey {
        switch item.tool {
        case "delete_project": "confirm.kind.delete_project"
        case "delete_task": "confirm.kind.delete_task"
        case "transfer_project_owner": "confirm.kind.transfer_project_owner"
        default: "confirm.kind.other"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.s) {
                Image(systemName: "exclamationmark.shield.fill").font(.subheadline).foregroundStyle(Color.dueOverdue)
                    .scaledSquare(24, relativeTo: .subheadline).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(kindKey).font(.caption.weight(.semibold)).foregroundStyle(Color.dueOverdue)
                    Text("confirm.by \(item.agentLabel?.isEmpty == false ? item.agentLabel! : String(localized: "confirm.agentFallback"))")
                        .font(.caption).foregroundStyle(Color.textSecondary)
                    Text(verbatim: item.summary).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("confirm.summary")
                    Text("confirm.expires \(item.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(Color.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if let outcome {
                outcomeLine(outcome)
            } else if step == .ask {
                FlowLayout(spacing: Space.s) {
                    Button { step = .confirm } label: { Text("confirm.confirm") }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Color.brand).foregroundStyle(Color.onBrand)
                        .accessibilityIdentifier("confirm.confirm")
                    Button { decide(false) } label: { Text("confirm.reject") }
                        .buttonStyle(AnswerChipStyle())
                        .accessibilityIdentifier("confirm.reject")
                }
                .disabled(busy)
            } else {
                secondStep
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .overlay(alignment: .topTrailing) { if busy { ProgressView().controlSize(.small).padding(Space.s) } }
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: Radius.l, style: .continuous).strokeBorder(Color.brand, lineWidth: 2).allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(highlighted ? "confirm.card.highlighted" : "confirm.card")
    }

    private var secondStep: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if item.impact.destructive {
                switch gate {
                case .typeName:
                    Text("confirm.typeName \(item.impact.targetName)").font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    TextField(accessible: "confirm.nameLabel", text: $typed)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("confirm.name")
                case .tick:
                    Toggle(isOn: $ticked) { Text("confirm.understood").font(.subheadline) }
                        .accessibilityIdentifier("confirm.understood")
                }
            }
            FlowLayout(spacing: Space.s) {
                Button(role: .destructive) { decide(true) } label: { Text(busy ? "confirm.busy" : "confirm.run") }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Color.dueOverdue)
                    .disabled(!ready || busy)
                    .accessibilityIdentifier("confirm.run")
                Button { step = .ask; typed = ""; ticked = false } label: { Text("confirm.cancel") }
                    .buttonStyle(AnswerChipStyle()).disabled(busy)
            }
        }
        .padding(Space.s)
        .overlay(RoundedRectangle(cornerRadius: Radius.s).stroke(Color.dueOverdue.opacity(0.4)))
    }

    private func outcomeLine(_ r: ActionRequest) -> some View {
        let key = ConfirmationRules.outcomeKey(tool: r.tool, state: r.state, code: r.result?.code)
        return Group {
            if r.state == .failed {
                Text("confirm.done.failed \(String(localized: String.LocalizationValue(key)))").foregroundStyle(Color.dueOverdue)
            } else {
                Text(LocalizedStringKey(key)).foregroundStyle(Color.textSecondary)
            }
        }
        .font(.subheadline)
        .accessibilityIdentifier("confirm.outcome")
    }
}

#if DEBUG
private enum ConfirmationPreviewData {
    static let item = FeedConfirmation(
        id: UUID(), tool: "delete_project", summary: "Projekt „Altprojekt“ mit 1 Unterprojekt und 3 Aufgaben löschen",
        impact: ActionImpact(targetType: "project", targetID: UUID(), targetName: "Altprojekt", subprojects: 1, tasks: 3, destructive: true),
        agentLabel: "Claude Code", expiresAt: Date().addingTimeInterval(6 * 86_400))
}

private struct ConfirmationPreview: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Space.m) {
                ConfirmationCard(item: ConfirmationPreviewData.item, outcome: nil, busy: false) { _ in }
            }
            .padding(Space.page)
        }
        .background(Color.canvas)
    }
}

#Preview("Confirmation light") { ConfirmationPreview().preferredColorScheme(.light) }
#Preview("Confirmation dark") { ConfirmationPreview().preferredColorScheme(.dark) }
#Preview("Confirmation accessibility5") { ConfirmationPreview().dynamicTypeSize(.accessibility5) }
#endif
