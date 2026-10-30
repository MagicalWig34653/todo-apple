import XCTest
@testable import TodoCore

final class QuickAddParserTests: XCTestCase {
    private var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Berlin")!; c.locale = Locale(identifier: "de_DE"); return c }()
    // Friday 30 Oct 2026, 10:00
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 10))! }

    private func parse(_ s: String) -> QuickAddParse { QuickAddParser.parse(s, now: now, calendar: cal) }
    private func day(_ d: Int, _ h: Int? = nil, _ m: Int = 0, month: Int = 11) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: d, hour: h ?? 0, minute: m))!
    }

    func testPlainTitleUntouched() {
        let p = parse("Milch kaufen")
        XCTAssertEqual(p.title, "Milch kaufen"); XCTAssertNil(p.due); XCTAssertNil(p.priority)
    }
    func testTomorrowAndPriority() {
        let p = parse("Zahnarzt anrufen morgen p1")
        XCTAssertEqual(p.title, "Zahnarzt anrufen"); XCTAssertEqual(p.due, day(31, month: 10)); XCTAssertEqual(p.priority, 3)
    }
    func testTimeAndProjectAndLabel() {
        let p = parse("Meeting heute um 14:30 #Arbeit @dringend")
        XCTAssertEqual(p.title, "Meeting"); XCTAssertEqual(p.due, day(30, 14, 30, month: 10)); XCTAssertTrue(p.hasTime)
        XCTAssertEqual(p.projectToken, "Arbeit"); XCTAssertEqual(p.labelTokens, ["dringend"])
    }
    func testWeekdayWithAm() {
        let p = parse("Sport am Montag")
        XCTAssertEqual(p.title, "Sport"); XCTAssertEqual(p.due, day(2))
    }
    func testInDays() { XCTAssertEqual(parse("Rechnung in 3 Tagen").due, day(2)) }
    func testRecurrence() {
        let p = parse("Pflanzen giessen jeden Tag")
        XCTAssertEqual(p.title, "Pflanzen giessen"); XCTAssertEqual(p.recurrence, .daily); XCTAssertEqual(p.due, day(30, month: 10))
    }
    func testUhrForm() { let p = parse("Anruf morgen um 9 Uhr"); XCTAssertEqual(p.due, day(31, 9, month: 10)); XCTAssertEqual(p.title, "Anruf") }
    func testNextWeek() { XCTAssertEqual(parse("Planung naechste Woche").due, day(2)) }
}
