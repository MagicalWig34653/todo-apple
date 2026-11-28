import SwiftUI
import TodoCore

#Preview("Einstellungen, Light") {
    NavigationStack { List { SettingsHubSections(model: SettingsHubModel()) } }.environment(AppModel())
}

#Preview("Einstellungen, Dark") {
    NavigationStack { List { SettingsHubSections(model: SettingsHubModel()) } }.environment(AppModel()).preferredColorScheme(.dark)
}

#Preview("Einstellungen, accessibility5") {
    NavigationStack { List { SettingsHubSections(model: SettingsHubModel()) } }.environment(AppModel()).dynamicTypeSize(.accessibility5)
}

/// Settings hub like the PWA's settings: appearance, passkeys, sessions, connections (MCP clients), runner pairing.
/// One page of sections (no nested navigation), shared by the account screen on iPhone/iPad and the Mac settings window.
@MainActor @Observable
final class SettingsHubModel {
    var passkeys: [PasskeyInfo] = []
    var sessions: [AccountSession] = []
    var connections: [Connection] = []
    /// Card 80738AEA: own project groups and brain mandates (one per connection).
    var groups: [ProjectGroup] = []
    var mandates: [BrainMandate] = []
    /// Open sheets of the groups sections (`ProjectGroupsSheets` on the host).
    var editingGroup: GroupTarget?
    var editingSelection: SelectionTarget?
    var preferences: AccountPreferences?
    var pairing: RunnerPairing?
    var loaded = false
    var busy = false
    var errorKey: String?
    /// Server and account the values belong to; the Mac settings window stays alive across sign-outs.
    @ObservationIgnored private var account: String?

    private func forget() {
        passkeys = []; sessions = []; connections = []; groups = []; mandates = []
        editingGroup = nil; editingSelection = nil; preferences = nil; pairing = nil; loaded = false; errorKey = nil
    }

    func load(_ app: AppModel) async {
        guard let client = app.client else { return }
        let owner = app.serverURL + "|" + (app.user?.id.uuidString ?? "-")
        if account != owner { forget(); account = owner }
        let generation = app.sessionGeneration
        async let k = try? client.passkeys()
        async let s = try? client.sessions()
        async let c = try? client.connections()
        async let p = try? client.preferences()
        async let g = try? client.projectGroups()
        async let m = try? client.brainMandates()
        let (keys, sessions, connections, prefs) = await (k, s, c, p)
        let (groups, mandates) = await (g, m)
        guard generation == app.sessionGeneration else { return }
        passkeys = (keys ?? []).filter(\.isActive)
        self.sessions = (sessions ?? []).sortedCurrentFirst
        self.connections = (connections ?? []).active
        self.groups = groups ?? []
        self.mandates = mandates ?? []
        if let prefs { preferences = prefs; if prefs.revision > 0 { app.colorScheme = prefs.appearance.scheme } }
        loaded = true
    }

    /// Applies at once on this device and stores it in the account (shared with the PWA).
    func setScheme(_ scheme: ColorSchemeChoice, _ app: AppModel) async {
        app.colorScheme = scheme
        guard let client = app.client else { return }
        let base = preferences ?? AccountPreferences()
        do { preferences = try await client.savePreferences(base.withColorScheme(scheme)) }
        catch { errorKey = "settings.error.save" }
    }

    private func run(_ app: AppModel, _ work: (APIClient) async throws -> Void) async {
        guard let client = app.client, !busy else { return }
        busy = true; defer { busy = false }
        do { try await work(client) }
        catch is CancellationError { return }
        catch APIError.conflict { errorKey = "settings.passkeys.last" }
        catch { errorKey = AppModel.key(for: error) }
        await load(app)
    }

    func addPasskey(name: String, _ app: AppModel) async {
        await run(app) { try await $0.addPasskey(name: name, authenticator: PlatformPasskey()) }
    }
    func revokePasskey(_ k: PasskeyInfo, _ app: AppModel) async { await run(app) { try await $0.revokePasskey(k.id) } }
    func revokeSession(_ s: AccountSession, _ app: AppModel) async {
        if s.current { await app.logout(); return }
        await run(app) { try await $0.revokeSession(s.id) }
    }
    func revokeOtherSessions(_ app: AppModel) async { await run(app) { try await $0.revokeOtherSessions() } }
    func revokeConnection(_ c: Connection, _ app: AppModel) async { await run(app) { try await $0.revokeConnection(c.id) } }
    /// Mandates that moved to a newer connection stay only in the protocol (like the PWA).
    var listedMandates: [BrainMandate] { mandates.filter { $0.grantRevokedReason != "superseded" } }

    /// Saves with the rule (never a bare list, which would replace a group rule); returns an error key.
    func saveMandate(_ grantID: UUID, _ selection: ProjectSelection, _ app: AppModel) async -> String? {
        await write(app) { _ = try await $0.saveBrainMandate(grantID: grantID, selection: selection) }
    }
    func saveConnection(_ grantID: UUID, _ selection: ProjectSelection, _ app: AppModel) async -> String? {
        await write(app) { _ = try await $0.setConnectionSelection(grantID, selection) }
    }
    func revokeMandate(_ m: BrainMandate, _ app: AppModel) async {
        if let key = await write(app, { try await $0.revokeBrainMandate(grantID: m.grantID) }) { errorKey = key }
    }
    func apply(_ action: GroupAction, _ app: AppModel) async -> String? {
        await write(app) { client in
            switch action {
            case .create(let name, let ids): _ = try await client.createProjectGroup(name: name, projectIDs: ids)
            case .update(let g, let name, let ids): _ = try await client.updateProjectGroup(g.id, name: name, projectIDs: ids)
            case .delete(let g): _ = try await client.deleteProjectGroup(g.id)
            }
        }
    }

    /// Runs a write and reloads; the error key for the sheet that asked.
    private func write(_ app: AppModel, _ work: (APIClient) async throws -> Void) async -> String? {
        guard let client = app.client else { return "error.generic" }
        busy = true; defer { busy = false }
        do { try await work(client) }
        catch let error as APIError {
            await load(app)  // the lists may be stale (removed connection, deleted group)
            return SelectionSaveRules.errorKey(for: error) ?? AppModel.key(for: error)
        } catch { return AppModel.key(for: error) }
        await load(app)
        return nil
    }

    func pair(label: String, _ app: AppModel) async {
        guard let client = app.client, !busy else { return }
        busy = true; defer { busy = false }
        do { pairing = try await client.pairRunner(label: label) }
        catch { errorKey = AppModel.key(for: error) }
    }
}

/// The hub's sections; the host wraps them in a `List` (iOS) or a grouped `Form` (macOS settings window).
struct SettingsHubSections: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: SettingsHubModel
    @State private var newPasskeyName = ""
    @State private var askPasskeyName = false
    @State private var runnerLabel = ""
    @State private var confirmRevoke: Connection?

    private var schemeBinding: Binding<ColorSchemeChoice> {
        Binding(get: { app.colorScheme }, set: { s in Task { await model.setScheme(s, app) } })
    }

    var body: some View {
        Section {
            Picker("settings.appearance.scheme", selection: schemeBinding) {
                Text("settings.appearance.system").tag(ColorSchemeChoice.system)
                Text("settings.appearance.light").tag(ColorSchemeChoice.light)
                Text("settings.appearance.dark").tag(ColorSchemeChoice.dark)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.scheme")
        } header: { Text("settings.appearance") } footer: { Text("settings.appearance.hint") }

        NotificationSettingsSections()

        VoiceSettingsSection()

        Section {
            ForEach(model.passkeys) { k in
                LabeledContent {
                    if let d = k.createdAt { Text(d, format: .dateTime.day().month().year()) }
                } label: { Label { Text(verbatim: k.name) } icon: { Image(systemName: "person.badge.key") } }
                .swipeActions { Button("settings.revoke", role: .destructive) { Task { await model.revokePasskey(k, app) } } }
                .contextMenu { Button("settings.revoke", role: .destructive) { Task { await model.revokePasskey(k, app) } } }
            }
            Button { newPasskeyName = ""; askPasskeyName = true } label: { Label("settings.passkeys.add", systemImage: "plus") }
                .disabled(model.busy)
        } header: { Text("settings.passkeys") } footer: { Text("settings.passkeys.hint") }

        Section {
            ForEach(model.sessions) { s in
                HStack {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(s.current ? "settings.sessions.current" : "settings.sessions.other").font(.body)
                        if let d = s.createdAt {
                            Text("settings.sessions.since \(d.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(Color.textSecondary)
                        }
                    }
                    Spacer(minLength: Space.s)
                    if !s.current {
                        Button("settings.signOut", role: .destructive) { Task { await model.revokeSession(s, app) } }
                            .buttonStyle(.borderless).disabled(model.busy)
                    }
                }
            }
            if model.sessions.count > 1 {
                Button("settings.sessions.revokeOthers", role: .destructive) { Task { await model.revokeOtherSessions(app) } }
                    .disabled(model.busy)
            }
        } header: { Text("settings.sessions") }

        ProjectGroupsSettingsSections(model: model)

        Section {
            if model.loaded && model.connections.isEmpty { Text("settings.connections.empty").foregroundStyle(Color.textSecondary) }
            ForEach(model.connections) { c in
                HStack {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(verbatim: c.displayName.isEmpty ? String(localized: "settings.connections.unnamed") : c.displayName)
                        HStack(spacing: Space.s) {
                            if let summary = selectionSummary(c.selection, groups: model.groups) { Text(summary) }
                            Text("settings.connections.projects \(c.projectIDs.count)")
                            if let used = c.lastUsedAt { Text("settings.connections.used \(used.formatted(.relative(presentation: .named)))") }
                        }
                        .font(.caption).foregroundStyle(Color.textSecondary)
                    }
                    // One element for name and caption (the row holds two buttons, so it can no longer combine all of it).
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: Space.s)
                    Button("connection.projects.short") { model.editingSelection = .connection(c) }.buttonStyle(.borderless).disabled(model.busy)
                        .accessibilityIdentifier("connection.projects.\(c.displayName)")
                    Button("settings.revoke", role: .destructive) { confirmRevoke = c }.buttonStyle(.borderless).disabled(model.busy)
                }
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: Text("connection.projects")) { model.editingSelection = .connection(c) }
                .accessibilityAction(named: Text("settings.revoke")) { confirmRevoke = c }
            }
        } header: { Text("settings.connections") } footer: { Text("settings.connections.hint") }

        Section {
            if let p = model.pairing {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("settings.runner.code").font(.caption).foregroundStyle(Color.textSecondary)
                    Text(verbatim: p.code).font(.title2.monospaced().weight(.semibold)).textSelection(.enabled)
                        .accessibilityIdentifier("settings.runner.pairCode")
                    Text("settings.runner.expires \(p.expiresAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(Color.textSecondary)
                }
            }
            TextField(accessible: "settings.runner.label", text: $runnerLabel)
            Button("settings.runner.pair") { Task { await model.pair(label: runnerLabel, app) } }
                .disabled(model.busy || runnerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("settings.runner.pair")
            Button { app.selection = .runner } label: { Label("view.runner", systemImage: "terminal") }
        } header: { Text("settings.runner") } footer: { Text("settings.runner.hint") }
        .alert("settings.passkeys.add", isPresented: $askPasskeyName) {
            TextField(accessible: "settings.passkeys.name", text: $newPasskeyName)
            Button("settings.passkeys.create") { Task { await model.addPasskey(name: newPasskeyName, app) } }
            Button("cancel", role: .cancel) {}
        }
        .confirmationDialog("settings.connections.revokeTitle", isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }), titleVisibility: .visible) {
            Button("settings.revoke", role: .destructive) { if let c = confirmRevoke { Task { await model.revokeConnection(c, app) } }; confirmRevoke = nil }
        } message: { Text("settings.connections.revokeHint") }
        .alert(LocalizedStringKey(model.errorKey ?? ""), isPresented: Binding(get: { model.errorKey != nil }, set: { if !$0 { model.errorKey = nil } })) {
            Button("ok") {}
        }
    }
}
