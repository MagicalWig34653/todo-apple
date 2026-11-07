import SwiftUI
import TodoCore

/// "Benachrichtigungen" sections for the account screen (iOS/iPad/Mac window) and the Mac settings window.
/// Hidden entirely when the server has no push endpoints.
struct NotificationSettingsSections: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    private var push: PushCoordinator { .shared }

    var body: some View {
        Group {
            if push.available {
                statusSection
                if push.serverSupport == .supported, push.prefs != nil {
                    categoriesSection
                    contentSection
                }
            }
        }
        .task { await app.pushSync() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await app.pushSync() } } }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            LabeledContent("push.status") { Text(statusKey).foregroundStyle(Color.textSecondary) }
                .accessibilityElement(children: .combine)
            switch push.authorization {
            case .notDetermined, .unknown:
                Button("push.enable") { Task { await app.enablePush() } }
                    .tapTarget()
            case .denied:
                Text("push.denied.hint").font(.footnote).foregroundStyle(Color.textSecondary)
                Button("push.openSettings") { push.openSystemSettings() }.tapTarget()
            case .authorized: EmptyView()
            }
            if push.serverPushEnabled == false {
                Label { Text("push.serverOff") } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.footnote).foregroundStyle(Color.textSecondary)
            }
            if let key = push.registrationErrorKey {
                Label { Text(LocalizedStringKey(key)) } icon: { Image(systemName: "exclamationmark.circle") }
                    .font(.footnote).foregroundStyle(Color.textSecondary)
            }
        } header: { Text("push.title") }
    }

    private var statusKey: LocalizedStringKey {
        switch push.authorization {
        case .authorized: "push.status.on"
        case .denied: "push.status.denied"
        case .notDetermined, .unknown: "push.status.notAsked"
        }
    }

    // MARK: Categories

    private func binding(_ category: PushCategory) -> Binding<Bool> {
        Binding(
            get: { push.prefs?.categories[category] ?? false },
            set: { value in Task { await push.setCategory(category, enabled: value, client: app.client) } })
    }

    private var categoriesSection: some View {
        Section {
            Toggle("push.cat.reminders", isOn: binding(.reminders))
            Toggle("push.cat.questions", isOn: binding(.agentQuestions))
            Toggle("push.cat.reviews", isOn: binding(.agentReviews))
            Toggle("push.cat.comments", isOn: binding(.comments))
        } header: { Text("push.categories") } footer: {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("push.categories.footer")
                if let key = push.prefsErrorKey { Text(LocalizedStringKey(key)).foregroundStyle(Color.dueOverdue) }
            }
        }
    }

    private var contentSection: some View {
        Section {
            Toggle("push.showContent", isOn: Binding(
                get: { push.prefs?.showContent ?? false },
                set: { v in Task { await push.setShowContent(v, client: app.client) } }))
            Toggle("push.badge", isOn: Binding(
                get: { push.prefs?.badge ?? true },
                set: { v in Task { await push.setBadge(v, client: app.client) } }))
        } footer: { Text("push.showContent.footer") }
    }
}

/// Explainer card, shown once in context (command center with open questions or reviews) before the system prompt.
struct PushPrimerCard: View {
    @Environment(AppModel.self) private var app
    private var push: PushCoordinator { .shared }
    @State private var hidden = false

    var visible: Bool {
        !hidden && !push.primerDismissed && push.available && push.authorization == .notDetermined && app.attentionCount > 0
    }

    var body: some View {
        if visible {
            PushPrimerContent(
                enable: { hide(); Task { await app.enablePush() } },
                later: { hide() })
        }
    }

    private func hide() { push.primerDismissed = true; hidden = true }
}

/// Layout of the explainer card (separate so previews can show it without push state).
struct PushPrimerContent: View {
    let enable: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label { Text("push.primer.title").font(.headline) } icon: { Image(systemName: "bell.badge").foregroundStyle(Color.brand) }
                .accessibilityAddTraits(.isHeader)
            Text("push.primer.message").font(.subheadline).foregroundStyle(Color.textSecondary)
            AdaptiveStack(spacing: Space.s) {
                Button("push.primer.enable", action: enable).buttonStyle(.borderedProminent).tapTarget()
                Button("push.primer.later", action: later).buttonStyle(.bordered).tapTarget()
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.m)
        .readableWidth()
        .pageMargins()
        .padding(.top, Space.s)
        .accessibilityElement(children: .contain)
    }
}

#if DEBUG
private struct PrimerPreview: View {
    var body: some View {
        VStack(spacing: 0) { PushPrimerContent(enable: {}, later: {}); Spacer() }
            .background(Color.canvas)
    }
}
#Preview("Primer light") { PrimerPreview().preferredColorScheme(.light) }
#Preview("Primer dark") { PrimerPreview().preferredColorScheme(.dark) }
#Preview("Primer accessibility5") { PrimerPreview().dynamicTypeSize(.accessibility5) }
#endif
