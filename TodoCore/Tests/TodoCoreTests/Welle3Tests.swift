import XCTest
@testable import TodoCore

/// Glow-up wave 3: the features the PWA had and the app lacked. Confirmations (contracts/action-requests.yaml and
/// the feed's `confirmations[]`), acceptance criteria editing (collaboration.yaml), dependencies and milestones
/// (planning-ext.yaml, read only), the project mode (project-state.yaml) and the settings hub (identity.yaml
/// passkeys/sessions/preferences, oauth-mcp.yaml grants, agents.yaml pairing).
final class Welle3Tests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let tid = UUID(), pid = UUID()

    override func setUp() {
        MockURLProtocol.seen = []
        MockURLProtocol.handler = nil
        try? store.save("tok")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: URL(string: "http://test.invalid")!, session: URLSession(configuration: config), tokenStore: store)
    }

    private func reply(_ s: String) { reply(200, s) }
    private func reply(_ status: Int, _ s: String) { MockURLProtocol.handler = { _ in (status, Data(s.utf8)) } }
    private var last: URLRequest { MockURLProtocol.seen.last! }
    private func body(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    // MARK: Confirmations

    private func impact(destructive: Bool = true, type: String = "project") -> String {
        #"{"targetType":"\#(type)","targetID":"\#(pid)","targetName":"Altprojekt","subprojects":1,"tasks":3,"newOwnerName":null,"destructive":\#(destructive)}"#
    }
    private func request(state: String = "pending", tool: String = "delete_project", result: String = "null") -> String {
        #"{"id":"\#(tid)","tool":"\#(tool)","state":"\#(state)","summary":"Projekt „Altprojekt“ mit 3 Aufgaben löschen","impact":\#(impact()),"agentLabel":"Test-Agent","result":\#(result),"createdAt":"2026-11-12T08:00:00Z","decidedAt":null,"executedAt":null,"expiresAt":"2026-11-19T08:00:00Z"}"#
    }

    func testFeedDecodesConfirmationsAndOlderFeedsWithout() async throws {
        let c = #"{"id":"\#(tid)","tool":"delete_project","summary":"Projekt löschen","impact":\#(impact()),"agentLabel":"Test-Agent","createdAt":"2026-11-12T08:00:00Z","expiresAt":"2026-11-19T08:00:00Z","confirmPath":"/v1/action-requests/\#(tid)/confirm","rejectPath":"/v1/action-requests/\#(tid)/reject"}"#
        reply(#"{"generatedAt":"2026-11-12T08:00:00Z","mode":"all","projectID":null,"needsYou":[],"needsYouTotal":0,"confirmations":[\#(c)],"posts":[],"nextCursor":null}"#)
        let page = try await client.feed()
        XCTAssertEqual(page.confirmations.count, 1)
        let item = try XCTUnwrap(page.confirmations.first)
        XCTAssertEqual(item.id, tid)
        XCTAssertEqual(item.impact.targetName, "Altprojekt")
        XCTAssertEqual(item.impact.tasks, 3)
        XCTAssertTrue(item.impact.destructive)
        XCTAssertEqual(item.agentLabel, "Test-Agent")
        var state = FeedState()
        state.replace(with: page)
        XCTAssertEqual(state.confirmations.map(\.id), [tid])
        XCTAssertFalse(state.isEmpty, "a pending confirmation alone keeps the feed from being empty")
        state.remove(confirmationID: tid)
        XCTAssertTrue(state.confirmations.isEmpty)

        reply(#"{"generatedAt":"2026-11-12T08:00:00Z","mode":"all","projectID":null,"needsYou":[],"needsYouTotal":0,"posts":[],"nextCursor":null}"#)
        let older = try await client.feed()
        XCTAssertEqual(older.confirmations, [])
    }

    func testActionRequestRoutes() async throws {
        reply("[" + request() + "]")
        let list = try await client.actionRequests(state: .pending)
        XCTAssertEqual(last.url?.path, "/v1/action-requests")
        XCTAssertEqual(last.url?.query, "state=pending")
        XCTAssertEqual(list.first?.state, .pending)

        reply(request(state: "executed", result: #"{"ok":true,"code":"deleted"}"#))
        let done = try await client.confirmActionRequest(tid)
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.url?.path, "/v1/action-requests/\(tid.uuidString)/confirm")
        XCTAssertEqual(done.state, .executed)
        XCTAssertEqual(done.result?.ok, true)

        reply(request(state: "rejected"))
        let rejected = try await client.rejectActionRequest(tid)
        XCTAssertEqual(last.url?.path, "/v1/action-requests/\(tid.uuidString)/reject")
        XCTAssertEqual(rejected.state, .rejected)

        reply(410, #"{"reason":"request_expired"}"#)
        do { _ = try await client.confirmActionRequest(tid); XCTFail("expected 410") } catch {}
    }

    func testUnknownStateAndToolStayReadable() async throws {
        reply(request(state: "something_new", tool: "delete_everything"))
        let r = try await client.actionRequest(tid)
        XCTAssertEqual(r.state, .other("something_new"))
        XCTAssertEqual(r.tool, "delete_everything")
    }

    func testConfirmationGateAndOutcome() {
        XCTAssertEqual(ConfirmationRules.gate(tool: "delete_project"), .typeName)
        XCTAssertEqual(ConfirmationRules.gate(tool: "delete_task"), .tick)
        XCTAssertEqual(ConfirmationRules.gate(tool: "transfer_project_owner"), .tick)
        XCTAssertTrue(ConfirmationRules.nameMatches(" Altprojekt ", "Altprojekt"))
        XCTAssertFalse(ConfirmationRules.nameMatches("altprojekt", "Altprojekt"), "case counts")
        XCTAssertFalse(ConfirmationRules.nameMatches("", " "))
        // Not destructive: one tap is enough; destructive needs the gate.
        XCTAssertTrue(ConfirmationRules.ready(destructive: false, tool: "delete_project", typed: "", ticked: false))
        XCTAssertFalse(ConfirmationRules.ready(destructive: true, tool: "delete_project", typed: "falsch", ticked: true))
        XCTAssertTrue(ConfirmationRules.ready(destructive: true, tool: "delete_project", typed: "Altprojekt", ticked: false, name: "Altprojekt"))
        XCTAssertFalse(ConfirmationRules.ready(destructive: true, tool: "delete_task", typed: "", ticked: false))
        XCTAssertTrue(ConfirmationRules.ready(destructive: true, tool: "delete_task", typed: "", ticked: true))

        XCTAssertEqual(ConfirmationRules.outcomeKey(tool: "delete_project", state: .executed, code: "deleted"), "confirm.done.projectDeleted")
        XCTAssertEqual(ConfirmationRules.outcomeKey(tool: "delete_task", state: .executed, code: nil), "confirm.done.taskDeleted")
        XCTAssertEqual(ConfirmationRules.outcomeKey(tool: "transfer_project_owner", state: .executed, code: nil), "confirm.done.ownerChanged")
        XCTAssertEqual(ConfirmationRules.outcomeKey(tool: "delete_column", state: .executed, code: nil), "confirm.done.executed")
        XCTAssertEqual(ConfirmationRules.outcomeKey(tool: "delete_task", state: .rejected, code: nil), "confirm.done.rejected")
        XCTAssertEqual(ConfirmationRules.outcomeKey(tool: "delete_task", state: .expired, code: nil), "confirm.done.expired")
        XCTAssertEqual(ConfirmationRules.outcomeKey(tool: "delete_task", state: .failed, code: "forbidden"), "confirm.fail.forbidden")
        XCTAssertEqual(ConfirmationRules.outcomeKey(tool: "delete_task", state: .failed, code: "version_conflict"), "confirm.fail.conflict")
        XCTAssertEqual(ConfirmationRules.outcomeKey(tool: "delete_task", state: .failed, code: "weird"), "confirm.fail.other")
    }

    // MARK: Acceptance criteria

    func testCriterionCreateUpdateDelete() async throws {
        let cid = UUID()
        let dto = #"{"id":"\#(cid)","taskID":"\#(tid)","text":"Mobil zuerst","completed":false,"version":1}"#
        reply(201, dto)
        let created = try await client.createCriterion(taskID: tid, text: "  Mobil zuerst ")
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.url?.path, "/v1/tasks/\(tid.uuidString)/acceptance-criteria")
        XCTAssertEqual(body(last)["text"] as? String, "Mobil zuerst")
        XCTAssertNotNil(last.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(created.id, cid)

        reply(#"{"id":"\#(cid)","taskID":"\#(tid)","text":"Mobil zuerst","completed":true,"version":2}"#)
        let ticked = try await client.updateCriterion(taskID: tid, id: cid, version: 1, completed: true)
        XCTAssertEqual(last.httpMethod, "PATCH")
        XCTAssertEqual(last.url?.path, "/v1/tasks/\(tid.uuidString)/acceptance-criteria/\(cid.uuidString)")
        XCTAssertEqual(body(last)["completed"] as? Bool, true, "explicit target state, no blind toggle")
        XCTAssertEqual(body(last)["version"] as? Int, 1)
        XCTAssertNil(body(last)["text"])
        XCTAssertTrue(ticked.completed)

        reply(dto)
        _ = try await client.updateCriterion(taskID: tid, id: cid, version: 2, text: "Tablet auch")
        XCTAssertEqual(body(last)["text"] as? String, "Tablet auch")
        XCTAssertNil(body(last)["completed"])

        reply(204, "")
        try await client.deleteCriterion(taskID: tid, id: cid, version: 3)
        XCTAssertEqual(last.httpMethod, "DELETE")
        XCTAssertEqual(body(last)["version"] as? Int, 3)

        reply(409, #"{"reason":"version_conflict"}"#)
        do { _ = try await client.updateCriterion(taskID: tid, id: cid, version: 1, completed: false); XCTFail("expected conflict") }
        catch { XCTAssertTrue(error is APIError) }
    }

    func testCriterionEmptyTextIsRejectedLocally() async throws {
        reply(201, "{}")
        do { _ = try await client.createCriterion(taskID: tid, text: "   "); XCTFail("expected invalid input") }
        catch { XCTAssertEqual(error as? APIError, .invalidInput(reason: "text_required")) }
        XCTAssertTrue(MockURLProtocol.seen.isEmpty, "nothing sent")
    }

    func testCriteriaListReplacesOneEntry() {
        let a = TaskCriterion(id: UUID(), taskID: tid, text: "A", completed: false, version: 1)
        let b = TaskCriterion(id: UUID(), taskID: tid, text: "B", completed: false, version: 1)
        let b2 = TaskCriterion(id: b.id, taskID: tid, text: "B", completed: true, version: 2)
        XCTAssertEqual([a, b].replacing(b2), [a, b2])
        XCTAssertEqual([a].replacing(b2), [a, b2], "unknown entry is appended")
    }

    // MARK: Dependencies and milestones

    private func task(_ id: UUID, _ title: String, status: String = "open") -> String {
        #"{"id":"\#(id)","projectID":"\#(pid)","title":"\#(title)","description":"","status":"\#(status)","version":1,"columnID":null,"boardPosition":0}"#
    }

    func testDependenciesOfATask() async throws {
        let pre = UUID()
        reply("[" + task(pre, "API-Vertrag", status: "done") + "]")
        let deps = try await client.dependencies(taskID: tid)
        XCTAssertEqual(last.url?.path, "/v1/planning/tasks/\(tid.uuidString)/dependencies")
        XCTAssertEqual(deps.map(\.id), [pre])
        XCTAssertTrue(deps[0].isDone)
    }

    func testMilestonesAndTheTasksMilestone() async throws {
        let m1 = UUID(), m2 = UUID(), other = UUID()
        reply(#"[{"milestone":{"id":"\#(m1)","projectID":"\#(pid)","title":"Beta","dueAt":"2026-12-01T00:00:00Z"},"tasks":[\#(task(other, "X"))]},"# +
              #"{"milestone":{"id":"\#(m2)","projectID":"\#(pid)","title":"Launch"},"tasks":[\#(task(tid, "Y")),\#(task(other, "X", status: "done"))]}]"#)
        let list = try await client.milestones(projectID: pid)
        XCTAssertEqual(last.url?.path, "/v1/planning/milestones")
        XCTAssertEqual(last.url?.query, "projectID=\(pid.uuidString)")
        XCTAssertEqual(list.count, 2)
        XCTAssertNotNil(list[0].milestone.dueAt)
        XCTAssertNil(list[1].milestone.dueAt)
        XCTAssertEqual(list.milestone(of: tid)?.milestone.title, "Launch")
        XCTAssertNil(list.milestone(of: UUID()))
        XCTAssertEqual(list[1].doneCount, 1)
    }

    // MARK: Project mode

    func testProjectModeDecodingAndDefaults() throws {
        let dec = JSONDecoder()
        let withMode = #"{"projectID":"\#(pid)","view":"list","sort":"manual","grouping":"column","showCompleted":true,"mode":"classic","modeSource":"default","isFavorite":false,"revision":0}"#
        let p = try dec.decode(ProjectDisplayPrefs.self, from: Data(withMode.utf8))
        XCTAssertEqual(p.projectMode, .classic)
        XCTAssertEqual(p.modeSource, "default")
        // A server before the switch has no field: everything stays as it was (management), like the PWA.
        let old = #"{"projectID":"\#(pid)","view":"list","sort":"manual","grouping":"column","showCompleted":true,"isFavorite":false,"revision":3}"#
        XCTAssertEqual(try dec.decode(ProjectDisplayPrefs.self, from: Data(old.utf8)).projectMode, .management)
        XCTAssertEqual(ProjectDisplayPrefs(projectID: pid).projectMode, .management, "unknown project keeps the full view")
        // Unknown future values fall back to management too.
        var q = p; q.mode = "kanban"
        XCTAssertEqual(q.projectMode, .management)
    }

    func testModePatchIsSentAndApplied() async throws {
        let patch = ProjectPrefsPatch(mode: ProjectMode.classic.rawValue)
        XCTAssertFalse(patch.isEmpty)
        let applied = patch.applied(to: ProjectDisplayPrefs(projectID: pid))
        XCTAssertEqual(applied.projectMode, .classic)
        XCTAssertEqual(applied.modeSource, "user")
        XCTAssertEqual(ProjectPrefsPatch(view: "board").merged(with: patch), ProjectPrefsPatch(view: "board", mode: "classic"))

        reply(#"{"projectID":"\#(pid)","view":"list","sort":"manual","grouping":"column","showCompleted":true,"mode":"classic","modeSource":"user","isFavorite":false,"revision":1}"#)
        _ = try await client.patchProjectPrefs(pid, revision: 0, patch)
        XCTAssertEqual(body(last)["mode"] as? String, "classic")
        XCTAssertEqual(body(last)["revision"] as? Int, 0)
        XCTAssertNil(body(last)["view"])
    }

    func testPrefsListAsksForDefaults() async throws {
        reply(#"{"items":[]}"#)
        _ = try await client.projectPrefs(includeDefaults: true)
        XCTAssertEqual(last.url?.query, "includeDefaults=true")
        _ = try await client.projectPrefs()
        XCTAssertNil(last.url?.query)
    }

    func testOldPrefsCacheWithoutModeStillDecodes() throws {
        // The app caches prefs and pending patches as JSON (UserDefaults); entries written before wave 3 lack `mode`.
        let cached = #"{"view":"board"}"#
        let patch = try JSONDecoder().decode(ProjectPrefsPatch.self, from: Data(cached.utf8))
        XCTAssertEqual(patch.view, "board")
        XCTAssertNil(patch.mode)
    }

    // MARK: Settings hub

    func testPreferencesKeepAccentAndGlowWhenChangingTheScheme() async throws {
        reply(##"{"version":1,"appearance":{"colorScheme":"system","accent":"custom","accentCustomHex":"#12AB34","glow":"subtle"},"revision":4,"updatedAt":null}"##)
        let prefs = try await client.preferences()
        XCTAssertEqual(last.url?.path, "/v1/me/preferences")
        XCTAssertEqual(prefs.appearance.scheme, .system)
        XCTAssertEqual(prefs.revision, 4)

        reply(##"{"version":1,"appearance":{"colorScheme":"dark","accent":"custom","accentCustomHex":"#12AB34","glow":"subtle"},"revision":5}"##)
        let saved = try await client.savePreferences(prefs.withColorScheme(.dark))
        XCTAssertEqual(last.httpMethod, "PUT")
        let sent = body(last)
        XCTAssertEqual(sent["version"] as? Int, 1)
        XCTAssertNil(sent["revision"], "strict document: no revision key")
        let appearance = sent["appearance"] as? [String: Any]
        XCTAssertEqual(appearance?["colorScheme"] as? String, "dark")
        XCTAssertEqual(appearance?["accent"] as? String, "custom")
        XCTAssertEqual(appearance?["accentCustomHex"] as? String, "#12AB34")
        XCTAssertEqual(appearance?["glow"] as? String, "subtle")
        XCTAssertEqual(saved.appearance.scheme, .dark)
    }

    func testPreferencesWithoutCustomAccentSendNoHex() async throws {
        reply(#"{"version":1,"appearance":{"colorScheme":"light","accent":"blue","glow":"off"},"revision":0}"#)
        let prefs = try await client.preferences()
        reply(#"{"version":1,"appearance":{"colorScheme":"dark","accent":"blue","glow":"off"},"revision":1}"#)
        _ = try await client.savePreferences(prefs.withColorScheme(.dark))
        let appearance = body(last)["appearance"] as? [String: Any]
        XCTAssertNil(appearance?["accentCustomHex"])
    }

    func testPasskeysListRenameRevokeAndAdd() async throws {
        let k = UUID()
        reply(#"[{"id":"\#(k)","name":"iPhone","createdAt":"2026-11-01T10:00:00Z"},{"id":"\#(UUID())","name":"Alt","createdAt":"2026-10-01T10:00:00Z","revokedAt":"2026-10-02T10:00:00Z"}]"#)
        let keys = try await client.passkeys()
        XCTAssertEqual(last.url?.path, "/v1/me/passkeys")
        XCTAssertEqual(keys.count, 2)
        XCTAssertTrue(keys[0].isActive)
        XCTAssertFalse(keys[1].isActive)

        reply(204, "")
        try await client.renamePasskey(k, name: " Mac ")
        XCTAssertEqual(last.httpMethod, "PATCH")
        XCTAssertEqual(body(last)["name"] as? String, "Mac")
        try await client.revokePasskey(k)
        XCTAssertEqual(last.httpMethod, "DELETE")
        XCTAssertEqual(last.url?.path, "/v1/me/passkeys/\(k.uuidString)")

        reply(409, #"{"reason":"last_passkey"}"#)
        do { try await client.revokePasskey(k); XCTFail("expected conflict") } catch {}

        let challenge = Data([1, 2, 3, 250]).base64URLEncoded
        let cid = UUID()
        MockURLProtocol.handler = { req in
            if req.url!.path.hasSuffix("/begin") {
                return (200, Data(#"{"challengeID":"\#(cid)","options":{"challenge":"\#(challenge)","rp":{"id":"rp.test","name":"T"},"user":{"id":"AQI","name":"lino","displayName":"Lino"}}}"#.utf8))
            }
            return (200, Data(#"{"ok":true}"#.utf8))
        }
        try await client.addPasskey(name: "iPad", authenticator: FakePasskey())
        let begin = MockURLProtocol.seen[MockURLProtocol.seen.count - 2]
        XCTAssertEqual(begin.url?.path, "/v1/me/passkeys/begin")
        XCTAssertEqual(begin.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(last.url?.path, "/v1/me/passkeys/finish")
        XCTAssertEqual(last.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let finish = body(last)
        XCTAssertEqual(finish["challengeID"] as? String, cid.uuidString)
        XCTAssertEqual(finish["passkeyName"] as? String, "iPad")
        XCTAssertNotNil((finish["credential"] as? [String: Any])?["response"])
    }

    func testSessions() async throws {
        let me = UUID(), other = UUID()
        reply(#"[{"id":"\#(other)","createdAt":"2026-11-01T10:00:00Z","expiresAt":"2026-12-01T10:00:00Z","current":false},{"id":"\#(me)","createdAt":"2026-11-10T10:00:00Z","expiresAt":"2026-12-10T10:00:00Z","current":true}]"#)
        let list = try await client.sessions()
        XCTAssertEqual(last.url?.path, "/v1/me/sessions")
        XCTAssertEqual(list.sortedCurrentFirst.map(\.id), [me, other])
        reply(204, "")
        try await client.revokeSession(other)
        XCTAssertEqual(last.httpMethod, "DELETE")
        XCTAssertEqual(last.url?.path, "/v1/me/sessions/\(other.uuidString)")
        try await client.revokeOtherSessions()
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.url?.path, "/v1/me/sessions/revoke-others")
    }

    func testConnections() async throws {
        let g = UUID()
        reply(#"[{"id":"\#(g)","client_id":"\#(UUID())","client_name":"Claude Code","scopes":["projects:read","tasks:write"],"project_ids":["\#(pid)"],"revoked":false,"name":"Mac mini","last_used_at":"2026-11-12T08:00:00Z"},"# +
              #"{"id":"\#(UUID())","client_id":"\#(UUID())","client_name":"","scopes":[],"project_ids":[],"revoked":true}]"#)
        let list = try await client.connections()
        XCTAssertEqual(last.url?.path, "/oauth/grants")
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].displayName, "Mac mini")
        XCTAssertEqual(list[0].projectIDs, [pid])
        XCTAssertNotNil(list[0].lastUsedAt)
        XCTAssertEqual(list[1].displayName, "", "no name and no client name")
        XCTAssertEqual(list.active.map(\.id), [g], "revoked connections are hidden")

        reply(204, "")
        try await client.revokeConnection(g)
        XCTAssertEqual(last.httpMethod, "DELETE")
        XCTAssertEqual(last.url?.path, "/oauth/grants/\(g.uuidString)")
    }

    func testRunnerPairingCode() async throws {
        let d = UUID()
        reply(#"{"deviceID":"\#(d)","code":"ABCD-1234","expiresAt":"2026-11-12T08:10:00Z"}"#)
        let pairing = try await client.pairRunner(label: " Mac mini ")
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.url?.path, "/v1/agents/devices")
        XCTAssertEqual(body(last)["label"] as? String, "Mac mini")
        XCTAssertEqual(pairing.code, "ABCD-1234")
        XCTAssertEqual(pairing.deviceID, d)
    }
}
