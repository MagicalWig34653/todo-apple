import XCTest
@testable import TodoCore

/// Calendar client side, part 1 (card 8CECAD24, contracts planning-ext 1.2.0 and sync 1.5.0): the additive planning
/// fields, the schedule wire shapes and the typed errors. The pure calendar rules are in `CalendarRulesTests`.
final class CalendarScheduleTests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let tid = UUID(), pid = UUID()
    private let iso = ISO8601DateFormatter()

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
    private func taskJSON(version: Int = 2, status: String = "open") -> String {
        #"{"id":"\#(tid)","projectID":"\#(pid)","title":"T","description":"","status":"\#(status)","version":\#(version)}"#
    }
    private func date(_ s: String) -> Date { iso.date(from: s)! }
    private func json(_ data: some Encodable) throws -> [String: Any] {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: e.encode(data)) as? [String: Any] ?? [:]
    }

    // MARK: PlanningData: additive and tolerant

    func testPlanningDataDecodesNewFieldsAndToleratesOldServers() throws {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let full = #"{"dueAt":null,"plannedAt":"2026-11-23T09:00:00Z","plannedMinutes":45,"plannedAllDay":false,"priority":2,"reminders":[],"autoStart":true,"autoStartedAt":"2026-11-23T09:00:05Z"}"#
        let p = try d.decode(PlanningData.self, from: Data(full.utf8))
        XCTAssertEqual(p.plannedMinutes, 45)
        XCTAssertFalse(p.plannedAllDay)
        XCTAssertTrue(p.autoStart)
        XCTAssertEqual(p.autoStartedAt, date("2026-11-23T09:00:05Z"))

        // Server before 1.1.0 / Sync before 1.5.0: none of the keys exist.
        let old = try d.decode(PlanningData.self, from: Data(#"{"plannedAt":"2026-11-23T09:00:00Z","priority":1,"reminders":[]}"#.utf8))
        XCTAssertNil(old.plannedMinutes)
        XCTAssertFalse(old.plannedAllDay)
        XCTAssertFalse(old.autoStart)
        XCTAssertNil(old.autoStartedAt)
        XCTAssertEqual(old.priority, 1)
    }

    func testPlanningDataKeepsDurationAndAllDayInARoundTripButNeverSendsReadOnlyState() throws {
        let p = PlanningData(plannedAt: date("2026-11-23T09:00:00Z"), plannedMinutes: 90, plannedAllDay: true, autoStart: true,
                             autoStartedAt: date("2026-11-23T09:00:05Z"))
        let wire = try json(p)
        XCTAssertEqual(wire["plannedMinutes"] as? Int, 90)
        XCTAssertEqual(wire["plannedAllDay"] as? Bool, true)
        XCTAssertNil(wire["autoStart"], "auto-start is only writable through PUT /v1/tasks/{id}/auto-start")
        XCTAssertNil(wire["autoStartedAt"])

        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let again = try d.decode(PlanningData.self, from: JSONSerialization.data(withJSONObject: wire))
        XCTAssertEqual(again.plannedMinutes, 90)
        XCTAssertTrue(again.plannedAllDay)
    }

    func testPlanningDataWithoutDurationOmitsTheKeySoTheServerKeepsIt() throws {
        // contracts: PUT adopts plannedMinutes only when the key is present (absent keeps, null clears).
        let wire = try json(PlanningData(dueAt: date("2026-11-23T09:00:00Z"), priority: 1))
        XCTAssertNil(wire["plannedMinutes"])
        XCTAssertEqual(wire["plannedAllDay"] as? Bool, false)
        XCTAssertTrue(wire["plannedAt"] is NSNull, "existing behaviour: cleared dates are explicit null")
    }

    func testSetPlanningPutKeepsAnExistingDurationInTheBodyWhenTheCallerCarriesIt() async throws {
        reply(#"{"task":\#(taskJSON()),"position":0,"priority":0,"reminders":[],"plannedAt":"2026-11-23T09:00:00Z","plannedMinutes":45,"plannedAllDay":false,"autoStart":false}"#)
        let loaded = try await client.planning(taskID: tid)
        XCTAssertEqual(loaded.planning.plannedMinutes, 45)
        var edited = loaded.planning
        edited.priority = 3
        _ = try await client.setPlanning(taskID: tid, edited)
        XCTAssertEqual(last.httpMethod, "PUT")
        XCTAssertEqual(body(last)["plannedMinutes"] as? Int, 45, "an edit of the priority must not drop the duration")
        XCTAssertEqual(body(last)["priority"] as? Int, 3)
    }

    func testPlanningTaskDecodesAutoStartFlatAndEncodesItBack() throws {
        let raw = #"{"task":\#(taskJSON()),"position":1,"priority":0,"reminders":[],"plannedAllDay":false,"autoStart":true,"autoStartedAt":"2026-11-23T09:00:05Z"}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let pt = try d.decode(PlanningTask.self, from: Data(raw.utf8))
        XCTAssertTrue(pt.planning.autoStart)
        let wire = try json(pt)
        XCTAssertEqual(wire["autoStart"] as? Bool, true, "the task shape keeps the server's read-only state")
        XCTAssertEqual(wire["autoStartedAt"] as? String, "2026-11-23T09:00:05Z")
    }

    func testSyncPlanningMutationLeavesDurationAndAllDayOutSoTheServerKeepsThem() throws {
        // Known gap (docs/CALENDAR.md): the queue does not carry the new fields yet, so a queued edit never clears them.
        let m = SyncMutation.planning(taskID: tid, PlanningData(plannedAt: date("2026-11-23T09:00:00Z"), priority: 1, plannedMinutes: 45, plannedAllDay: false))
        let wire = try json(m)
        XCTAssertNil(wire["plannedMinutes"])
        XCTAssertNil(wire["plannedAllDay"])
        XCTAssertEqual(wire["type"] as? String, "task.planning")
    }

    func testFeedPlanningDecodesNewFieldsAndTheStoreKeepsThem() throws {
        let raw = #"{"seq":1,"entityType":"task","entityID":"\#(tid)","kind":"upsert","task":\#(taskJSON()),"planning":{"plannedAt":"2026-11-23T09:00:00Z","plannedMinutes":60,"plannedAllDay":false,"priority":0,"reminders":[]}}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let change = try d.decode(SyncChange.self, from: Data(raw.utf8))
        XCTAssertEqual(change.planning?.plannedMinutes, 60)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let stored = try d.decode(PlanningData.self, from: e.encode(try XCTUnwrap(change.planning)))
        XCTAssertEqual(stored.plannedMinutes, 60, "SQLiteSyncStore and the outbox persist PlanningData through Codable")
    }

    // MARK: ScheduleUpdate encoding

    func testScheduleUpdateSendsOnlyTheKeysThatAreSet() throws {
        let start = date("2026-11-23T09:15:00Z")
        let a = try json(ScheduleUpdate(version: 4, SchedulePatch(plannedAt: .set(start))))
        XCTAssertEqual(Set(a.keys), ["version", "plannedAt"])
        XCTAssertEqual(a["version"] as? Int, 4)
        XCTAssertEqual(a["plannedAt"] as? String, "2026-11-23T09:15:00Z")

        let b = try json(ScheduleUpdate(version: 1, SchedulePatch(plannedMinutes: .set(45))))
        XCTAssertEqual(Set(b.keys), ["version", "plannedMinutes"])

        let c = try json(ScheduleUpdate(version: 1, SchedulePatch(plannedAllDay: false)))
        XCTAssertEqual(Set(c.keys), ["version", "plannedAllDay"], "false is a value, not an absent key")
        XCTAssertEqual(c["plannedAllDay"] as? Bool, false)

        let d = try json(ScheduleUpdate(version: 1, SchedulePatch()))
        XCTAssertEqual(Set(d.keys), ["version"])
    }

    func testScheduleUpdateNullClears() throws {
        let w = try json(ScheduleUpdate(version: 7, SchedulePatch(plannedAt: .clear, plannedMinutes: .clear)))
        XCTAssertTrue(w["plannedAt"] is NSNull)
        XCTAssertTrue(w["plannedMinutes"] is NSNull)
        XCTAssertNil(w["plannedAllDay"])
        XCTAssertEqual(w["version"] as? Int, 7)
    }

    // MARK: Decoding the backend answers

    private func entryJSON(extra: String = "") -> String {
        #"{"taskID":"\#(tid)","projectID":"\#(pid)","title":"Release vorbereiten","status":"open","version":3,"plannedAt":"2026-11-23T09:00:00Z","plannedMinutes":60,"plannedAllDay":false,"dueAt":"2026-11-23T09:30:00Z","blocked":false,"canEdit":true,"autoStart":true,"autoStartedAt":null,"jobState":"queued","repositoryKey":"github.com/x/y","conflicts":["after_due","repository_overlap"]\#(extra)}"#
    }

    func testScheduleDecodesEntriesFromTheBackendShape() async throws {
        reply(#"{"from":"2026-11-23T00:00:00Z","to":"2026-11-30T00:00:00Z","truncated":true,"items":[\#(entryJSON())]}"#)
        let from = date("2026-11-23T00:00:00Z"), to = date("2026-11-30T00:00:00Z")
        let r = try await client.schedule(from: from, to: to, projectID: pid, limit: 100)
        XCTAssertEqual(last.httpMethod, "GET")
        XCTAssertEqual(last.url?.path, "/v1/planning/schedule")
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: last.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["from"], "2026-11-23T00:00:00Z")
        XCTAssertEqual(q["to"], "2026-11-30T00:00:00Z")
        XCTAssertEqual(q["projectID"], pid.uuidString)
        XCTAssertEqual(q["limit"], "100")
        XCTAssertTrue(r.truncated)
        let e = try XCTUnwrap(r.items.first)
        XCTAssertEqual(e.taskID, tid)
        XCTAssertEqual(e.id, tid)
        XCTAssertEqual(e.version, 3)
        XCTAssertEqual(e.plannedMinutes, 60)
        XCTAssertTrue(e.canEdit)
        XCTAssertTrue(e.autoStart)
        XCTAssertNil(e.autoStartedAt)
        XCTAssertEqual(e.jobState, "queued")
        XCTAssertEqual(e.repositoryKey, "github.com/x/y")
        XCTAssertEqual(e.conflicts, [.afterDue, .repositoryOverlap])
    }

    func testScheduleWithoutOptionalQueryItemsSendsOnlyTheWindow() async throws {
        reply(#"{"from":"2026-11-23T00:00:00Z","to":"2026-11-24T00:00:00Z","truncated":false,"items":[]}"#)
        _ = try await client.schedule(from: date("2026-11-23T00:00:00Z"), to: date("2026-11-24T00:00:00Z"))
        let names = Set((URLComponents(url: last.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name))
        XCTAssertEqual(names, ["from", "to"])
    }

    func testScheduleEntryToleratesMissingOptionalKeysAndUnknownConflicts() throws {
        // Read-only is the safe default if canEdit is missing; unknown conflict codes from a newer server are dropped.
        let raw = #"{"taskID":"\#(tid)","projectID":"\#(pid)","title":"T","status":"in_review","version":1,"conflicts":["after_due","brand_new"]}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let e = try d.decode(ScheduleEntry.self, from: Data(raw.utf8))
        XCTAssertFalse(e.canEdit)
        XCTAssertFalse(e.plannedAllDay)
        XCTAssertFalse(e.blocked)
        XCTAssertFalse(e.autoStart)
        XCTAssertNil(e.plannedAt)
        XCTAssertEqual(e.status, "in_review")
        XCTAssertEqual(e.conflicts, [.afterDue])
    }

    func testUnscheduledReturnsPlanningTasksWithQuery() async throws {
        reply(#"[{"task":\#(taskJSON()),"position":0,"priority":2,"reminders":[],"plannedAllDay":false,"autoStart":false,"dueAt":"2026-11-25T08:00:00Z"}]"#)
        let list = try await client.unscheduled(projectID: pid, limit: 50)
        XCTAssertEqual(last.url?.path, "/v1/planning/unscheduled")
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: last.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["projectID"], pid.uuidString)
        XCTAssertEqual(q["limit"], "50")
        XCTAssertEqual(list.first?.planning.priority, 2)
        XCTAssertNil(list.first?.planning.plannedAt)
    }

    // MARK: PATCH /v1/tasks/{id}/schedule

    func testUpdateScheduleSendsAPatchWithTheVersion() async throws {
        reply(#"{"task":\#(taskJSON(version: 5)),"position":0,"priority":0,"reminders":[],"plannedAt":"2026-11-23T09:15:00Z","plannedMinutes":30,"plannedAllDay":false,"autoStart":false}"#)
        let result = try await client.updateSchedule(taskID: tid, version: 4, SchedulePatch(plannedAt: .set(date("2026-11-23T09:15:00Z")), plannedAllDay: false))
        XCTAssertEqual(last.httpMethod, "PATCH")
        XCTAssertEqual(last.url?.path, "/v1/tasks/\(tid.uuidString)/schedule")
        XCTAssertEqual(last.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(last.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let b = body(last)
        XCTAssertEqual(b["version"] as? Int, 4)
        XCTAssertEqual(b["plannedAt"] as? String, "2026-11-23T09:15:00Z")
        XCTAssertEqual(b["plannedAllDay"] as? Bool, false)
        XCTAssertNil(b["plannedMinutes"])
        XCTAssertNil(b["dueAt"], "dragging never touches the due date")
        XCTAssertEqual(result.task.version, 5, "the answer carries the new task version for the next patch")
        XCTAssertEqual(result.planning.plannedMinutes, 30)
    }

    func testUpdateScheduleMapsEveryDocumentedError() async throws {
        let cases: [(Int, String, ScheduleError)] = [
            (409, "version_conflict", .versionConflict),
            (409, "task_done", .taskDone),
            (400, "invalid_planned_minutes", .invalidPlannedMinutes),
            (400, "all_day_requires_planned_at", .allDayRequiresPlannedAt),
            (400, "recurrence_requires_date", .recurrenceRequiresDate),
            (400, "invalid_schedule", .invalidSchedule),
            (403, "forbidden", .readOnly),
            (404, "not_found", .notFound),
        ]
        for (status, reason, expected) in cases {
            reply(status, #"{"error":true,"reason":"\#(reason)"}"#)
            do {
                _ = try await client.updateSchedule(taskID: tid, version: 1, SchedulePatch(plannedAt: .clear))
                XCTFail("\(reason) should throw")
            } catch let error as ScheduleError {
                XCTAssertEqual(error, expected, reason)
            }
        }
    }

    func testUpdateScheduleKeepsUnrelatedErrorsAsApiErrors() async throws {
        reply(401, #"{"error":true,"reason":"unauthorized"}"#)
        do {
            _ = try await client.updateSchedule(taskID: tid, version: 1, SchedulePatch(plannedAt: .clear))
            XCTFail("should throw")
        } catch let error as ScheduleError {
            XCTAssertEqual(error, .other(.unauthorized(reason: "unauthorized")))
            XCTAssertEqual(error.apiError, .unauthorized(reason: "unauthorized"))
        }
        MockURLProtocol.handler = { _ in (-1, Data()) }
        do {
            _ = try await client.updateSchedule(taskID: tid, version: 1, SchedulePatch(plannedAt: .clear))
            XCTFail("should throw")
        } catch let error as ScheduleError {
            guard case .other(.transport) = error else { return XCTFail("transport failure stays distinguishable: \(error)") }
        }
    }

    func testScheduleWindowErrors() async throws {
        let cases: [(Int, String, ScheduleError)] = [
            (400, "invalid_window", .invalidWindow), (400, "window_too_large", .windowTooLarge),
            (400, "invalid_limit", .invalidLimit), (429, "rate_limited", .rateLimited),
        ]
        for (status, reason, expected) in cases {
            reply(status, #"{"error":true,"reason":"\#(reason)"}"#)
            do {
                _ = try await client.schedule(from: date("2026-11-23T00:00:00Z"), to: date("2026-11-24T00:00:00Z"))
                XCTFail("\(reason) should throw")
            } catch let error as ScheduleError { XCTAssertEqual(error, expected, reason) }
        }
    }
}
