import Foundation

/// A project with its nested children, built from the flat server list.
public struct ProjectNode: Identifiable, Equatable, Sendable {
    public let project: Project
    /// nil for leaves (suits `List(_:children:)`).
    public let children: [ProjectNode]?
    public var id: UUID { project.id }
}

public enum ProjectTree {
    /// Builds a forest preserving input order. Projects whose parent is missing (or part of a cycle) become roots.
    public static func build(_ projects: [Project]) -> [ProjectNode] {
        let ids = Set(projects.map(\.id))
        let byParent = Dictionary(grouping: projects) { p -> UUID? in
            if let parent = p.parentID, ids.contains(parent), parent != p.id { return parent }
            return nil
        }
        var visited = Set<UUID>()
        func nodes(_ parent: UUID?) -> [ProjectNode] {
            (byParent[parent] ?? []).compactMap { p in
                guard visited.insert(p.id).inserted else { return nil }
                let kids = nodes(p.id)
                return ProjectNode(project: p, children: kids.isEmpty ? nil : kids)
            }
        }
        return nodes(nil)
    }
}
