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

    // MARK: Absolute dates (card 8DB7E4F8)
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    func testNumericDateWithAm() {
        let p = parse("Steuer abgeben am 15.12.")
        XCTAssertEqual(p.title, "Steuer abgeben"); XCTAssertEqual(p.due, date(2026, 12, 15)); XCTAssertFalse(p.hasTime)
        XCTAssertEqual(p.recognized, ["am 15.12."])
    }
    func testNumericDateWithTrailingDotNeedsNoAm() {
        let p = parse("Geburtstag 5.11.")
        XCTAssertEqual(p.title, "Geburtstag"); XCTAssertEqual(p.due, date(2026, 11, 5))
    }
    func testNumericDateWithYear() {
        XCTAssertEqual(parse("Urlaub 24.12.2026").due, date(2026, 12, 24))
        XCTAssertEqual(parse("Urlaub 24.12.2027").due, date(2027, 12, 24))
        XCTAssertEqual(parse("Urlaub am 24.12.27").due, date(2027, 12, 24))
        XCTAssertEqual(parse("Urlaub 24.12.2027").title, "Urlaub")
    }
    func testPastDateRollsToNextYear() {
        XCTAssertEqual(parse("Geburtstag am 5.10.").due, date(2027, 10, 5))
        XCTAssertEqual(parse("Heute-Datum 30.10.").due, date(2026, 10, 30), "today stays today")
    }
    func testExplicitPastYearIsKept() { XCTAssertEqual(parse("Altlast 1.3.2026").due, date(2026, 3, 1)) }
    func testMonthNameDates() {
        let p = parse("Termin am 3. Dezember")
        XCTAssertEqual(p.title, "Termin"); XCTAssertEqual(p.due, date(2026, 12, 3)); XCTAssertEqual(p.recognized, ["am 3. Dezember"])
        XCTAssertEqual(parse("Fest 24. Dez.").due, date(2026, 12, 24))
        XCTAssertEqual(parse("Neujahr 1. Januar").due, date(2027, 1, 1))
        XCTAssertEqual(parse("Frist 15. März").due, date(2027, 3, 15))
        XCTAssertEqual(parse("Frist 15. maerz 2028").due, date(2028, 3, 15))
        XCTAssertEqual(parse("Frist 15. März 2028").title, "Frist")
    }
    func testDateWithTimeAndRest() {
        let p = parse("Zahnarzt am 15.12. um 9 Uhr #Privat p2")
        XCTAssertEqual(p.title, "Zahnarzt"); XCTAssertEqual(p.due, date(2026, 12, 15, 9)); XCTAssertTrue(p.hasTime)
        XCTAssertEqual(p.projectToken, "Privat"); XCTAssertEqual(p.priority, 2)
    }
    func testNumbersAreNotDates() {
        XCTAssertEqual(parse("Kaffee 3.50").title, "Kaffee 3.50"); XCTAssertNil(parse("Kaffee 3.50").due)
        XCTAssertEqual(parse("Version 2.1 testen").title, "Version 2.1 testen"); XCTAssertNil(parse("Version 2.1 testen").due)
        XCTAssertEqual(parse("Seite 3. Absatz").title, "Seite 3. Absatz"); XCTAssertNil(parse("Seite 3. Absatz").due)
    }
    func testInvalidDatesStayInTitle() {
        for s in ["Test am 31.2.", "Test am 32.1.", "Test am 15.13.", "Test am 0.5.", "Test 30. Februar"] {
            let p = parse(s); XCTAssertNil(p.due, s); XCTAssertEqual(p.title, s, s)
        }
    }
    func testLeapDayRollsToNextLeapYear() {
        XCTAssertEqual(parse("Schalttag 29.2.").due, date(2028, 2, 29))
    }
}
