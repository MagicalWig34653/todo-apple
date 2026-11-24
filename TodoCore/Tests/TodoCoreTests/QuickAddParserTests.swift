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

    // MARK: Weekday recurrence and months (card 8DB7E4F8)
    func testEveryWeekdayIsWeeklyStartingNextOccurrence() {
        // Friday 30 Oct 2026: next Monday is 2 Nov.
        let p = parse("Teamrunde jeden Montag")
        XCTAssertEqual(p.title, "Teamrunde"); XCTAssertEqual(p.recurrence, .weekly)
        XCTAssertEqual(p.due, date(2026, 11, 2)); XCTAssertFalse(p.hasTime)
        XCTAssertEqual(p.recognized, ["jeden Montag"])
        XCTAssertEqual(parse("Putzen jeden Samstag").due, date(2026, 10, 31))
        XCTAssertEqual(parse("Putzen jeden Samstag").recurrence, .weekly)
    }
    func testEveryWeekdayWithFeminineArticleAndTime() {
        let p = parse("Sport jeden Dienstag um 18 Uhr #Privat")
        XCTAssertEqual(p.title, "Sport"); XCTAssertEqual(p.recurrence, .weekly)
        XCTAssertEqual(p.due, date(2026, 11, 3, 18)); XCTAssertTrue(p.hasTime); XCTAssertEqual(p.projectToken, "Privat")
    }
    func testEveryDayAndWeekStillWork() {
        XCTAssertEqual(parse("Pflanzen jeden Tag").recurrence, .daily)
        XCTAssertEqual(parse("Bericht jede Woche").recurrence, .weekly)
        XCTAssertEqual(parse("Miete jeden Monat").recurrence, .monthly)
        XCTAssertEqual(parse("Miete jeden Monat").title, "Miete")
    }
    func testInMonthsAddsCalendarMonths() {
        let p = parse("Zahnkontrolle in 2 Monaten")
        XCTAssertEqual(p.title, "Zahnkontrolle"); XCTAssertEqual(p.due, date(2026, 12, 30)); XCTAssertNil(p.recurrence)
        XCTAssertEqual(p.recognized, ["in 2 Monaten"])
        XCTAssertEqual(parse("Anruf in 1 Monat").due, date(2026, 11, 30))
        XCTAssertEqual(parse("Anruf in 4 Monaten").due, date(2027, 2, 28), "month end is clamped")
        XCTAssertEqual(parse("Anruf in 2 Monaten um 9 Uhr").due, date(2026, 12, 30, 9))
    }
    func testNextMonthIsFirstOfNextMonth() {
        let p = parse("Budget naechsten Monat")
        XCTAssertEqual(p.title, "Budget"); XCTAssertEqual(p.due, date(2026, 11, 1))
        XCTAssertEqual(parse("Budget nächsten Monat").due, date(2026, 11, 1))
        XCTAssertEqual(parse("Budget kommenden Monat").due, date(2026, 11, 1))
        XCTAssertEqual(parse("Budget nächsten Monat").recognized, ["nächsten Monat"])
    }
    func testNextMonthAtYearEnd() {
        let dec = QuickAddParser.parse("Plan naechsten Monat", now: date(2026, 12, 20, 10), calendar: cal)
        XCTAssertEqual(dec.due, date(2027, 1, 1))
    }
    func testUmlautSpellingsWork() {
        // Typed with real umlauts (keyboard) must behave like the ae/ue transliteration used in the rules.
        XCTAssertEqual(parse("Paket übermorgen").due, day(1)); XCTAssertEqual(parse("Paket übermorgen").title, "Paket")
        XCTAssertEqual(parse("Pflanzen täglich").recurrence, .daily)
        XCTAssertEqual(parse("Bericht wöchentlich").recurrence, .weekly)
        XCTAssertEqual(parse("Planung nächste Woche").due, day(2))
        XCTAssertEqual(parse("Sport am Wochenende").due, day(31, month: 10))
        XCTAssertEqual(parse("Frist 15. März").due, date(2027, 3, 15), "March spelling keeps working")
    }
    func testMonthWordsInTitlesAreNotDates() {
        for s in ["Monatsbericht schreiben", "Jeden Monat Geld sparen ist gut", "Wir reden in Monaten", "in 0 Monaten", "in 400 Monaten"] {
            let p = parse(s)
            if s == "Jeden Monat Geld sparen ist gut" { XCTAssertEqual(p.recurrence, .monthly); continue }
            XCTAssertNil(p.due, s); XCTAssertEqual(p.title, s, s)
        }
        XCTAssertEqual(parse("Jeden Vormittag lesen").title, "Jeden Vormittag lesen")
        XCTAssertNil(parse("Jeden Vormittag lesen").recurrence)
    }

    // MARK: Intervals (card 8DB7E4F8: "alle 2 Wochen")
    func testEveryNWeeksSetsInterval() {
        let p = parse("Pflanzen giessen alle 2 Wochen")
        XCTAssertEqual(p.title, "Pflanzen giessen"); XCTAssertEqual(p.recurrence, .weekly); XCTAssertEqual(p.recurrenceInterval, 2)
        XCTAssertEqual(p.due, day(30, month: 10), "recurrence without a date starts today (same rule as 'jeden Tag')")
        XCTAssertEqual(p.recognized, ["alle 2 Wochen"])
    }
    func testEveryNDaysAndMonths() {
        let d = parse("Tabletten alle 3 Tage"); XCTAssertEqual(d.recurrence, .daily); XCTAssertEqual(d.recurrenceInterval, 3); XCTAssertEqual(d.title, "Tabletten")
        let m = parse("Rechnung alle 2 Monate"); XCTAssertEqual(m.recurrence, .monthly); XCTAssertEqual(m.recurrenceInterval, 2); XCTAssertEqual(m.title, "Rechnung")
        let one = parse("Putzen alle 1 Woche"); XCTAssertEqual(one.recurrence, .weekly); XCTAssertEqual(one.recurrenceInterval, 1)
    }
    func testIntervalWordsAndOrdinals() {
        let a = parse("Backup alle zwei Wochen"); XCTAssertEqual(a.recurrence, .weekly); XCTAssertEqual(a.recurrenceInterval, 2); XCTAssertEqual(a.title, "Backup")
        let b = parse("Backup jede zweite Woche"); XCTAssertEqual(b.recurrence, .weekly); XCTAssertEqual(b.recurrenceInterval, 2); XCTAssertEqual(b.title, "Backup")
        let c = parse("Bericht jeden dritten Monat"); XCTAssertEqual(c.recurrence, .monthly); XCTAssertEqual(c.recurrenceInterval, 3)
        let d = parse("Wäsche jeden zweiten Tag"); XCTAssertEqual(d.recurrence, .daily); XCTAssertEqual(d.recurrenceInterval, 2)
    }
    func testEverySecondWeekdayStartsOnNextOccurrence() {
        let p = parse("Team-Sync jeden zweiten Montag um 9:30")
        XCTAssertEqual(p.title, "Team-Sync"); XCTAssertEqual(p.recurrence, .weekly); XCTAssertEqual(p.recurrenceInterval, 2)
        XCTAssertEqual(p.due, day(2, 9, 30)); XCTAssertTrue(p.hasTime)
    }
    func testIntervalDefaultsToOneAndRuleCarriesIt() {
        XCTAssertEqual(parse("Pflanzen jeden Tag").recurrenceInterval, 1)
        XCTAssertNil(parse("Milch kaufen").recurrenceRule)
        let rule = parse("Pflanzen alle 2 Wochen").recurrenceRule
        XCTAssertEqual(rule?.frequency, .weekly); XCTAssertEqual(rule?.interval, 2)
        XCTAssertEqual(parse("Pflanzen taeglich").recurrenceRule?.interval, 1)
    }
    func testIntervalPhrasesInTitlesAreNotRecurrence() {
        for s in ["Alle 2 Kinder abholen", "Alle Fenster putzen", "alle 0 Wochen", "alle 400 Wochen", "alle zwei Autos waschen", "Jeden zweiten Vormittag lesen"] {
            let p = parse(s)
            XCTAssertNil(p.recurrence, s); XCTAssertNil(p.due, s); XCTAssertEqual(p.title, s, s)
        }
    }
}
