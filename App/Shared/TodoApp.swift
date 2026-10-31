import SwiftUI

@main
struct TodoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("app.title") {
            RootView().environment(model).hapticHost().task { await model.start() }
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

    var body: some View {
        switch model.phase {
        case .launching: ProgressView()
        case .signedOut: LoginView()
        case .signedIn: MainView()
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

    var body: some View {
        Form {
            Section {
                LabeledContent("account.name") { Text(verbatim: model.user?.displayName ?? "–") }
                if let u = model.user?.username { LabeledContent("account.username") { Text(verbatim: u) } }
                LabeledContent("login.server") { Text(verbatim: model.serverURL).textSelection(.enabled) }
                LabeledContent("help.version") { Text(verbatim: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") }
            }
            if model.phase == .signedIn {
                Section { Button("logout", role: .destructive) { Task { await model.logout() } } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 300)
    }
}
#endif
