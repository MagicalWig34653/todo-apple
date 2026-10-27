import SwiftUI
import TodoCore

struct TeamsView: View {
    @Environment(AppModel.self) private var model
    @State private var newTeam = ""

    var body: some View {
        List {
            if !model.teamInvitations.isEmpty {
                Section("teams.invitations") {
                    ForEach(model.teamInvitations) { invitation in
                        HStack {
                            Text(verbatim: invitation.teamName ?? "")
                            Spacer()
                            Button("teams.accept") { Task { await accept(invitation) } }
                        }
                    }
                }
            }
            Section("view.teams") {
                ForEach(model.teams) { team in
                    NavigationLink { TeamMembersView(team: team) } label: { Text(verbatim: team.name) }
                }
                TextField("teams.new", text: $newTeam).onSubmit { Task { await create() } }
            }
        }
        .navigationTitle("view.teams")
        .refreshable { await model.reloadTeams() }
        .task { await model.reloadTeams() }
    }

    private func create() async {
        let name = newTeam.trimmingCharacters(in: .whitespaces)
        newTeam = ""
        guard let client = model.client, !name.isEmpty else { return }
        do { _ = try await client.createTeam(name: name); await model.reloadTeams() } catch { await model.handle(error) }
    }

    private func accept(_ invitation: TeamMembership) async {
        guard let client = model.client else { return }
        do { try await client.acceptTeamInvitation(teamID: invitation.teamID); await model.reloadTeams() } catch { await model.handle(error) }
    }
}

struct TeamMembersView: View {
    @Environment(AppModel.self) private var model
    let team: Team
    @State private var members: [TeamMembership] = []
    @State private var query = ""
    @State private var found: [DirectoryUser] = []

    var body: some View {
        List {
            Section("teams.members") {
                ForEach(members) { m in
                    HStack {
                        Text(verbatim: m.displayName ?? "?")
                        Spacer()
                        if m.isAdmin { Text("teams.admin").font(.caption).foregroundStyle(.secondary) }
                        if !m.accepted { Text("teams.pending").font(.caption).foregroundStyle(.secondary) }
                    }
                    .swipeActions {
                        Button("teams.remove", role: .destructive) { Task { await remove(m) } }
                    }
                }
            }
            Section("teams.invite") {
                TextField("users.search", text: $query).onSubmit { Task { await search() } }
                ForEach(found) { u in
                    Button { Task { await invite(u) } } label: { Text(verbatim: u.displayName) }
                }
            }
        }
        .navigationTitle(team.name)
        .task { await reload() }
    }

    private func reload() async {
        guard let client = model.client else { return }
        do { members = try await client.members(teamID: team.id) } catch { await model.handle(error) }
    }

    private func search() async {
        guard let client = model.client, query.trimmingCharacters(in: .whitespaces).count >= 2 else { return }
        do { found = try await client.searchUsers(query.trimmingCharacters(in: .whitespaces), limit: 10) } catch { await model.handle(error) }
    }

    private func invite(_ user: DirectoryUser) async {
        guard let client = model.client else { return }
        do { _ = try await client.inviteMember(teamID: team.id, userID: user.id); found = []; query = ""; await reload() }
        catch { await model.handle(error) }
    }

    private func remove(_ m: TeamMembership) async {
        guard let client = model.client else { return }
        do { try await client.removeMember(teamID: team.id, userID: m.userID); await reload() } catch { await model.handle(error) }
    }
}

/// Project sharing: grants for people and teams, role per grant, inheritance switch.
struct ShareView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var grants: [ProjectGrant] = []
    @State private var visibility: EffectiveVisibility?
    @State private var query = ""
    @State private var found: [DirectoryUser] = []
    @State private var role: ShareRole = .read

    private func name(of grant: ProjectGrant) -> String {
        switch grant.principalType {
        case .team: model.teams.first { $0.id == grant.principalID }?.name ?? "—"
        case .person: grant.principalID == model.user?.id ? (model.user?.displayName ?? "—") : "—"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("share.grants") {
                    ForEach(grants) { g in
                        HStack {
                            Image(systemName: g.principalType == .team ? "person.2" : "person")
                            Text(verbatim: name(of: g))
                            Spacer()
                            Text(LocalizedStringKey("role.\(g.role.rawValue)")).foregroundStyle(.secondary)
                        }
                        .swipeActions { Button("share.remove", role: .destructive) { Task { await remove(g) } } }
                    }
                }
                Section("share.add") {
                    Picker("share.role", selection: $role) {
                        ForEach(ShareRole.allCases, id: \.self) { Text(LocalizedStringKey("role.\($0.rawValue)")).tag($0) }
                    }
                    ForEach(model.teams) { team in
                        Button { Task { await add(.team, team.id) } } label: { Label { Text(verbatim: team.name) } icon: { Image(systemName: "person.2") } }
                    }
                    TextField("users.search", text: $query).onSubmit { Task { await search() } }
                    ForEach(found) { u in
                        Button { Task { await add(.person, u.id) } } label: { Label { Text(verbatim: u.displayName) } icon: { Image(systemName: "person") } }
                    }
                }
                if let v = visibility {
                    Section {
                        Toggle("share.inherits", isOn: Binding(get: { v.inherits }, set: { on in Task { await setInherits(on) } }))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(project.name)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("done") { dismiss() } } }
            .task { await model.reloadTeams(); await reload() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func reload() async {
        guard let client = model.client else { return }
        do {
            grants = try await client.grants(projectID: project.id)
            visibility = try await client.visibility(projectID: project.id)
        } catch { await model.handle(error) }
    }

    private func search() async {
        guard let client = model.client, query.trimmingCharacters(in: .whitespaces).count >= 2 else { return }
        do { found = try await client.searchUsers(query.trimmingCharacters(in: .whitespaces), limit: 10) } catch { await model.handle(error) }
    }

    private func add(_ type: PrincipalType, _ id: UUID) async {
        guard let client = model.client else { return }
        do { _ = try await client.setGrant(projectID: project.id, principalType: type, principalID: id, role: role); found = []; query = ""; await reload() }
        catch { await model.handle(error) }
    }

    private func remove(_ g: ProjectGrant) async {
        guard let client = model.client else { return }
        do { try await client.removeGrant(projectID: project.id, grantID: g.id); await reload() } catch { await model.handle(error) }
    }

    private func setInherits(_ on: Bool) async {
        guard let client = model.client else { return }
        // Inheritance changes bump the project version; use the latest known one.
        let version = model.projects.first { $0.id == project.id }?.version ?? project.version
        do { visibility = try await client.setInheritance(projectID: project.id, version: version, inherits: on); await model.reload() }
        catch { await model.handle(error); await reload() }
    }
}
