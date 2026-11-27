import Foundation

// Card 80738AEA: project groups and rule selections (contracts/connections.yaml 1.8.0, oauth-mcp.yaml 1.13.0, ADR 0037).
// PLACEHOLDER for the red run: interface only.

public enum SelectionMode: String, Codable, Sendable, CaseIterable, Hashable { case selected, allExcept = "all_except" }

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

    public var isPlain: Bool { true }
    public var namesSomething: Bool { !projectIDs.isEmpty }
    public mutating func toggle(_ field: WritableKeyPath<ProjectSelection, [UUID]>, _ id: UUID) {}
    public mutating func setMode(_ mode: SelectionMode) { self.mode = mode }
    public func same(as other: ProjectSelection) -> Bool { self == other }
}

public struct ProjectGroup: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var projectIDs: [UUID]
    public init(id: UUID, name: String, projectIDs: [UUID]) { self.id = id; self.name = name; self.projectIDs = projectIDs }
}

public enum ProjectGroupName {
    public static func normalized(_ raw: String) -> String { raw }
    public static func problem(_ raw: String, groups: [ProjectGroup], selfID: UUID? = nil) -> String? { nil }
}

public struct SelectionChange: Codable, Sendable, Equatable {
    public let kind: String
    public let grantID: UUID
    public let name: String
    public let added: [UUID]
    public let removed: [UUID]
}

public struct ProjectGroupChangeResult: Codable, Sendable, Equatable {
    public let group: ProjectGroup?
    public let changes: [SelectionChange]
}

public struct ProjectGroupsOfProject: Codable, Sendable, Equatable {
    public let groupIDs: [UUID]
    public let changes: [SelectionChange]
}

public struct SelectionPreview: Codable, Sendable, Equatable {
    public let projectIDs: [UUID]
    public let agentCreatedProjectIDs: [UUID]
}

public struct BrainMandate: Codable, Sendable, Equatable, Identifiable {
    public let grantID: UUID
    public let grantName: String?
    public let projectIDs: [UUID]
    public let active: Bool
    public var id: UUID { grantID }
    public var editableSelection: ProjectSelection { ProjectSelection(projectIDs: projectIDs) }
}

extension Connection {
    public var selection: ProjectSelection? { nil }
    public var editableSelection: ProjectSelection { ProjectSelection(projectIDs: projectIDs) }
}

private let notYet = APIError.decoding("not implemented")

extension APIClient {
    public func projectGroups() async throws -> [ProjectGroup] { throw notYet }
    public func createProjectGroup(name: String, projectIDs: [UUID]) async throws -> ProjectGroupChangeResult { throw notYet }
    public func updateProjectGroup(_ id: UUID, name: String?, projectIDs: [UUID]?, dryRun: Bool = false) async throws -> ProjectGroupChangeResult { throw notYet }
    public func deleteProjectGroup(_ id: UUID) async throws -> [SelectionChange] { throw notYet }
    public func groupsOfProject(_ projectID: UUID) async throws -> [UUID] { throw notYet }
    public func setGroupsOfProject(_ projectID: UUID, groupIDs: [UUID], dryRun: Bool = false) async throws -> ProjectGroupsOfProject { throw notYet }
    public func previewSelection(_ selection: ProjectSelection) async throws -> SelectionPreview { throw notYet }
    public func brainMandates() async throws -> [BrainMandate] { throw notYet }
    public func saveBrainMandate(grantID: UUID, selection: ProjectSelection) async throws -> BrainMandate { throw notYet }
    public func revokeBrainMandate(grantID: UUID) async throws { throw notYet }
    public func setConnectionSelection(_ grantID: UUID, _ selection: ProjectSelection) async throws -> Connection { throw notYet }
}
