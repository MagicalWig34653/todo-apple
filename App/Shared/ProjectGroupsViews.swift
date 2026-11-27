import SwiftUI
import TodoCore

// Card 80738AEA: project groups in the app (contracts/connections.yaml 1.8.0, ADR 0037). Settings: groups (create, rename,
// members), brain mandates and connections with groups and "all except ..." plus a live preview computed by the server;
// project settings and new projects: choose groups. Every save of a mandate or connection sends the rule (`ProjectSelection`).

#Preview("Auswahl, Light") { SelectionEditorPreviewHost() }
#Preview("Auswahl, Dark") { SelectionEditorPreviewHost().preferredColorScheme(.dark) }
#Preview("Auswahl, accessibility5") { SelectionEditorPreviewHost().dynamicTypeSize(.accessibility5) }
#Preview("Gruppe, Light") { ProjectGroupEditor(group: SelectionSamples.groups[0], groups: SelectionSamples.groups, projects: SelectionSamples.projects) { _ in nil } }
#Preview("Gruppe, Dark") { ProjectGroupEditor(group: SelectionSamples.groups[0], groups: SelectionSamples.groups, projects: SelectionSamples.projects) { _ in nil }.preferredColorScheme(.dark) }
#Preview("Gruppe, accessibility5") { ProjectGroupEditor(group: nil, groups: SelectionSamples.groups, projects: SelectionSamples.projects) { _ in nil }.dynamicTypeSize(.accessibility5) }

/// Display name per project: the parent path makes equal names distinguishable (like the PWA's `projectLabels`).
func projectLabels(_ projects: [Project]) -> [UUID: String] {
    let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var labels: [UUID: String] = [:]
    for p in projects {
        var parts = [p.name], seen: Set<UUID> = [p.id], parent = p.parentID.flatMap { byID[$0] }
        while let up = parent, !seen.contains(up.id) { parts.insert(up.name, at: 0); seen.insert(up.id); parent = up.parentID.flatMap { byID[$0] } }
        labels[p.id] = parts.joined(separator: " / ")
    }
    return labels
}

/// One line about a rule: "Alle eigenen Projekte außer 2" or "Gruppen: Kunden"; nil for a plain list.
func selectionSummary(_ s: ProjectSelection?, groups: [ProjectGroup]) -> LocalizedStringKey? {
    guard let s, !s.isPlain else { return nil }
    if s.mode == .allExcept { return "selection.summary.allExcept \(s.excludedProjectIDs.count + s.excludedGroupIDs.count)" }
    let names = s.groupIDs.compactMap { id in groups.first { $0.id == id }?.name }.sorted().joined(separator: ", ")
    return "selection.summary.groups \(names)"
}

// MARK: Settings sections

/// What a sheet of the settings edits.
enum SelectionTarget: Identifiable {
    case mandate(BrainMandate)
    case newMandate(Connection)
    case connection(Connection)

    var id: String {
        switch self {
        case .mandate(let m): "m-\(m.grantID)"
        case .newMandate(let c): "n-\(c.id)"
        case .connection(let c): "c-\(c.id)"
        }
    }
}

enum GroupTarget: Identifiable {
    case new, existing(ProjectGroup)
    var id: String { if case .existing(let g) = self { g.id.uuidString } else { "new" } }
    var group: ProjectGroup? { if case .existing(let g) = self { g } else { nil } }
}

/// Groups and brain mandates inside the settings hub (iPhone/iPad account screen and the Mac settings window).
struct ProjectGroupsSettingsSections: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: SettingsHubModel

    private var mandateCandidates: [Connection] {
        let given = Set(model.mandates.filter(\.active).map(\.grantID))
        return model.connections.filter { !given.contains($0.id) }
    }

    var body: some View {
        Section {
            if model.loaded && model.groups.isEmpty { Text("projectGroups.empty").foregroundStyle(Color.textSecondary) }
            ForEach(model.groups) { g in
                Button { model.editingGroup = .existing(g) } label: {
                    LabeledContent {
                        Text("settings.connections.projects \(g.projectIDs.count)")
                    } label: { Label { Text(verbatim: g.name).lineLimit(2) } icon: { Image(systemName: "square.stack.3d.up") } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("group.row.\(g.name)")
            }
            Button { model.editingGroup = .new } label: { Label("projectGroups.new", systemImage: "plus") }
                .disabled(model.busy)
                .accessibilityIdentifier("group.new")
        } header: { Text("projectGroups") } footer: { Text("projectGroups.hint") }

        Section {
            if model.loaded && model.listedMandates.isEmpty { Text("mandate.empty").foregroundStyle(Color.textSecondary) }
            ForEach(model.listedMandates) { m in
                Button { model.editingSelection = .mandate(m) } label: { MandateRow(mandate: m, groups: model.groups).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    // The server refuses a mandate for a removed connection (409 grant_revoked).
                    .disabled(!model.connections.contains { $0.id == m.grantID })
                    .accessibilityIdentifier("mandate.row.\(m.grantName ?? "")")
                    .swipeActions { if m.active { Button("mandate.revoke", role: .destructive) { Task { await model.revokeMandate(m, app) } } } }
                    .contextMenu { if m.active { Button("mandate.revoke", role: .destructive) { Task { await model.revokeMandate(m, app) } } } }
            }
            if !mandateCandidates.isEmpty {
                Menu {
                    ForEach(mandateCandidates) { c in
                        Button { model.editingSelection = .newMandate(c) } label: { Text(verbatim: c.displayName.isEmpty ? String(localized: "settings.connections.unnamed") : c.displayName) }
                    }
                } label: { Label("mandate.give", systemImage: "checkmark.seal") }
                .accessibilityIdentifier("mandate.give")
            }
        } header: { Text("mandate") } footer: { Text("mandate.hint") }
    }
}

/// The sheets of the groups sections. Attached to the host (`List`/`Form`), not to a lazy `Section`, where a sheet may never
/// present (first tour run: tapping a group row opened nothing).
struct ProjectGroupsSheets: ViewModifier {
    @Environment(AppModel.self) private var app
    @Bindable var model: SettingsHubModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.editingGroup) { target in
                ProjectGroupEditor(group: target.group, groups: model.groups, projects: app.projects) { action in
                    await model.apply(action, app)
                }
                .environment(app).tint(.brand)
            }
            .sheet(item: $model.editingSelection) { target in
                selectionSheet(target).environment(app).tint(.brand)
            }
    }

    @ViewBuilder private func selectionSheet(_ target: SelectionTarget) -> some View {
        switch target {
        case .mandate(let m):
            SelectionEditor(title: "mandate.edit", subject: m.grantName ?? "", groups: model.groups, projects: app.projects,
                            initial: m.editableSelection, before: m.active ? m.projectIDs : [], isNewGrant: !m.active) { s in
                await model.saveMandate(m.grantID, s, app)
            }
        case .newMandate(let c):
            SelectionEditor(title: "mandate.give", subject: c.displayName, groups: model.groups, projects: app.projects,
                            initial: ProjectSelection(), before: []) { s in
                await model.saveMandate(c.id, s, app)
            }
        case .connection(let c):
            SelectionEditor(title: "connection.projects", subject: c.displayName, groups: model.groups, projects: app.projects,
                            initial: c.editableSelection, before: c.projectIDs, allowsEmpty: c.scopes.contains("projects:write")) { s in
                await model.saveConnection(c.id, s, app)
            }
        }
    }
}

private struct MandateRow: View {
    let mandate: BrainMandate
    let groups: [ProjectGroup]

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(verbatim: mandate.grantName ?? String(localized: "settings.connections.unnamed")).lineLimit(2)
                AdaptiveStack(spacing: Space.s) {
                    if let summary = selectionSummary(mandate.selection, groups: groups) { Text(summary) }
                    Text("settings.connections.projects \(mandate.projectIDs.count)")
                }
                .font(.caption).foregroundStyle(Color.textSecondary)
            }
            Spacer(minLength: Space.s)
            Text(mandate.active ? "mandate.active" : "mandate.revoked")
                .font(.caption.weight(.semibold))
                .foregroundStyle(mandate.active ? Color.brand : Color.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Selection editor

/// Choice of projects for a brain mandate or a connection: explicit projects and groups, or "all my projects except ...".
/// Shows what the choice reaches now (computed by the server, `/v1/project-selection/preview`) and what a save would change.
struct SelectionEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let subject: String
    let groups: [ProjectGroup]
    let projects: [Project]
    let initial: ProjectSelection
    /// What is in effect now; the preview lists what a save adds and removes.
    let before: [UUID]
    var allowsEmpty = false
    /// A revoked mandate given again: saving the unchanged selection is allowed.
    var isNewGrant = false
    /// Returns an error key, nil on success.
    let save: (ProjectSelection) async -> String?
    /// Previews and screenshots without a server.
    var fixedPreview: SelectionPreview?

    @State private var selection = ProjectSelection()
    @State private var started = false
    @State private var preview: SelectionPreview?
    /// The selection that `preview` (nil: the request failed) answers; anything else is still pending.
    @State private var answered: ProjectSelection?
    @State private var saving = false
    @State private var errorKey: String?

    private var labels: [UUID: String] { projectLabels(projects) }
    private func names(_ ids: [UUID]) -> String {
        ids.map { labels[$0] ?? String($0.uuidString.prefix(8)).lowercased() }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", ")
    }
    private var sortedProjects: [Project] { projects.sorted { (labels[$0.id] ?? $0.name).localizedStandardCompare(labels[$1.id] ?? $1.name) == .orderedAscending } }
    private var previewPending: Bool { answered != selection }
    private var canSave: Bool { !saving && !previewPending && SelectionSaveRules.canSave(selection, initial: initial, allowsEmpty: allowsEmpty, isNewGrant: isNewGrant) }

    var body: some View {
        NavigationStack {
            Form {
                if !subject.isEmpty {
                    Section { LabeledContent("selection.for") { Text(verbatim: subject).lineLimit(2) } }
                }
                Section {
                    Picker("selection.mode", selection: Binding(get: { selection.mode }, set: { selection.setMode($0) })) {
                        Text("selection.mode.selected").tag(SelectionMode.selected)
                        Text("selection.mode.allExcept").tag(SelectionMode.allExcept)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("selection.mode")
                } footer: { Text(selection.mode == .allExcept ? "selection.mode.allExcept.hint" : "selection.mode.selected.hint") }

                previewSection

                if selection.mode == .selected {
                    if !groups.isEmpty { checks("selection.groups", groups.map { ($0.id, $0.name, "group") }, \.groupIDs) }
                    checks("selection.projects", sortedProjects.map { ($0.id, labels[$0.id] ?? $0.name, "project") }, \.projectIDs)
                } else {
                    if !groups.isEmpty { checks("selection.excludedGroups", groups.map { ($0.id, $0.name, "group") }, \.excludedGroupIDs) }
                    checks("selection.excludedProjects", sortedProjects.map { ($0.id, labels[$0.id] ?? $0.name, "project") }, \.excludedProjectIDs)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() }.accessibilityIdentifier("sheet.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") {
                        Task {
                            saving = true; defer { saving = false }
                            if let key = await save(selection) { errorKey = key } else { dismiss() }
                        }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("selection.save")
                }
            }
            .task(id: selection) { await refreshPreview() }
            .onAppear { if !started { selection = initial.droppingUnknownProjects(known: Set(projects.map(\.id))); started = true } }
            .alert(LocalizedStringKey(errorKey ?? ""), isPresented: Binding(get: { errorKey != nil }, set: { if !$0 { errorKey = nil } })) { Button("ok") {} }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 680)
        #endif
    }

    @ViewBuilder private var previewSection: some View {
        Section {
            if previewPending {
                HStack(spacing: Space.s) { ProgressView(); Text("selection.preview.loading").foregroundStyle(Color.textSecondary) }
            } else if let preview {
                Text("selection.preview.count \(preview.projectIDs.count)")
                    .font(.headline)
                    .accessibilityIdentifier("selection.preview.count")
                if !preview.projectIDs.isEmpty {
                    Text(verbatim: names(preview.projectIDs)).font(.subheadline).foregroundStyle(Color.textSecondary).lineLimit(4)
                }
                let diff = selectionDiff(before: before, after: preview.projectIDs)
                if !diff.added.isEmpty {
                    Label { Text("selection.preview.added \(names(diff.added))").lineLimit(3) } icon: { Image(systemName: "plus.circle") }
                        .font(.subheadline).foregroundStyle(Color.brand)
                }
                if !diff.removed.isEmpty {
                    Label { Text("selection.preview.removed \(names(diff.removed))").lineLimit(3) } icon: { Image(systemName: "minus.circle") }
                        .font(.subheadline).foregroundStyle(Color.textSecondary)
                }
                if selection.mode == .allExcept && !preview.agentCreatedProjectIDs.isEmpty {
                    Text("selection.preview.agentCreated \(names(preview.agentCreatedProjectIDs))").font(.caption).foregroundStyle(Color.textSecondary)
                }
            } else {
                Text("selection.preview.failed").foregroundStyle(Color.textSecondary)
            }
        } header: { Text("selection.preview") }
    }

    private func checks(_ header: LocalizedStringKey, _ rows: [(UUID, String, String)], _ field: WritableKeyPath<ProjectSelection, [UUID]>) -> some View {
        Section {
            ForEach(rows, id: \.0) { id, name, kind in
                Toggle(isOn: Binding(get: { selection[keyPath: field].contains(id) }, set: { _ in selection.toggle(field, id) })) {
                    Text(verbatim: name).lineLimit(2)
                }
                .accessibilityIdentifier("selection.\(kind).\(name)")
            }
        } header: { Text(header) }
    }

    private func refreshPreview() async {
        let asked = selection
        if let fixedPreview { preview = fixedPreview; answered = asked; return }
        guard started, let client = app.client else { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let result = try? await client.previewSelection(asked)
        guard !Task.isCancelled else { return }
        preview = result; answered = asked
    }
}

// MARK: Group editor

enum GroupAction {
    case create(name: String, projectIDs: [UUID])
    case update(ProjectGroup, name: String?, projectIDs: [UUID]?)
    case delete(ProjectGroup)
}

/// Create or edit one group: name and members. Members are projects the person can read; no inheritance to subprojects.
struct ProjectGroupEditor: View {
    @Environment(\.dismiss) private var dismiss
    let group: ProjectGroup?
    let groups: [ProjectGroup]
    let projects: [Project]
    /// Returns an error key, nil on success.
    let apply: (GroupAction) async -> String?

    @State private var name = ""
    @State private var members: Set<UUID> = []
    @State private var started = false
    @State private var saving = false
    @State private var errorKey: String?
    @State private var confirmDelete = false

    private var labels: [UUID: String] { projectLabels(projects) }
    private var problem: String? { ProjectGroupName.problem(name, groups: groups, selfID: group?.id) }
    private var changed: Bool {
        guard let group else { return true }
        return ProjectGroupName.normalized(name) != group.name || members != Set(group.projectIDs)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(accessible: "projectGroups.name", text: $name)
                        .accessibilityIdentifier("group.name")
                    if !name.isEmpty, let problem { Text(LocalizedStringKey(problem)).font(.caption).foregroundStyle(Color.textSecondary) }
                } footer: { Text("projectGroups.name.hint") }
                Section {
                    ForEach(projects.sorted { (labels[$0.id] ?? "").localizedStandardCompare(labels[$1.id] ?? "") == .orderedAscending }) { p in
                        let label = labels[p.id] ?? p.name
                        Toggle(isOn: Binding(get: { members.contains(p.id) }, set: { on in if on { members.insert(p.id) } else { members.remove(p.id) } })) {
                            Text(verbatim: label).lineLimit(2)
                        }
                        .accessibilityIdentifier("group.member.\(label)")
                    }
                } header: { Text("projectGroups.members \(members.count)") } footer: { Text("projectGroups.members.hint") }
                if let group {
                    Section {
                        Button("projectGroups.delete", role: .destructive) { confirmDelete = true }
                            .confirmationDialog("projectGroups.delete", isPresented: $confirmDelete, titleVisibility: .visible) {
                                Button("projectGroups.delete", role: .destructive) { run(.delete(group)) }
                            } message: { Text("projectGroups.delete.hint") }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(group == nil ? "projectGroups.new" : "projectGroups.edit")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() }.accessibilityIdentifier("sheet.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") {
                        if let group {
                            let n = ProjectGroupName.normalized(name)
                            run(.update(group, name: n == group.name ? nil : n, projectIDs: members == Set(group.projectIDs) ? nil : Array(members)))
                        } else { run(.create(name: name, projectIDs: Array(members))) }
                    }
                    .disabled(saving || problem != nil || !changed)
                    .accessibilityIdentifier("group.save")
                }
            }
            .onAppear {
                guard !started else { return }
                name = group?.name ?? ""; members = Set(group?.projectIDs ?? []); started = true
            }
            .alert(LocalizedStringKey(errorKey ?? ""), isPresented: Binding(get: { errorKey != nil }, set: { if !$0 { errorKey = nil } })) { Button("ok") {} }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 640)
        #endif
    }

    private func run(_ action: GroupAction) {
        Task {
            saving = true; defer { saving = false }
            if let key = await apply(action) { errorKey = key } else { dismiss() }
        }
    }
}

// MARK: Project: its groups

/// Project settings ("…" menu) and the new-project sheet: the person's own groups this project belongs to.
struct ProjectGroupsOfProjectSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var groups: [ProjectGroup] = []
    @State private var chosen: Set<UUID> = []
    @State private var initial: Set<UUID> = []
    @State private var loaded = false
    @State private var errorKey: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if loaded && groups.isEmpty { Text("projectGroups.noneYet").foregroundStyle(Color.textSecondary) }
                    GroupChecks(groups: groups, chosen: $chosen)
                } header: { Text(verbatim: project.name) } footer: { Text("project.groups.hint") }
            }
            .formStyle(.grouped)
            .navigationTitle("project.groups")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() }.accessibilityIdentifier("sheet.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") {
                        Task {
                            guard let client = app.client else { return }
                            do { _ = try await client.setGroupsOfProject(project.id, groupIDs: Array(chosen)); dismiss() }
                            catch { errorKey = AppModel.key(for: error) }
                        }
                    }
                    .disabled(!loaded || chosen == initial)
                    .accessibilityIdentifier("project.groups.save")
                }
            }
            .task {
                guard let client = app.client else { return }
                do {
                    async let g = client.projectGroups()
                    async let mine = client.groupsOfProject(project.id)
                    (groups, initial) = (try await g, Set(try await mine))
                    chosen = initial
                } catch { errorKey = AppModel.key(for: error) }
                loaded = true
            }
            .alert(LocalizedStringKey(errorKey ?? ""), isPresented: Binding(get: { errorKey != nil }, set: { if !$0 { errorKey = nil } })) { Button("ok") {} }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 440)
        #endif
    }
}

struct GroupChecks: View {
    let groups: [ProjectGroup]
    @Binding var chosen: Set<UUID>

    var body: some View {
        ForEach(groups) { g in
            Toggle(isOn: Binding(get: { chosen.contains(g.id) }, set: { on in if on { chosen.insert(g.id) } else { chosen.remove(g.id) } })) {
                Text(verbatim: g.name).lineLimit(2)
            }
            .accessibilityIdentifier("project.group.\(g.name)")
        }
    }
}

/// New project: name and, when the person has groups, the groups it joins.
struct NewProjectSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let parentID: UUID?
    @State private var name = ""
    @State private var groups: [ProjectGroup] = []
    @State private var chosen: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField(accessible: "project.name", text: $name).accessibilityIdentifier("project.new.name") }
                if !groups.isEmpty {
                    Section { GroupChecks(groups: groups, chosen: $chosen) } header: { Text("project.groups") } footer: { Text("project.groups.hint") }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("project.new")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() }.accessibilityIdentifier("sheet.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") {
                        let n = name, g = Array(chosen), parent = parentID
                        dismiss()
                        Task { await app.addProject(name: n, parentID: parent, groupIDs: g) }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("project.new.save")
                }
            }
            .task { if let client = app.client { groups = (try? await client.projectGroups()) ?? [] } }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 300, idealHeight: 380)
        #endif
    }
}

// MARK: Samples (previews and Mac renders without a server)

enum SelectionSamples {
    static let projects: [Project] = ["Website-Relaunch", "Umzug", "Steuer 2026", "Garten"].enumerated().map { i, name in
        Project(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(i + 1)")!, parentID: nil, name: name, version: 1)
    }
    static let groups = [
        ProjectGroup(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, name: "Kunden", projectIDs: [projects[0].id, projects[2].id]),
        ProjectGroup(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, name: "Privat", projectIDs: [projects[1].id, projects[3].id]),
    ]
}

struct SelectionEditorPreviewHost: View {
    var body: some View {
        SelectionEditor(title: "mandate.edit", subject: "Brain", groups: SelectionSamples.groups, projects: SelectionSamples.projects,
                        initial: ProjectSelection(projectIDs: [SelectionSamples.projects[1].id], groupIDs: [SelectionSamples.groups[0].id]),
                        before: [SelectionSamples.projects[1].id], save: { _ in nil },
                        fixedPreview: SelectionPreview(projectIDs: [SelectionSamples.projects[0].id, SelectionSamples.projects[1].id, SelectionSamples.projects[2].id]))
            .environment(AppModel())
    }
}
