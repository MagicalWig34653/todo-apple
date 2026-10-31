import XCTest
@testable import TodoCore

final class PushTests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let tid = UUID(), pid = UUID(), sid = UUID(), did = UUID()

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
    private var deviceJSON: String {
        #"{"id":"\#(did)","platform":"ios","environment":"sandbox","bundleId":"de.linolaske.todo","appVersion":"0.1.0","locale":"de-DE","createdAt":"2026-10-31T10:00:00Z","lastSeenAt":"2026-10-31T10:00:00.500Z"}"#
    }

    func testTokenHexAndValidation() {
        XCTAssertEqual(PushToken.hex(Data([0x00, 0xAB, 0x0f, 0xff])), "00ab0fff")
        XCTAssertFalse(PushToken.isValid("abcd"))
        XCTAssertTrue(PushToken.isValid(String(repeating: "a1", count: 32)))
        XCTAssertFalse(PushToken.isValid(String(repeating: "zz", count: 32)))
    }

    func testRegisterDeviceRequestAndDecoding() async throws {
        reply(201, deviceJSON)
        let token = String(repeating: "ab", count: 32)
        let d = try await client.registerPushDevice(PushRegistration(
            token: token, platform: .ios, environment: .sandbox, bundleId: "de.linolaske.todo", appVersion: "0.1.0", locale: "de-DE"))
        XCTAssertEqual(last.httpMethod, "POST"); XCTAssertEqual(last.url?.path, "/v1/push/devices")
        XCTAssertEqual(last.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let b = body(last)
        XCTAssertEqual(b["token"] as? String, token); XCTAssertEqual(b["platform"] as? String, "ios")
        XCTAssertEqual(b["environment"] as? String, "sandbox"); XCTAssertEqual(b["bundleId"] as? String, "de.linolaske.todo")
        XCTAssertEqual(b["locale"] as? String, "de-DE")
        XCTAssertEqual(d.id, did); XCTAssertEqual(d.environment, .sandbox)
    }

    func testListAndRevokeDevices() async throws {
        reply("[\(deviceJSON)]")
        let list = try await client.pushDevices()
        XCTAssertEqual(last.url?.path, "/v1/push/devices"); XCTAssertEqual(list.count, 1)
        reply(204, "")
        try await client.revokePushDevice(did)
        XCTAssertEqual(last.httpMethod, "DELETE"); XCTAssertEqual(last.url?.path, "/v1/push/devices/\(did.uuidString.lowercased())")
    }

    func testPrefsGetAndPartialUpdate() async throws {
        reply(#"{"categories":{"reminders":true,"agent_questions":true,"agent_reviews":true,"assignments":false,"comments":false},"showContent":false,"badge":true}"#)
        let p = try await client.pushPrefs()
        XCTAssertEqual(last.url?.path, "/v1/me/push-prefs")
        XCTAssertEqual(p, PushPrefs())
        reply(#"{"categories":{"reminders":true,"agent_questions":false,"agent_reviews":true,"assignments":false,"comments":true},"showContent":true,"badge":true}"#)
        let u = try await client.updatePushPrefs(PushPrefsUpdate(categories: [.agentQuestions: false, .comments: true], showContent: true))
        XCTAssertEqual(last.httpMethod, "POST")
        let b = body(last)
        XCTAssertEqual((b["categories"] as? [String: Bool])?["agent_questions"], false)
        XCTAssertEqual((b["categories"] as? [String: Bool])?["comments"], true)
        XCTAssertEqual(b["showContent"] as? Bool, true)
        XCTAssertNil(b["badge"], "unset fields are not sent")
        XCTAssertFalse(u.categories.agentQuestions); XCTAssertTrue(u.categories.comments); XCTAssertTrue(u.showContent)
        XCTAssertFalse(u.categories[.agentQuestions])
    }

    func testOlderServerAnswers404() async {
        reply(404, #"{"reason":"not_found"}"#)
        do { _ = try await client.pushPrefs(); XCTFail("expected error") }
        catch { XCTAssertTrue(APIClient.isPushUnavailable(error)) }
        do { _ = try await client.registerPushDevice(PushRegistration(token: "t", platform: .macos, environment: .production, bundleId: "b")); XCTFail() }
        catch { XCTAssertTrue(APIClient.isPushUnavailable(error)) }
        XCTAssertFalse(APIClient.isPushUnavailable(APIError.server(status: 500, reason: nil)))
    }

    func testInvalidTokenIsInvalidInput() async {
        reply(400, #"{"reason":"invalid_token"}"#)
        do { _ = try await client.registerPushDevice(PushRegistration(token: "x", platform: .ios, environment: .sandbox, bundleId: "b")); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .invalidInput(reason: "invalid_token")) }
    }

    // MARK: payload mapping

    private func info(kind: String, task: UUID? = nil, project: UUID? = nil, subject: UUID? = nil, category: String? = nil, badge: Int? = nil) -> [AnyHashable: Any] {
        var aps: [String: Any] = ["alert": ["title": "x"], "mutable-content": 1]
        if let category { aps["category"] = category }
        if let badge { aps["badge"] = badge }
        var d: [AnyHashable: Any] = ["aps": aps, "kind": kind]
        if let task { d["taskID"] = task.uuidString }
        if let project { d["projectID"] = project.uuidString }
        if let subject { d["subjectID"] = subject.uuidString }
        return d
    }

    func testPayloadParsingAndLinks() {
        let r = PushPayload(userInfo: info(kind: "reminder", task: tid, project: pid, category: "TODO_REMINDER", badge: 3))
        XCTAssertEqual(r.kind, .reminder); XCTAssertEqual(r.taskID, tid); XCTAssertEqual(r.badge, 3)
        XCTAssertEqual(r.category, "TODO_REMINDER")
        XCTAssertEqual(r.link, .task(taskID: tid, projectID: pid))
        XCTAssertEqual(PushPayload(userInfo: info(kind: "comment", task: tid, project: pid, subject: sid)).link, .task(taskID: tid, projectID: pid))
        XCTAssertEqual(PushPayload(userInfo: info(kind: "question", task: tid, project: pid, subject: sid)).link, .commandCenter(taskID: tid, projectID: pid))
        XCTAssertEqual(PushPayload(userInfo: info(kind: "review", task: tid)).link, .commandCenter(taskID: tid, projectID: nil))
        XCTAssertEqual(PushPayload(userInfo: info(kind: "review")).link, .commandCenter(taskID: nil, projectID: nil))
        XCTAssertEqual(PushPayload(userInfo: info(kind: "reminder", project: pid)).link, .project(pid))
        XCTAssertNil(PushPayload(userInfo: info(kind: "test")).link)
    }

    func testPayloadIsTolerant() {
        let p = PushPayload(userInfo: ["kind": "future", "taskID": "not-a-uuid", "aps": ["badge": "x"]])
        XCTAssertNil(p.kind); XCTAssertNil(p.taskID); XCTAssertNil(p.badge); XCTAssertNil(p.link)
        XCTAssertNil(PushPayload(userInfo: [:]).link)
    }

    func testResponseActions() {
        let reminder = PushPayload(userInfo: info(kind: "reminder", task: tid, project: pid))
        XCTAssertEqual(PushResponseAction.resolve(actionIdentifier: PushIdentifiers.actionDone, payload: reminder), .markDone(taskID: tid, projectID: pid))
        XCTAssertEqual(PushResponseAction.resolve(actionIdentifier: PushIdentifiers.actionSnooze, payload: reminder), .snooze(taskID: tid))
        XCTAssertEqual(PushResponseAction.resolve(actionIdentifier: PushIdentifiers.systemDefault, payload: reminder), .open(.task(taskID: tid, projectID: pid)))
        XCTAssertEqual(PushResponseAction.resolve(actionIdentifier: PushIdentifiers.systemDismiss, payload: reminder), .none)
        let q = PushPayload(userInfo: info(kind: "question", task: tid, project: pid))
        XCTAssertEqual(PushResponseAction.resolve(actionIdentifier: PushIdentifiers.actionAnswer, payload: q), .open(.commandCenter(taskID: tid, projectID: pid)))
        // Done/snooze are only valid for reminders.
        XCTAssertEqual(PushResponseAction.resolve(actionIdentifier: PushIdentifiers.actionDone, payload: q), .none)
        XCTAssertEqual(PushResponseAction.resolve(actionIdentifier: PushIdentifiers.systemDefault, payload: PushPayload(userInfo: info(kind: "test"))), .none)
    }
}
