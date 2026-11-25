import XCTest
@testable import TodoCore

/// Extended recurrence rules (card A18F3FF7, contract planning-ext 1.3.0): `weekdays`, `basis`, `monthDay` and the
/// pass-through of fields this build does not know (`PUT` replaces the whole rule, so dropping them deletes them).
final class RecurrenceRuleTests: XCTestCase {
    /// A rule from a newer server: every known field plus fields no build knows yet, in every JSON shape.
    private let newer = #"{"frequency":"weekly","interval":2,"timeZone":"Europe/Berlin","until":"2027-12-31T00:00:00Z","weekdays":[1,4],"basis":"completion","skipHolidays":true,"offsetDays":-3,"ratio":2.5,"note":"x","nothing":null,"window":{"from":1,"tags":["a",false]}}"#

    private func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func reencoded(_ json: String) throws -> NSDictionary {
        let rule = try APIClient.decoder.decode(RecurrenceRule.self, from: Data(json.utf8))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try object(encoder.encode(rule))
    }

    func testDecodesWeekdaysBasisAndMonthDay() throws {
        let rule = try APIClient.decoder.decode(RecurrenceRule.self, from: Data(newer.utf8))
        XCTAssertEqual(rule.weekdays, [1, 4])
        XCTAssertEqual(rule.basis, .completion)
        XCTAssertNil(rule.monthDay)
        XCTAssertEqual(rule.interval, 2)
        XCTAssertNotNil(rule.until)
        let monthly = try APIClient.decoder.decode(RecurrenceRule.self, from: Data(#"{"frequency":"monthly","interval":1,"timeZone":"UTC","monthDay":31}"#.utf8))
        XCTAssertEqual(monthly.monthDay, 31)
        XCTAssertNil(monthly.weekdays)
        XCTAssertNil(monthly.basis, "absent = due, and it stays absent")
        XCTAssertEqual(Set(monthly.unknownFields.keys), [])
        XCTAssertEqual(Set(rule.unknownFields.keys), ["skipHolidays", "offsetDays", "ratio", "note", "nothing", "window"])
    }

    func testEncodesWeekdaysBasisAndMonthDay() throws {
        let rule = RecurrenceRule(frequency: .weekly, timeZone: "UTC", weekdays: [2, 5], basis: .completion)
        XCTAssertEqual(try object(JSONEncoder().encode(rule)),
                       ["frequency": "weekly", "interval": 1, "timeZone": "UTC", "weekdays": [2, 5], "basis": "completion"] as NSDictionary)
        let monthly = RecurrenceRule(frequency: .monthly, timeZone: "UTC", monthDay: 15)
        XCTAssertEqual(try object(JSONEncoder().encode(monthly)), ["frequency": "monthly", "interval": 1, "timeZone": "UTC", "monthDay": 15] as NSDictionary)
    }

    func testTogglingWeekdaysKeepsThemSortedAndDropsAnEmptyList() {
        var rule = RecurrenceRule(frequency: .weekly, timeZone: "UTC")
        rule.toggle(weekday: 4)
        rule.toggle(weekday: 1)
        XCTAssertEqual(rule.weekdays, [1, 4])
        rule.toggle(weekday: 9)
        XCTAssertEqual(rule.weekdays, [1, 4], "outside 1...7 is ignored (the server refuses it)")
        rule.toggle(weekday: 1)
        rule.toggle(weekday: 4)
        XCTAssertNil(rule.weekdays, "an empty list is invalid on the server")
        var monthly = RecurrenceRule(frequency: .monthly, timeZone: "UTC")
        monthly.toggle(weekday: 1)
        XCTAssertNil(monthly.weekdays, "weekdays only fit weekly rules")
    }

    func testSettingBasisAndMonthDayUsesNeutralValuesAsAbsent() {
        var rule = RecurrenceRule(frequency: .monthly, timeZone: "UTC")
        rule.set(basis: .completion)
        XCTAssertEqual(rule.basis, .completion)
        rule.set(basis: .due)
        XCTAssertNil(rule.basis)
        rule.set(monthDay: 31)
        XCTAssertEqual(rule.monthDay, 31)
        rule.set(monthDay: 40)
        XCTAssertEqual(rule.monthDay, 31)
        rule.set(monthDay: nil)
        XCTAssertNil(rule.monthDay)
        var weekly = RecurrenceRule(frequency: .weekly, timeZone: "UTC")
        weekly.set(monthDay: 3)
        XCTAssertNil(weekly.monthDay, "a month day only fits monthly rules")
    }

    func testChangingTheFrequencyKeepsWhatStillFits() throws {
        var rule = try APIClient.decoder.decode(RecurrenceRule.self, from: Data(newer.utf8))
        XCTAssertEqual(rule.changing(frequency: .weekly), rule, "same frequency: nothing changes, the interval stays")
        let monthly = rule.changing(frequency: .monthly)
        XCTAssertEqual(monthly.frequency, .monthly)
        XCTAssertEqual(monthly.interval, 1, "the interval counted weeks")
        XCTAssertNil(monthly.weekdays)
        XCTAssertEqual(monthly.basis, .completion)
        XCTAssertEqual(monthly.timeZone, "Europe/Berlin")
        XCTAssertEqual(monthly.until, rule.until)
        XCTAssertEqual(monthly.unknownFields, rule.unknownFields)
        rule = RecurrenceRule(frequency: .monthly, timeZone: "UTC", monthDay: 31)
        XCTAssertNil(rule.changing(frequency: .daily).monthDay)
    }

    func testNewAndUnknownFieldsSurviveADecodeAndEncodeRoundTrip() throws {
        XCTAssertEqual(try reencoded(newer), try object(Data(newer.utf8)))
    }

    func testMonthDaySurvivesARoundTrip() throws {
        let json = #"{"frequency":"monthly","interval":1,"timeZone":"UTC","monthDay":31}"#
        XCTAssertEqual(try reencoded(json), try object(Data(json.utf8)))
    }

    func testAnUnknownBasisValueSurvivesARoundTrip() throws {
        let json = #"{"frequency":"daily","interval":1,"timeZone":"UTC","basis":"start"}"#
        XCTAssertEqual(try reencoded(json), try object(Data(json.utf8)))
    }

    func testAPlainRuleStaysByteCompatible() throws {
        let json = #"{"frequency":"weekly","interval":2,"timeZone":"Europe/Berlin"}"#
        XCTAssertEqual(try reencoded(json), try object(Data(json.utf8)), "no new keys, no nulls")
    }

    /// Offline edits go through the persisted sync queue as a `task.planning` mutation.
    func testTheQueuedSyncMutationKeepsTheWholeRule() throws {
        let rule = try APIClient.decoder.decode(RecurrenceRule.self, from: Data(newer.utf8))
        let mutation = SyncMutation.planning(taskID: UUID(), PlanningData(dueAt: Date(timeIntervalSince1970: 1_800_000_000), recurrence: rule))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(mutation)
        let sent = try XCTUnwrap(try object(data)["recurrence"] as? NSDictionary)
        XCTAssertEqual(sent, try object(Data(newer.utf8)))
        XCTAssertEqual(try APIClient.decoder.decode(SyncMutation.self, from: data).planningData.recurrence, rule)
    }
}
