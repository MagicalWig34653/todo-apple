import XCTest
@testable import TodoCore

/// Card 80738AEA: project groups (contracts/connections.yaml 1.8.0, ADR 0037) and rule selections of brain mandates and
/// connections (oauth-mcp.yaml 1.13.0). The trap: PUT /v1/settings/brain-mandate and PUT /oauth/grants/{id}/projects
/// without `selection` replace a group rule by the list. The app must always edit the explicit list plus the rule and send both.
final class ProjectGroupsTests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let g1 = UUID(), g2 = UUID(), p1 = UUID(), p2 = UUID(), p3 = UUID(), grant = UUID()

    override func setUp() {
        MockURLProtocol.seen = []
        MockURLProtocol.handler = nil
        try? store.save("tok")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: URL(string: "http://test.invalid")!, session: URLSession(configuration: config), tokenStore: store)
    }

    private func reply(_ s: String) { MockURLProtocol.handler = { _ in (200, Data(s.utf8)) } }
    private var last: URLRequest { MockURLProtocol.seen.last! }
    private func body(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
    }
    private func ids(_ any: Any?) -> Set<UUID> { Set(((any as? [String]) ?? []).compactMap(UUID.init(uuidString:))) }
    private func ruleJSON(mode: String = "selected", projects: [UUID] = [], groups: [UUID] = [], excluded: [UUID] = [], excludedGroups: [UUID] = []) -> String {
        func list(_ l: [UUID]) -> String { "[" + l.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
        return #"{"mode":"\#(mode)","projectIDs":\#(list(projects)),"groupIDs":\#(list(groups)),"excludedProjectIDs":\#(list(excluded)),"excludedGroupIDs":\#(list(excludedGroups))}"#
    }

    // MARK: Groups

    func testGroupsListCreateRenameMembersDeleteUseContractShapes() async throws {
        reply(#"{"groups":[{"id":"\#(g1)","name":"Kunden","projectIDs":["\#(p1)","\#(p2)"]},{"id":"\#(g2)","name":"Privat","projectIDs":[]}]}"#)
        let groups = try await client.projectGroups()
        XCTAssertEqual(last.httpMethod, "GET")
        XCTAssertEqual(last.url?.path, "/v1/project-groups")
        XCTAssertEqual(groups.map(\.name), ["Kunden", "Privat"])
        XCTAssertEqual(groups.first?.projectIDs, [p1, p2])

        reply(#"{"group":{"id":"\#(g1)","name":"Kunden","projectIDs":["\#(p1)"]},"changes":[]}"#)
        let created = try await client.createProjectGroup(name: "  Kunden  ", projectIDs: [p1])
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.url?.path, "/v1/project-groups")
        XCTAssertEqual(body(last)["name"] as? String, "Kunden", "the name goes trimmed")
        XCTAssertEqual(ids(body(last)["projectIDs"]), [p1])
        XCTAssertEqual(created.group?.id, g1)

        let change = #"{"kind":"mandate","grantID":"\#(grant)","name":"Brain","added":["\#(p2)"],"removed":[]}"#
        reply(#"{"group":{"id":"\#(g1)","name":"Kunden A","projectIDs":["\#(p1)","\#(p2)"]},"changes":[\#(change)]}"#)
        let renamed = try await client.updateProjectGroup(g1, name: "Kunden A", projectIDs: nil)
        XCTAssertEqual(last.httpMethod, "PATCH")
        XCTAssertEqual(last.url?.path, "/v1/project-groups/\(g1.uuidString)")
        XCTAssertEqual(body(last)["name"] as? String, "Kunden A")
        XCTAssertNil(body(last)["projectIDs"], "a rename leaves the members alone")
        XCTAssertNil(last.url?.query, "no dryRun unless asked")
        XCTAssertEqual(renamed.changes.first?.kind, "mandate")
        XCTAssertEqual(renamed.changes.first?.added, [p2])

        reply(#"{"group":{"id":"\#(g1)","name":"Kunden A","projectIDs":["\#(p3)"]},"changes":[]}"#)
        _ = try await client.updateProjectGroup(g1, name: nil, projectIDs: [p3], dryRun: true)
        XCTAssertNil(body(last)["name"])
        XCTAssertEqual(ids(body(last)["projectIDs"]), [p3])
        XCTAssertEqual(last.url?.query, "dryRun=true")

        reply(#"{"changes":[\#(change)]}"#)
        let removed = try await client.deleteProjectGroup(g1)
        XCTAssertEqual(last.httpMethod, "DELETE")
        XCTAssertEqual(last.url?.path, "/v1/project-groups/\(g1.uuidString)")
        XCTAssertEqual(removed.count, 1)
    }

    func testGroupsOfAProjectReadAndSet() async throws {
        reply(#"{"groupIDs":["\#(g2)"],"changes":[]}"#)
        let current = try await client.groupsOfProject(p1)
        XCTAssertEqual(last.httpMethod, "GET")
        XCTAssertEqual(last.url?.path, "/v1/projects/\(p1.uuidString)/groups")
        XCTAssertEqual(current, [g2])

        reply(#"{"groupIDs":["\#(g1)","\#(g2)"],"changes":[]}"#)
        let set = try await client.setGroupsOfProject(p1, groupIDs: [g1, g2])
        XCTAssertEqual(last.httpMethod, "PUT")
        XCTAssertEqual(last.url?.path, "/v1/projects/\(p1.uuidString)/groups")
        XCTAssertEqual(ids(body(last)["groupIDs"]), [g1, g2])
        XCTAssertEqual(set.groupIDs, [g1, g2])
    }

    func testGroupNameFollowsServerRules() {
        let groups = [ProjectGroup(id: g1, name: "Kunden", projectIDs: [])]
        XCTAssertEqual(ProjectGroupName.normalized("  Neue   Gruppe "), "Neue Gruppe")
        XCTAssertEqual(ProjectGroupName.problem("   ", groups: groups), "projectGroups.error.name")
        XCTAssertEqual(ProjectGroupName.problem(String(repeating: "x", count: 81), groups: groups), "projectGroups.error.name")
        XCTAssertNil(ProjectGroupName.problem(String(repeating: "x", count: 80), groups: groups))
        XCTAssertEqual(ProjectGroupName.problem("kunden", groups: groups), "projectGroups.error.taken")
        XCTAssertNil(ProjectGroupName.problem("KUNDEN", groups: groups, selfID: g1), "renaming a group to itself in other case is fine")
    }

    // MARK: Selection

    func testSelectionModeSwitchClearsExclusionsAndToggles() {
        var s = ProjectSelection(projectIDs: [p1])
        XCTAssertTrue(s.isPlain)
        s.toggle(\.groupIDs, g1)
        XCTAssertFalse(s.isPlain)
        s.setMode(.allExcept)
        s.toggle(\.excludedProjectIDs, p2)
        s.toggle(\.excludedGroupIDs, g2)
        XCTAssertEqual(s.excludedProjectIDs, [p2])
        s.setMode(.selected)
        XCTAssertEqual(s.excludedProjectIDs, [], "exclusions of the other mode would act unseen")
        XCTAssertEqual(s.excludedGroupIDs, [])
        XCTAssertEqual(s.groupIDs, [g1], "groups and explicit projects stay")
        XCTAssertEqual(s.projectIDs, [p1])
        s.toggle(\.projectIDs, p1)
        XCTAssertEqual(s.projectIDs, [])
        XCTAssertTrue(s.namesSomething, "an empty group still counts: it may get members")
        XCTAssertTrue(ProjectSelection(projectIDs: [p2, p1], groupIDs: [g1]).same(as: ProjectSelection(projectIDs: [p1, p2], groupIDs: [g1])))
    }

    func testPreviewSendsRuleOnlyWhenThereIsOne() async throws {
        reply(#"{"projectIDs":["\#(p1)","\#(p2)"],"agentCreatedProjectIDs":["\#(p3)"]}"#)
        let preview = try await client.previewSelection(ProjectSelection(mode: .allExcept, projectIDs: [], excludedProjectIDs: [p3]))
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.url?.path, "/v1/project-selection/preview")
        let sel = try XCTUnwrap(body(last)["selection"] as? [String: Any])
        XCTAssertEqual(sel["mode"] as? String, "all_except")
        XCTAssertEqual(ids(sel["excludedProjectIDs"]), [p3])
        XCTAssertEqual(ids(body(last)["projectIDs"]), [])
        XCTAssertEqual(preview.projectIDs, [p1, p2])
        XCTAssertEqual(preview.agentCreatedProjectIDs, [p3])

        _ = try await client.previewSelection(ProjectSelection(projectIDs: [p1]))
        XCTAssertNil(body(last)["selection"], "a plain list goes without selection (old meaning)")
        XCTAssertEqual(ids(body(last)["projectIDs"]), [p1])
    }

    // MARK: Connections keep their rule

    func testConnectionWithGroupRuleIsEditedFromItsExplicitListAndSavedWithSelection() async throws {
        // Effective: p1 (explicit) + p2, p3 (group g1). A naive edit would take all three as the list and send no rule.
        let grantJSON = #"[{"id":"\#(grant)","client_name":"Claude","name":"Brain","scopes":["projects:read"],"project_ids":["\#(p1)","\#(p2)","\#(p3)"],"explicit_project_ids":["\#(p1)"],"selection":\#(ruleJSON(projects: [p1], groups: [g1])),"revoked":false}]"#
        reply(grantJSON)
        let grants = try await client.connections()
        let connection = try XCTUnwrap(grants.first)
        XCTAssertEqual(connection.projectIDs, [p1, p2, p3], "project_ids stays the effective set")
        XCTAssertEqual(connection.selection?.groupIDs, [g1])
        var edit = connection.editableSelection
        XCTAssertEqual(edit.projectIDs, [p1], "the form starts from the explicit list, not the effective set")
        XCTAssertEqual(edit.groupIDs, [g1])
        edit.toggle(\.projectIDs, p3)

        reply(grantJSON.dropFirst().dropLast().description)
        _ = try await client.setConnectionSelection(grant, edit)
        XCTAssertEqual(last.httpMethod, "PUT")
        XCTAssertEqual(last.url?.path, "/oauth/grants/\(grant.uuidString)/projects")
        XCTAssertEqual(ids(body(last)["project_ids"]), [p1, p3])
        let sel = try XCTUnwrap(body(last)["selection"] as? [String: Any], "without selection the server would drop the group rule")
        XCTAssertEqual(sel["mode"] as? String, "selected")
        XCTAssertEqual(ids(sel["groupIDs"]), [g1])

        // An old server (no explicit_project_ids, no selection): the effective list is the explicit one.
        reply(#"[{"id":"\#(grant)","client_name":"Claude","scopes":[],"project_ids":["\#(p2)"],"revoked":false}]"#)
        let oldGrants = try await client.connections()
        let old = try XCTUnwrap(oldGrants.first)
        XCTAssertNil(old.selection)
        XCTAssertEqual(old.editableSelection, ProjectSelection(projectIDs: [p2]))
    }

    // MARK: Brain mandates keep their rule

    func testBrainMandateWithRuleIsSavedWithSelectionAndPlainOneWithout() async throws {
        let mandate = #"{"grantID":"\#(grant)","grantName":"Brain","projectIDs":["\#(p1)","\#(p2)"],"explicitProjectIDs":[],"selection":\#(ruleJSON(mode: "all_except", excluded: [p3], excludedGroups: [g2])),"active":true,"createdAt":"2026-11-26T08:00:00Z","updatedAt":"2026-11-26T09:00:00Z","revokedAt":null,"lastUsedAt":null}"#
        reply(#"{"mandates":[\#(mandate)]}"#)
        let mandates = try await client.brainMandates()
        let m = try XCTUnwrap(mandates.first)
        XCTAssertEqual(last.url?.path, "/v1/settings/brain-mandate")
        XCTAssertEqual(m.id, grant)
        XCTAssertTrue(m.active)
        XCTAssertEqual(m.projectIDs, [p1, p2])
        var edit = m.editableSelection
        XCTAssertEqual(edit.mode, .allExcept)
        XCTAssertEqual(edit.projectIDs, [], "explicit list, not the effective set")
        XCTAssertEqual(edit.excludedGroupIDs, [g2])
        edit.toggle(\.excludedProjectIDs, p1)

        reply(mandate)
        _ = try await client.saveBrainMandate(grantID: grant, selection: edit)
        XCTAssertEqual(last.httpMethod, "PUT")
        XCTAssertEqual(last.url?.path, "/v1/settings/brain-mandate")
        XCTAssertEqual(UUID(uuidString: body(last)["grantID"] as? String ?? ""), grant)
        XCTAssertEqual(ids(body(last)["projectIDs"]), [])
        let sel = try XCTUnwrap(body(last)["selection"] as? [String: Any], "without selection the server would replace the rule by an empty list")
        XCTAssertEqual(sel["mode"] as? String, "all_except")
        XCTAssertEqual(ids(sel["excludedProjectIDs"]), [p3, p1])
        XCTAssertEqual(ids(sel["excludedGroupIDs"]), [g2])

        _ = try await client.saveBrainMandate(grantID: grant, selection: ProjectSelection(projectIDs: [p2]))
        XCTAssertNil(body(last)["selection"], "a plain list goes without selection, also for older servers")
        XCTAssertEqual(ids(body(last)["projectIDs"]), [p2])

        // Older mandate without selection/explicit list: the effective list is the explicit one.
        reply(#"{"mandates":[{"grantID":"\#(grant)","grantName":null,"projectIDs":["\#(p2)"],"active":false,"createdAt":"2026-11-26T08:00:00Z","updatedAt":"2026-11-26T08:00:00Z","revokedAt":"2026-11-26T10:00:00Z","lastUsedAt":null}]}"#)
        let oldMandates = try await client.brainMandates()
        let old = try XCTUnwrap(oldMandates.first)
        XCTAssertFalse(old.active)
        XCTAssertEqual(old.editableSelection, ProjectSelection(projectIDs: [p2]))

        MockURLProtocol.handler = { _ in (204, Data()) }
        try await client.revokeBrainMandate(grantID: grant)
        XCTAssertEqual(last.httpMethod, "DELETE")
        XCTAssertEqual(last.url?.path, "/v1/settings/brain-mandate/\(grant.uuidString)")
    }
}
