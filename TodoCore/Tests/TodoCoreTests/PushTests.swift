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

    // MARK: confirmations / daily brief prefs (contract push.yaml 1.1.0)

    func testPrefsDecodeNewKeysFromServer() async throws {
        reply(#"{"categories":{"reminders":true,"agent_questions":true,"agent_reviews":true,"assignments":false,"comments":false,"confirmations":false,"daily_brief":true},"showContent":false,"badge":true,"dailyBriefHour":7}"#)
        let p = try await client.pushPrefs()
        XCTAssertFalse(p.categories.confirmations)
        XCTAssertTrue(p.categories.dailyBrief)
        XCTAssertFalse(p.categories[.confirmations])
        XCTAssertTrue(p.categories[.dailyBrief])
        XCTAssertEqual(p.dailyBriefHour, 7)
    }

    func testPrefsFromOlderServerKeepDefaults() async throws {
        // Server before contract 1.1.0: none of the new keys exist.
        reply(#"{"categories":{"reminders":false,"agent_questions":true,"agent_reviews":true,"assignments":false,"comments":true},"showContent":true,"badge":false}"#)
        let p = try await client.pushPrefs()
        XCTAssertFalse(p.categories.reminders); XCTAssertTrue(p.categories.comments)
        XCTAssertTrue(p.categories.confirmations, "default on")
        XCTAssertFalse(p.categories.dailyBrief, "default off")
        XCTAssertNil(p.dailyBriefHour)
        XCTAssertEqual(PushPrefs().categories.confirmations, true)
        XCTAssertEqual(PushPrefs().categories.dailyBrief, false)
        XCTAssertNil(PushPrefs().dailyBriefHour)
    }

    func testPrefsIgnoreUnknownKeysAndNullHour() async throws {
        reply(#"{"categories":{"reminders":true,"agent_questions":true,"agent_reviews":true,"assignments":false,"comments":false,"confirmations":true,"daily_brief":false,"future_category":true},"showContent":false,"badge":true,"dailyBriefHour":null,"somethingNew":{"a":1}}"#)
        let p = try await client.pushPrefs()
        XCTAssertNil(p.dailyBriefHour)
        XCTAssertTrue(p.categories.confirmations); XCTAssertFalse(p.categories.dailyBrief)
    }

    func testPrefsUpdateSendsOnlySetFields() async throws {
        reply(#"{"categories":{"reminders":true,"agent_questions":true,"agent_reviews":true,"assignments":false,"comments":false,"confirmations":true,"daily_brief":true},"showContent":false,"badge":true,"dailyBriefHour":6}"#)
        let u = try await client.updatePushPrefs(PushPrefsUpdate(categories: [.dailyBrief: true], dailyBriefHour: 6))
        let b = body(last)
        XCTAssertEqual((b["categories"] as? [String: Bool]), ["daily_brief": true], "only the changed category, JSON key daily_brief")
        XCTAssertEqual(b["dailyBriefHour"] as? Int, 6)
        XCTAssertNil(b["showContent"]); XCTAssertNil(b["badge"])
        XCTAssertTrue(u.categories.dailyBrief); XCTAssertEqual(u.dailyBriefHour, 6)

        _ = try await client.updatePushPrefs(PushPrefsUpdate(categories: [.confirmations: false]))
        let c = body(last)
        XCTAssertEqual((c["categories"] as? [String: Bool]), ["confirmations": false])
        XCTAssertNil(c["dailyBriefHour"], "unset hour is not sent")

        _ = try await client.updatePushPrefs(PushPrefsUpdate(badge: false))
        let d = body(last)
        XCTAssertNil(d["categories"]); XCTAssertNil(d["dailyBriefHour"])
    }

    func testBriefSettingsSupportIsDetectedFromServerAnswer() async throws {
        reply(#"{"categories":{"reminders":true,"agent_questions":true,"agent_reviews":true,"assignments":false,"comments":false},"showContent":false,"badge":true}"#)
        let old = try await client.pushPrefs()
        XCTAssertFalse(old.supportsBriefSettings, "server before 1.1.0: confirmation/brief switches stay hidden")
        reply(#"{"categories":{"reminders":true,"agent_questions":true,"agent_reviews":true,"assignments":false,"comments":false,"confirmations":true,"daily_brief":false},"showContent":false,"badge":true,"dailyBriefHour":8}"#)
        let current = try await client.pushPrefs()
        XCTAssertTrue(current.supportsBriefSettings)
        XCTAssertFalse(PushPrefs().supportsBriefSettings)
    }

    // MARK: daily brief hour (UTC on the server, local time in the UI)

    private func zone(_ id: String) -> TimeZone { TimeZone(identifier: id)! }
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testDailyBriefOptionsCoverAllUTCHoursSortedByLocalTime() {
        let options = DailyBriefHour.options(now: date("2026-11-20T12:00:00Z"), timeZone: zone("Europe/Berlin"))
        XCTAssertEqual(options.count, 24)
        XCTAssertEqual(Set(options.map(\.utcHour)), Set(0...23))
        XCTAssertEqual(options.map(\.localMinutes), options.map(\.localMinutes).sorted())
        // Winter: Berlin = UTC+1.
        XCTAssertEqual(options.first { $0.utcHour == 8 }?.localMinutes, 9 * 60)
        XCTAssertEqual(options.first { $0.utcHour == 23 }?.localMinutes, 0)
        XCTAssertEqual(options.first?.utcHour, 23)
    }

    func testDailyBriefOptionsFollowDaylightSavingAndHalfHourZones() {
        let summer = DailyBriefHour.options(now: date("2026-07-20T12:00:00Z"), timeZone: zone("Europe/Berlin"))
        XCTAssertEqual(summer.first { $0.utcHour == 8 }?.localMinutes, 10 * 60, "UTC+2 in summer")
        let india = DailyBriefHour.options(now: date("2026-11-20T12:00:00Z"), timeZone: zone("Asia/Kolkata"))
        XCTAssertEqual(india.first { $0.utcHour == 8 }?.localMinutes, 13 * 60 + 30)
        XCTAssertEqual(DailyBriefHour.localMinutes(utcHour: 8, now: date("2026-11-20T12:00:00Z"), timeZone: zone("America/New_York")), 3 * 60)
    }

    func testDailyBriefHourDefaultAndClamp() {
        XCTAssertEqual(DailyBriefHour.defaultUTCHour, 8)
        XCTAssertEqual(DailyBriefHour.effective(nil), 8)
        XCTAssertEqual(DailyBriefHour.effective(5), 5)
        XCTAssertEqual(DailyBriefHour.effective(99), 8, "out-of-range server value falls back to the default")
    }

    func testCategoryRawValuesMatchContract() {
        XCTAssertEqual(PushCategory.confirmations.rawValue, "confirmations")
        XCTAssertEqual(PushCategory.dailyBrief.rawValue, "daily_brief")
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

    /// The exact bytes `PushMessage.payload()` of the backend sends (sorted keys, uppercase UUIDs), decoded the way
    /// APNs hands them to the app as `userInfo`.
    func testBackendPayloadBytesResolveToTaskLink() throws {
        let json = #"{"aps":{"alert":{"body":"Eine Aufgabe ist fällig.","title":"Erinnerung"},"badge":2,"category":"TODO_REMINDER","mutable-content":1,"sound":"default","thread-id":"\#(tid.uuidString)"},"kind":"reminder","projectID":"\#(pid.uuidString)","taskID":"\#(tid.uuidString)"}"#
        let userInfo = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [AnyHashable: Any])
        let payload = PushPayload(userInfo: userInfo)
        XCTAssertEqual(payload.badge, 2)
        XCTAssertEqual(PushResponseAction.resolve(actionIdentifier: PushIdentifiers.systemDefault, payload: payload),
                       .open(.task(taskID: tid, projectID: pid)))
    }

    /// Real backend forms (`deliverConfirmation`, `deliverDailyBrief`): no taskID/projectID, sorted keys.
    func testBackendActionRequestPayloadOpensCommandCenter() throws {
        let json = #"{"aps":{"alert":{"body":"Ein Agent wartet auf deine Bestätigung.","title":"Bestätigung nötig"},"badge":1,"category":"TODO_CONFIRMATION","mutable-content":1,"sound":"default"},"kind":"action_request","subjectID":"\#(sid.uuidString)"}"#
        let userInfo = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [AnyHashable: Any])
        let payload = PushPayload(userInfo: userInfo)
        XCTAssertEqual(payload.kind, .actionRequest)
        XCTAssertEqual(payload.subjectID, sid)
        XCTAssertNil(payload.taskID); XCTAssertNil(payload.projectID)
        XCTAssertEqual(payload.category, PushIdentifiers.confirmation)
        XCTAssertEqual(payload.category, "TODO_CONFIRMATION")
        XCTAssertEqual(payload.badge, 1)
        XCTAssertEqual(payload.link, .commandCenter(taskID: nil, projectID: nil))
        XCTAssertEqual(PushResponseAction.resolve(actionIdentifier: PushIdentifiers.systemDefault, payload: payload),
                       .open(.commandCenter(taskID: nil, projectID: nil)))
        XCTAssertEqual(PushResponseAction.resolve(actionIdentifier: PushIdentifiers.actionDone, payload: payload), .none)
        XCTAssertEqual(PushResponseAction.resolve(actionIdentifier: PushIdentifiers.systemDismiss, payload: payload), .none)
    }

    func testBackendDailyBriefPayloadOpensCommandCenter() throws {
        let json = #"{"aps":{"alert":{"body":"3 offen, 1 fällig, 2 Rückfragen","title":"Tagesbericht"},"badge":2,"category":"TODO_DAILY_BRIEF","mutable-content":1,"sound":"default"},"kind":"daily_brief"}"#
        let userInfo = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [AnyHashable: Any])
        let payload = PushPayload(userInfo: userInfo)
        XCTAssertEqual(payload.kind, .dailyBrief)
        XCTAssertNil(payload.taskID); XCTAssertNil(payload.projectID); XCTAssertNil(payload.subjectID)
        XCTAssertEqual(payload.category, PushIdentifiers.dailyBrief)
        XCTAssertEqual(payload.category, "TODO_DAILY_BRIEF")
        XCTAssertEqual(payload.link, .commandCenter(taskID: nil, projectID: nil))
        XCTAssertEqual(PushResponseAction.resolve(actionIdentifier: PushIdentifiers.systemDefault, payload: payload),
                       .open(.commandCenter(taskID: nil, projectID: nil)))
    }

    func testNewKindsNeverNeedIDsAndUnknownKindsStayNil() {
        XCTAssertEqual(PushPayload(userInfo: info(kind: "action_request", subject: sid)).link, .commandCenter(taskID: nil, projectID: nil))
        XCTAssertEqual(PushPayload(userInfo: info(kind: "daily_brief")).link, .commandCenter(taskID: nil, projectID: nil))
        XCTAssertNil(PushPayload(userInfo: info(kind: "action_request_v2")).link)
        XCTAssertNil(PushPayload(userInfo: info(kind: "weekly_brief")).kind)
        XCTAssertNil(PushPayload(userInfo: info(kind: "test")).link, "test still opens nothing")
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
