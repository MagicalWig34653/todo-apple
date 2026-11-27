import Foundation

// Card 80738AEA: project groups and rule selections (contracts/connections.yaml 1.8.0 `/v1/project-groups`,
// `/v1/projects/{id}/groups`, `/v1/project-selection/preview`, `x-project-selection`; oauth-mcp.yaml 1.13.0; ADR 0037).
// Person session only. A brain mandate or a connection selects projects by an explicit list plus an optional rule (groups,
// "all my projects except ..."). The trap: PUT without `selection` REPLACES a rule by the list. So the app always edits the
// explicit list plus the rule (`editableSelection`) and sends both (`selectionBody`); a plain list goes without `selection`
// (old meaning, also for older servers), exactly like the PWA (`web/src/lib/projectGroups.ts`).

public enum SelectionMode: String, Codable, Sendable, CaseIterable, Hashable { case selected, allExcept = "all_except" }

/// A choice of projects: the explicit projects plus the rule.
public struct ProjectSelection: Codable, Sendable, Equatable, Hashable {
    public var mode: SelectionMode
    public var projectIDs: [UUID]
    public var groupIDs: [UUID]
    public var excludedProjectIDs: [UUID]
    public var excludedGroupIDs: [UUID]

    public init(mode: SelectionMode = .selected, projectIDs: [UUID] = [], groupIDs: [UUID] = [], excludedProjectIDs: [UUID] = [], excludedGroupIDs: [UUID] = []) {
        self.mode = mode; self.projectIDs = projectIDs; self.groupIDs = groupIDs
        self.excludedProjectIDs = excludedProjectIDs; self.excludedGroupIDs = excludedGroupIDs
    }

    private enum CodingKeys: String, CodingKey { case mode, projectIDs, groupIDs, excludedProjectIDs, excludedGroupIDs }

    /// Absent arrays are empty; an unknown mode reads as `selected` (the server's default).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = SelectionMode(rawValue: try c.decodeIfPresent(String.self, forKey: .mode) ?? "") ?? .selected
        projectIDs = try c.decodeIfPresent([UUID].self, forKey: .projectIDs) ?? []
        groupIDs = try c.decodeIfPresent([UUID].self, forKey: .groupIDs) ?? []
        excludedProjectIDs = try c.decodeIfPresent([UUID].self, forKey: .excludedProjectIDs) ?? []
        excludedGroupIDs = try c.decodeIfPresent([UUID].self, forKey: .excludedGroupIDs) ?? []
    }

    /// Nothing beyond the explicit list (the server stores no rule for it).
    public var isPlain: Bool { mode == .selected && groupIDs.isEmpty && excludedProjectIDs.isEmpty && excludedGroupIDs.isEmpty }

    /// Whether the selection names anything at all (an empty group counts: it may get members).
    public var namesSomething: Bool { !projectIDs.isEmpty || !groupIDs.isEmpty || mode == .allExcept }

    public mutating func toggle(_ field: WritableKeyPath<ProjectSelection, [UUID]>, _ id: UUID) {
        if self[keyPath: field].contains(id) { self[keyPath: field].removeAll { $0 == id } } else { self[keyPath: field].append(id) }
    }

    /// Exclusions of the other mode would act unseen, so they start empty; explicit projects and groups stay.
    public mutating func setMode(_ mode: SelectionMode) {
        guard mode != self.mode else { return }
        self.mode = mode; excludedProjectIDs = []; excludedGroupIDs = []
    }

    /// Same choice regardless of order.
    public func same(as other: ProjectSelection) -> Bool {
        mode == other.mode && Set(projectIDs) == Set(other.projectIDs) && Set(groupIDs) == Set(other.groupIDs)
            && Set(excludedProjectIDs) == Set(other.excludedProjectIDs) && Set(excludedGroupIDs) == Set(other.excludedGroupIDs)
    }

    public func droppingUnknownProjects(known: Set<UUID>) -> ProjectSelection { self }

    /// Form state from a server answer: with a rule its own explicit list counts, otherwise `explicit`.
    public static func from(explicit: [UUID], rule: ProjectSelection?) -> ProjectSelection {
        rule ?? ProjectSelection(projectIDs: explicit)
    }

    /// The `selection` object of a request (the explicit list travels next to it); nil for a plain list.
    var ruleBody: RuleBody? {
        isPlain ? nil : RuleBody(mode: mode.rawValue, groupIDs: groupIDs, excludedProjectIDs: excludedProjectIDs, excludedGroupIDs: excludedGroupIDs)
    }

    struct RuleBody: Encodable { let mode: String; let groupIDs: [UUID]; let excludedProjectIDs: [UUID]; let excludedGroupIDs: [UUID] }
}

public struct ProjectGroup: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    /// Members the person can read now.
    public var projectIDs: [UUID]
    public init(id: UUID, name: String, projectIDs: [UUID]) { self.id = id; self.name = name; self.projectIDs = projectIDs }
}

/// Same rules as the server: 1 to 80 characters after trimming (inner runs of spaces collapse), unique per person ignoring case.
public enum ProjectGroupName {
    public static let maxLength = 80

    public static func normalized(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A localization key for the problem, nil when the name is fine.
    public static func problem(_ raw: String, groups: [ProjectGroup], selfID: UUID? = nil) -> String? {
        let name = normalized(raw)
        if name.isEmpty || name.count > maxLength { return "projectGroups.error.name" }
        if groups.contains(where: { $0.id != selfID && $0.name.lowercased() == name.lowercased() }) { return "projectGroups.error.taken" }
        return nil
    }
}

/// How a group change moves the reach of one brain mandate or connection of the person.
public struct SelectionChange: Codable, Sendable, Equatable, Hashable {
    /// `mandate` | `connection`
    public let kind: String
    public let grantID: UUID
    public let name: String
    public let added: [UUID]
    public let removed: [UUID]

    public init(kind: String, grantID: UUID, name: String, added: [UUID], removed: [UUID]) {
        self.kind = kind; self.grantID = grantID; self.name = name; self.added = added; self.removed = removed
    }
}

public struct ProjectGroupChangeResult: Codable, Sendable, Equatable {
    /// Absent after a delete.
    public let group: ProjectGroup?
    public let changes: [SelectionChange]
}

public struct ProjectGroupsOfProject: Codable, Sendable, Equatable {
    public let groupIDs: [UUID]
    public let changes: [SelectionChange]
}

public struct SelectionPreview: Codable, Sendable, Equatable {
    /// What the selection reaches now.
    public let projectIDs: [UUID]
    /// Own projects that "all" leaves out because a connection created them (or another person handed them over).
    public let agentCreatedProjectIDs: [UUID]

    public init(projectIDs: [UUID], agentCreatedProjectIDs: [UUID] = []) {
        self.projectIDs = projectIDs; self.agentCreatedProjectIDs = agentCreatedProjectIDs
    }

    private enum CodingKeys: String, CodingKey { case projectIDs, agentCreatedProjectIDs }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectIDs = try c.decodeIfPresent([UUID].self, forKey: .projectIDs) ?? []
        agentCreatedProjectIDs = try c.decodeIfPresent([UUID].self, forKey: .agentCreatedProjectIDs) ?? []
    }
}

/// PLACEHOLDER for the red run.
public enum SelectionSaveRules {
    public static func errorKey(for error: APIError) -> String? { nil }
    public static func canSave(_ selection: ProjectSelection, initial: ProjectSelection, allowsEmpty: Bool = false, isNewGrant: Bool = false) -> Bool { false }
}

/// Added and removed ids between two effective sets (order kept from the inputs).
public func selectionDiff(before: [UUID], after: [UUID]) -> (added: [UUID], removed: [UUID]) {
    let was = Set(before), will = Set(after)
    return (after.filter { !was.contains($0) }, before.filter { !will.contains($0) })
}

// MARK: Brain mandate (contracts/connections.yaml 1.2.0 to 1.8.0)

/// `BrainMandateDTO`: one per connection. `projectIDs` is what it covers now; `explicitProjectIDs` and `selection` (1.8.0)
/// are what the person chose.
public struct BrainMandate: Codable, Sendable, Equatable, Identifiable {
    public let grantID: UUID
    public let grantName: String?
    public let projectIDs: [UUID]
    public let explicitProjectIDs: [UUID]?
    public let selection: ProjectSelection?
    public let active: Bool
    public let createdAt: Date?
    public let updatedAt: Date?
    public let revokedAt: Date?
    public let lastUsedAt: Date?
    public let grantRevokedReason: String?

    public var id: UUID { grantID }

    public init(grantID: UUID, grantName: String?, projectIDs: [UUID], explicitProjectIDs: [UUID]? = nil, selection: ProjectSelection? = nil,
                active: Bool = true, createdAt: Date? = nil, updatedAt: Date? = nil, revokedAt: Date? = nil, lastUsedAt: Date? = nil,
                grantRevokedReason: String? = nil) {
        self.grantID = grantID; self.grantName = grantName; self.projectIDs = projectIDs; self.explicitProjectIDs = explicitProjectIDs
        self.selection = selection; self.active = active; self.createdAt = createdAt; self.updatedAt = updatedAt; self.revokedAt = revokedAt
        self.lastUsedAt = lastUsedAt; self.grantRevokedReason = grantRevokedReason
    }

    private enum CodingKeys: String, CodingKey {
        case grantID, grantName, projectIDs, explicitProjectIDs, selection, active, createdAt, updatedAt, revokedAt, lastUsedAt, grantRevokedReason
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grantID = try c.decode(UUID.self, forKey: .grantID)
        grantName = try c.decodeIfPresent(String.self, forKey: .grantName)
        projectIDs = try c.decodeIfPresent([UUID].self, forKey: .projectIDs) ?? []
        explicitProjectIDs = try c.decodeIfPresent([UUID].self, forKey: .explicitProjectIDs)
        selection = try c.decodeIfPresent(ProjectSelection.self, forKey: .selection)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        revokedAt = try c.decodeIfPresent(Date.self, forKey: .revokedAt)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        grantRevokedReason = try c.decodeIfPresent(String.self, forKey: .grantRevokedReason)
    }

    /// What the edit form starts from: the explicit list plus the rule, never the effective set.
    public var editableSelection: ProjectSelection { .from(explicit: explicitProjectIDs ?? projectIDs, rule: selection) }
}

private struct MandateBody: Encodable {
    let grantID: UUID
    let projectIDs: [UUID]
    let selection: ProjectSelection.RuleBody?
}

private struct GrantProjectsBody: Encodable {
    let projectIDs: [UUID]
    let selection: ProjectSelection.RuleBody?
    enum CodingKeys: String, CodingKey { case projectIDs = "project_ids", selection }
}

private struct PreviewBody: Encodable { let projectIDs: [UUID]; let selection: ProjectSelection.RuleBody? }
private struct GroupBody: Encodable { let name: String?; let projectIDs: [UUID]? }
private struct GroupIDsBody: Encodable { let groupIDs: [UUID] }
private struct GroupList: Decodable { let groups: [ProjectGroup] }
private struct DeleteResult: Decodable { let changes: [SelectionChange]? }
private struct MandateList: Decodable { let mandates: [BrainMandate] }

extension Connection {
    /// What the edit form starts from: the explicit list plus the rule, never the effective set.
    public var editableSelection: ProjectSelection { .from(explicit: explicitProjectIDs ?? projectIDs, rule: selection) }
}

extension APIClient {
    // MARK: Groups

    /// Own groups by name; members only the projects the person can read now.
    public func projectGroups() async throws -> [ProjectGroup] {
        let list: GroupList = try await send("GET", "v1/project-groups")
        return list.groups
    }

    public func createProjectGroup(name: String, projectIDs: [UUID]) async throws -> ProjectGroupChangeResult {
        try await send("POST", "v1/project-groups", body: GroupBody(name: ProjectGroupName.normalized(name), projectIDs: projectIDs))
    }

    /// `projectIDs` replaces the members; nil leaves them. `dryRun` computes the changes without saving.
    public func updateProjectGroup(_ id: UUID, name: String?, projectIDs: [UUID]?, dryRun: Bool = false) async throws -> ProjectGroupChangeResult {
        try await send("PATCH", "v1/project-groups/\(id.uuidString)", query: dryRun ? [URLQueryItem(name: "dryRun", value: "true")] : [],
                       body: GroupBody(name: name.map(ProjectGroupName.normalized), projectIDs: projectIDs))
    }

    /// Takes the group's projects out of every selection that includes it; the changes say where.
    public func deleteProjectGroup(_ id: UUID) async throws -> [SelectionChange] {
        let result: DeleteResult = try await send("DELETE", "v1/project-groups/\(id.uuidString)")
        return result.changes ?? []
    }

    public func groupsOfProject(_ projectID: UUID) async throws -> [UUID] {
        let result: ProjectGroupsOfProject = try await send("GET", "v1/projects/\(projectID.uuidString)/groups")
        return result.groupIDs
    }

    public func setGroupsOfProject(_ projectID: UUID, groupIDs: [UUID], dryRun: Bool = false) async throws -> ProjectGroupsOfProject {
        try await send("PUT", "v1/projects/\(projectID.uuidString)/groups", query: dryRun ? [URLQueryItem(name: "dryRun", value: "true")] : [],
                       body: GroupIDsBody(groupIDs: groupIDs))
    }

    /// What the selection reaches now, computed by the server (the same resolution as its checks); saves nothing.
    public func previewSelection(_ selection: ProjectSelection) async throws -> SelectionPreview {
        try await send("POST", "v1/project-selection/preview", body: PreviewBody(projectIDs: selection.projectIDs, selection: selection.ruleBody))
    }

    // MARK: Brain mandates

    /// One per connection that ever got one, newest first.
    public func brainMandates() async throws -> [BrainMandate] {
        let list: MandateList = try await send("GET", "v1/settings/brain-mandate")
        return list.mandates
    }

    /// Gives or overwrites the mandate of this connection only. Sends the rule whenever there is one.
    public func saveBrainMandate(grantID: UUID, selection: ProjectSelection) async throws -> BrainMandate {
        try await send("PUT", "v1/settings/brain-mandate", body: MandateBody(grantID: grantID, projectIDs: selection.projectIDs, selection: selection.ruleBody))
    }

    public func revokeBrainMandate(grantID: UUID) async throws {
        try await sendNoContent("DELETE", "v1/settings/brain-mandate/\(grantID.uuidString)")
    }

    // MARK: Connections

    /// Replaces the projects of a connection. Sends the rule whenever there is one.
    public func setConnectionSelection(_ grantID: UUID, _ selection: ProjectSelection) async throws -> Connection {
        try await send("PUT", "oauth/grants/\(grantID.uuidString)/projects",
                       body: GrantProjectsBody(projectIDs: selection.projectIDs, selection: selection.ruleBody))
    }
}
