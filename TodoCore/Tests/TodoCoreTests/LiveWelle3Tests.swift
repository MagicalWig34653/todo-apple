import CryptoKit
import XCTest
@testable import TodoCore

/// A real MCP connection for tests: OAuth with PKCE against the session of `client` (like `web/e2e/action-requests.spec.ts`).
struct LiveMCPConnection {
    let baseURL: URL
    let accessToken: String

    private struct Registered: Decodable { let client_id: String }
    private struct Consent: Decodable { let consent_token: String }
    private struct Redirect: Decodable { let redirect_uri: String }
    private struct Token: Decodable { let access_token: String }
    private struct RegisterBody: Encodable { let client_name: String; let redirect_uris: [String]; let token_endpoint_auth_method = "none" }
    private struct ConsentBody: Encodable { let consent_token: String; let approve = true; let project_ids: [String] }
    private struct TokenBody: Encodable {
        let grant_type = "authorization_code"; let client_id: String; let resource: String; let code: String
        let redirect_uri: String; let code_verifier: String
    }

    static func connect(_ client: APIClient, name: String, projects: [UUID]) async throws -> LiveMCPConnection {
        let redirect = "https://client.example/cb"
        let resource = client.baseURL.appending(path: "mcp").absoluteString
        let reg: Registered = try await client.send("POST", "oauth/register", body: RegisterBody(client_name: name, redirect_uris: [redirect]), auth: false)
        let verifier = (0..<40).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let consent: Consent = try await client.send("GET", "oauth/authorize", query: [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: reg.client_id),
            .init(name: "redirect_uri", value: redirect), .init(name: "scope", value: "projects:read projects:write tasks:read tasks:write"),
            .init(name: "state", value: "s"), .init(name: "resource", value: resource),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
        ])
        let target: Redirect = try await client.send("POST", "oauth/consent", body: ConsentBody(consent_token: consent.consent_token, project_ids: projects.map(\.uuidString)))
        let code = try XCTUnwrap(URLComponents(string: target.redirect_uri)?.queryItems?.first { $0.name == "code" }?.value)
        let token: Token = try await client.send("POST", "oauth/token", body: TokenBody(client_id: reg.client_id, resource: resource, code: code, redirect_uri: redirect, code_verifier: verifier), auth: false)
        return LiveMCPConnection(baseURL: client.baseURL, accessToken: token.access_token)
    }

    /// Calls an MCP tool; returns (isError, text of the first content item).
    func call(_ tool: String, _ args: [String: String]) async throws -> (isError: Bool, text: String) {
        var req = URLRequest(url: baseURL.appending(path: "mcp"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": args]])
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], String(decoding: data, as: UTF8.self))
        let result = try XCTUnwrap(json["result"] as? [String: Any], String(decoding: data, as: UTF8.self))
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (result["isError"] as? Bool ?? false, text)
    }

    /// Asks for a confirmation-gated tool; returns the request id.
    func requestConfirmation(_ tool: String, _ args: [String: String]) async throws -> UUID {
        let r = try await call(tool, args)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.text.utf8)) as? [String: Any], r.text)
        XCTAssertEqual(obj["error"] as? String, "confirmation_required", r.text)
        return try XCTUnwrap(UUID(uuidString: obj["actionRequestID"] as? String ?? ""), r.text)
    }
}

struct PrerequisiteBody: Encodable { let prerequisiteID: UUID }
struct MilestoneBody: Encodable { let projectID: UUID; let title: String; let dueAt: Date? }

extension APIClient {
    /// Test helpers for the write side the app does not use (dependencies and milestones are read only in the app).
    func addDependency(_ taskID: UUID, prerequisite: UUID) async throws {
        try await sendNoContent("PUT", "v1/planning/tasks/\(taskID.uuidString)/dependencies", body: PrerequisiteBody(prerequisiteID: prerequisite))
    }
    func createMilestone(projectID: UUID, title: String, dueAt: Date?) async throws -> Milestone {
        try await send("POST", "v1/planning/milestones", body: MilestoneBody(projectID: projectID, title: title, dueAt: dueAt))
    }
    func attachMilestone(_ id: UUID, taskID: UUID) async throws {
        try await sendNoContent("PUT", "v1/planning/milestones/\(id.uuidString)/tasks/\(taskID.uuidString)")
    }
}

/// Wave 3 end to end against a real backend (skipped without `TODO_LIVE_BASE_URL`; needs a fresh bootstrap token).
final class LiveWelle3Tests: XCTestCase {
    func testWelle3EndToEnd() async throws {
        let f = try await LiveEtappe2Tests().fixture()
        let a = f.admin
        let p = try await a.createProject(name: "W3 \(f.suffix)")
        let doomed = try await a.createProject(name: "Weg \(f.suffix)")
        let t = try await a.createTask(projectID: p.id, title: "Karte")
        let pre = try await a.createTask(projectID: p.id, title: "Voraussetzung")

        // Confirmations: a real MCP connection asks; reject one, confirm the other (executes).
        let mcp = try await LiveMCPConnection.connect(a, name: "Test-Agent", projects: [p.id, doomed.id])
        let r1 = try await mcp.requestConfirmation("delete_project", ["projectID": doomed.id.uuidString])
        let r2 = try await mcp.requestConfirmation("delete_task", ["taskID": pre.id.uuidString])
        let feed = try await a.feed()
        XCTAssertEqual(Set(feed.confirmations.map(\.id)), [r1, r2])
        XCTAssertEqual(feed.confirmations.first { $0.id == r1 }?.agentLabel?.isEmpty, false)
        let rejected = try await a.rejectActionRequest(r2)
        XCTAssertEqual(rejected.state, .rejected)
        let done = try await a.confirmActionRequest(r1)
        XCTAssertEqual(done.state, .executed)
        XCTAssertEqual(ConfirmationRules.outcomeKey(tool: done.tool, state: done.state, code: done.result?.code), "confirm.done.projectDeleted")
        let names = try await a.projects().map(\.name)
        XCTAssertFalse(names.contains(doomed.name))
        let left = try await a.feed().confirmations
        XCTAssertTrue(left.isEmpty)
        let conns = try await a.connections().active
        XCTAssertTrue(conns.contains { $0.displayName == "Test-Agent" })

        // Criteria: add, tick, rename, delete.
        let c = try await a.createCriterion(taskID: t.id, text: "Mobil zuerst")
        let ticked = try await a.updateCriterion(taskID: t.id, id: c.id, version: c.version, completed: true)
        XCTAssertTrue(ticked.completed)
        do { _ = try await a.updateCriterion(taskID: t.id, id: c.id, version: c.version, text: "alt"); XCTFail("stale version") } catch {}
        let renamed = try await a.updateCriterion(taskID: t.id, id: c.id, version: ticked.version, text: "Tablet auch")
        let ctx = try await a.taskContext(t.id)
        XCTAssertEqual(ctx.criteria.map(\.text), ["Tablet auch"])
        try await a.deleteCriterion(taskID: t.id, id: c.id, version: renamed.version)
        let remaining = try await a.criteria(taskID: t.id)
        XCTAssertTrue(remaining.isEmpty)

        // Dependencies and milestone (read side).
        try await a.addDependency(t.id, prerequisite: pre.id)
        let deps = try await a.dependencies(taskID: t.id)
        XCTAssertEqual(deps.map(\.id), [pre.id])
        let m = try await a.createMilestone(projectID: p.id, title: "Beta", dueAt: nil)
        try await a.attachMilestone(m.id, taskID: t.id)
        let ms = try await a.milestones(projectID: p.id)
        XCTAssertEqual(ms.milestone(of: t.id)?.milestone.title, "Beta")

        // Project mode: derived default, then the user's choice.
        let all = try await a.projectPrefs(includeDefaults: true)
        XCTAssertNotNil(all.first { $0.projectID == p.id }?.mode)
        let set = try await a.patchProjectPrefs(p.id, revision: all.first { $0.projectID == p.id }?.revision ?? 0, ProjectPrefsPatch(mode: "classic"))
        XCTAssertEqual(set.projectMode, .classic)
        XCTAssertEqual(set.modeSource, "user")

        // Settings hub.
        let prefs = try await a.preferences()
        let saved = try await a.savePreferences(prefs.withColorScheme(.dark))
        XCTAssertEqual(saved.appearance.scheme, .dark)
        let keys = try await a.passkeys()
        XCTAssertFalse(keys.filter(\.isActive).isEmpty)
        let sessions = try await a.sessions()
        XCTAssertEqual(sessions.filter(\.current).count, 1)
        let pairing = try await a.pairRunner(label: "Mac mini")
        XCTAssertFalse(pairing.code.isEmpty)
    }
}
