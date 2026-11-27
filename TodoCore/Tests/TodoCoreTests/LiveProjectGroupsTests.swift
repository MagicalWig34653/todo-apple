import XCTest
@testable import TodoCore

/// Card 80738AEA end to end against a real backend (skipped without `TODO_LIVE_BASE_URL`; needs a fresh bootstrap token):
/// create a group, preview a selection, give a brain mandate with the group, change the group, edit and save the mandate and
/// a connection the way the app does, and check that the group rule survives every save.
final class LiveProjectGroupsTests: XCTestCase {
    private func mandateOf(_ a: APIClient, _ grant: UUID) async throws -> BrainMandate {
        let all = try await a.brainMandates()
        return try XCTUnwrap(all.first { $0.grantID == grant })
    }
    private func connectionOf(_ a: APIClient, _ grant: UUID) async throws -> Connection {
        let all = try await a.connections()
        return try XCTUnwrap(all.first { $0.id == grant })
    }

    func testGroupsPreviewMandateAndConnectionKeepTheRule() async throws {
        let f = try await LiveEtappe2Tests().fixture()
        let a = f.admin
        let pA = try await a.createProject(name: "Gruppe A \(f.suffix)")
        let pB = try await a.createProject(name: "Gruppe B \(f.suffix)")
        let pC = try await a.createProject(name: "Gruppe C \(f.suffix)")

        // Group: create, list.
        let created = try await a.createProjectGroup(name: "Kunden \(f.suffix)", projectIDs: [pB.id])
        let g = try XCTUnwrap(created.group)
        let groups = try await a.projectGroups()
        XCTAssertTrue(groups.contains { $0.id == g.id && $0.projectIDs == [pB.id] })
        do { _ = try await a.createProjectGroup(name: "KUNDEN \(f.suffix)", projectIDs: []); XCTFail("name taken") } catch {}

        // A real MCP connection (OAuth/PKCE) for project A only.
        let mcp = try await LiveMCPConnection.connect(a, name: "Brain-Test", projects: [pA.id])
        let active = try await a.connections().active
        let grant = try XCTUnwrap(active.first { $0.displayName == "Brain-Test" })

        // Preview: explicit A plus the group; "all except C".
        let withGroup = ProjectSelection(projectIDs: [pA.id], groupIDs: [g.id])
        let preview = try await a.previewSelection(withGroup)
        XCTAssertEqual(Set(preview.projectIDs), [pA.id, pB.id])
        let allButC = try await a.previewSelection(ProjectSelection(mode: .allExcept, excludedProjectIDs: [pC.id]))
        XCTAssertTrue(Set(allButC.projectIDs).isSuperset(of: [pA.id, pB.id]))
        XCTAssertFalse(allButC.projectIDs.contains(pC.id))

        // Mandate with the group.
        let saved = try await a.saveBrainMandate(grantID: grant.id, selection: withGroup)
        XCTAssertEqual(Set(saved.projectIDs), [pA.id, pB.id])
        XCTAssertEqual(saved.selection?.groupIDs, [g.id])

        // The group grows: the mandate follows at once and the change names it.
        let grown = try await a.updateProjectGroup(g.id, name: nil, projectIDs: [pB.id, pC.id])
        XCTAssertTrue(grown.changes.contains { $0.kind == "mandate" && $0.grantID == grant.id && $0.added == [pC.id] })
        var mandate = try await mandateOf(a, grant.id)
        XCTAssertEqual(Set(mandate.projectIDs), [pA.id, pB.id, pC.id])

        // Edit like the app: from the explicit list plus rule, drop A, save. The rule stays.
        var edit = mandate.editableSelection
        XCTAssertEqual(edit.projectIDs, [pA.id])
        edit.toggle(\.projectIDs, pA.id)
        _ = try await a.saveBrainMandate(grantID: grant.id, selection: edit)
        mandate = try await mandateOf(a, grant.id)
        XCTAssertEqual(mandate.selection?.groupIDs, [g.id], "the group rule survives the save")
        XCTAssertEqual(Set(mandate.projectIDs), [pB.id, pC.id])

        // Connection: the same rule on the grant itself; then an edit keeps it.
        _ = try await a.setConnectionSelection(grant.id, withGroup)
        var conn = try await connectionOf(a, grant.id)
        XCTAssertEqual(conn.selection?.groupIDs, [g.id])
        XCTAssertEqual(Set(conn.projectIDs), [pA.id, pB.id, pC.id])
        var connEdit = conn.editableSelection
        XCTAssertEqual(connEdit.projectIDs, [pA.id])
        connEdit.toggle(\.projectIDs, pA.id)
        connEdit.groupIDs = [g.id]
        _ = try await a.setConnectionSelection(grant.id, connEdit)
        conn = try await connectionOf(a, grant.id)
        XCTAssertEqual(conn.selection?.groupIDs, [g.id], "the group rule survives the save")
        XCTAssertEqual(Set(conn.projectIDs), [pB.id, pC.id])
        // The agent sees exactly the group's projects through MCP.
        let seen = try await mcp.call("list_project_groups", [:])
        XCTAssertFalse(seen.isError, seen.text)
        XCTAssertTrue(seen.text.contains(pB.name) && seen.text.contains(pC.name), seen.text)
        XCTAssertFalse(seen.text.contains(pA.name), seen.text)

        // Project settings: put A into the group.
        let set = try await a.setGroupsOfProject(pA.id, groupIDs: [g.id])
        XCTAssertEqual(set.groupIDs, [g.id])
        let ofA = try await a.groupsOfProject(pA.id)
        XCTAssertEqual(ofA, [g.id])
        let after = try await a.projectGroups().first { $0.id == g.id }
        XCTAssertEqual(Set(after?.projectIDs ?? []), [pA.id, pB.id, pC.id])

        // Rename, then delete: every selection loses the group's projects, the changes say so.
        let renamed = try await a.updateProjectGroup(g.id, name: "Kunden neu \(f.suffix)", projectIDs: nil)
        XCTAssertEqual(renamed.group?.name, "Kunden neu \(f.suffix)")
        let dry = try await a.updateProjectGroup(g.id, name: nil, projectIDs: [], dryRun: true)
        XCTAssertFalse(dry.changes.isEmpty, "dryRun computes the effect")
        let unchanged = try await a.projectGroups().first { $0.id == g.id }
        XCTAssertEqual(unchanged?.projectIDs.count, 3, "dryRun saved nothing")
        let gone = try await a.deleteProjectGroup(g.id)
        XCTAssertTrue(gone.contains { $0.kind == "mandate" && $0.grantID == grant.id })
        mandate = try await mandateOf(a, grant.id)
        XCTAssertFalse(mandate.projectIDs.contains(pB.id))
        try await a.revokeBrainMandate(grantID: grant.id)
        print("LIVE 80738AEA ok: group \(g.id) mandate+connection kept rule; preview \(preview.projectIDs.count); allExcept \(allButC.projectIDs.count)")
    }

    /// Seeds the account of the picture tour (`App/UITests/ProjectGroupsTour.swift`, Mac render `TODO_DEBUG_GROUPS_RENDER`) and writes
    /// `{"token":...}` to `TODO_LIVE_SEED_GROUPS_OUT`: projects, groups "Kunden" and "Privat", a connection "Brain" with a mandate
    /// for "Umzug" plus the group "Kunden", a connection "Claude Code" for all projects except the group "Privat".
    func testSeedGroupsTour() async throws {
        guard let out = ProcessInfo.processInfo.environment["TODO_LIVE_SEED_GROUPS_OUT"] else { throw XCTSkip("TODO_LIVE_SEED_GROUPS_OUT not set") }
        let f = try await LiveEtappe2Tests().fixture()
        let a = f.admin
        let web = try await a.createProject(name: "Website-Relaunch")
        let move = try await a.createProject(name: "Umzug")
        _ = try await a.createProject(name: "Kueche", parentID: move.id)
        let tax = try await a.createProject(name: "Steuer 2026")
        let garden = try await a.createProject(name: "Garten")
        let kundenResult = try await a.createProjectGroup(name: "Kunden", projectIDs: [web.id, tax.id])
        let kunden = try XCTUnwrap(kundenResult.group)
        let privatResult = try await a.createProjectGroup(name: "Privat", projectIDs: [move.id, garden.id])
        let privat = try XCTUnwrap(privatResult.group)
        _ = try await LiveMCPConnection.connect(a, name: "Brain", projects: [move.id])
        _ = try await LiveMCPConnection.connect(a, name: "Claude Code", projects: [web.id])
        let conns = try await a.connections().active
        let brain = try XCTUnwrap(conns.first { $0.displayName == "Brain" })
        let code = try XCTUnwrap(conns.first { $0.displayName == "Claude Code" })
        _ = try await a.saveBrainMandate(grantID: brain.id, selection: ProjectSelection(projectIDs: [move.id], groupIDs: [kunden.id]))
        _ = try await a.setConnectionSelection(code.id, ProjectSelection(mode: .allExcept, excludedGroupIDs: [privat.id]))
        let token = try XCTUnwrap(try f.adminStore.load())
        try JSONSerialization.data(withJSONObject: ["token": token]).write(to: URL(fileURLWithPath: out))
    }
}

