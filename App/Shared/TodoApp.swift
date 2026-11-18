import SwiftUI
import TodoCore

@main
struct TodoApp: App {
    @State private var model = AppModel()
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    #if DEBUG && os(macOS)
    init() {
        // TODO_DEBUG_RENDER runs without any window (activation policy .prohibited), so `.task { start() }` never fires.
        let m = AppModel()
        _model = State(initialValue: m)
        if DebugLaunch.renderRequested { Task { @MainActor in await m.start() } }
    }
    #endif

    var body: some Scene {
        WindowGroup("app.title") {
            RootView().environment(model).hapticHost().task { await model.start() }
                #if DEBUG
                .overlay(alignment: .topLeading) { DebugProbeView() }
                #endif
                .preferredColorScheme(model.colorScheme.swiftUI)
                #if os(macOS)
                .frame(minWidth: 820, minHeight: 560)
                #endif
        }
        .commands { AppCommands(model: model) }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif
        #if os(macOS)
        Settings { SettingsView().environment(model) }
        #endif
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        #if DEBUG
        // Debug screenshots without a server: `TODO_DEBUG_NOW_PREVIEW=full|empty` shows the "Jetzt" screen with sample data.
        if let variant = ProcessInfo.processInfo.environment["TODO_DEBUG_NOW_PREVIEW"] {
            OverviewNowPreviewHost(data: variant == "empty" ? OverviewNow(serverTime: OverviewNowSample.now) : variant == "builds" ? OverviewNowSample.buildsOnly : OverviewNowSample.data)
        } else { realBody }
        #else
        realBody
        #endif
    }

    @ViewBuilder private var realBody: some View {
        switch model.phase {
        case .launching: ProgressView()
        case .signedOut: LoginView()
        case .signedIn:
            MainView().onAppear { model.openPendingPushLink() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.openPendingPushLink(); Task { await model.pushSync() } }
                }
        }
    }
}

/// Menu-bar commands (Mac menu bar, iPad menu bar and the keyboard shortcut overlay on iPad).
struct AppCommands: Commands {
    let model: AppModel

    private var signedIn: Bool { model.phase == .signedIn }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("task.add") { model.quickAddRequests += 1 }
                .keyboardShortcut("n").disabled(!signedIn)
            Button("project.new") { model.newProjectRequests += 1 }
                .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!signedIn)
        }
        CommandGroup(after: .textEditing) {
            Button("menu.find") { model.selection = .search }
                .keyboardShortcut("f").disabled(!signedIn)
        }
        CommandGroup(after: .sidebar) {
            Button("menu.refresh") { Task { await model.reload() } }
                .keyboardShortcut("r").disabled(!signedIn)
        }
        CommandMenu("menu.go") {
            Group {
            Button("view.inbox") { model.selection = .inbox }.keyboardShortcut("1")
            Button("view.today") { model.selection = .today }.keyboardShortcut("2")
            Button("view.upcoming") { model.selection = .upcoming }.keyboardShortcut("3")
            Button("view.commandCenter") { model.selection = .commandCenter }.keyboardShortcut("4")
            Button("view.now") { model.selection = .now }.keyboardShortcut("7")
            Button("view.labels") { model.selection = .labels }.keyboardShortcut("5")
            Divider()
            Button("view.teams") { model.selection = .teams }.keyboardShortcut("6")
            }
            .disabled(!signedIn)
        }
    }
}

#if os(macOS)
/// Settings window (Cmd+,): account, server, version.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var hub = SettingsHubModel()

    var body: some View {
        Form {
            Section {
                LabeledContent("account.name") { Text(verbatim: model.user?.displayName ?? "–") }
                if let u = model.user?.username { LabeledContent("account.username") { Text(verbatim: u) } }
                LabeledContent("login.server") { Text(verbatim: model.serverURL).textSelection(.enabled) }
                LabeledContent("help.version") { Text(verbatim: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") }
            }
            if model.phase == .signedIn { SettingsHubSections(model: hub) }
            if model.phase == .signedIn {
                Section { Button("logout", role: .destructive) { Task { await model.logout() } } }
            }
        }
        .formStyle(.grouped)
        .task { if model.phase == .signedIn { await hub.load(model) } }
        .frame(minWidth: 460, idealWidth: 460, minHeight: 480, idealHeight: 560)
    }
}
#endif

#if DEBUG && os(macOS)
#Preview("Settings light") { SettingsView().environment(AppModel()).preferredColorScheme(.light) }
#Preview("Settings dark") { SettingsView().environment(AppModel()).preferredColorScheme(.dark) }
#Preview("Settings accessibility5") { SettingsView().environment(AppModel()).dynamicTypeSize(.accessibility5) }
#endif

#if DEBUG
/// One invisible accessibility element with the outcome of `TODO_DEBUG_DELIVER_RESPONSE` (only present when requested).
private struct DebugProbeView: View {
    var body: some View {
        if DebugProbe.shared.enabled {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement().accessibilityLabel(Text(verbatim: DebugProbe.shared.status))
                .accessibilityIdentifier("debug.pushProbe")
        }
    }
}
#endif
