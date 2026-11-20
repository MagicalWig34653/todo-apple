import XCTest
@testable import TodoCore

/// Calendar client side, part 2 (card 8CECAD24): the pure rules without UI. Reference is the PWA (`web/src/lib/calendar.ts`,
/// ADR 0033 section 3); the difference is the time zone: the app shows the device's local time, the PWA Europe/Berlin.
final class CalendarRulesTests: XCTestCase {
    private func makeCalendar(_ zone: String = "Europe/Berlin", firstWeekday: Int = 2) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        c.locale = Locale(identifier: "de_DE")
        c.firstWeekday = firstWeekday  // after the locale, which would reset it
        return c
    }
    private var cal: Calendar { makeCalendar() }
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, calendar: Calendar? = nil) -> Date {
        (calendar ?? cal).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    private let task = UUID(), project = UUID()
    private func entry(
        _ title: String = "T", start: Date? = nil, minutes: Int? = nil, allDay: Bool = false, due: Date? = nil, status: String = "open",
        canEdit: Bool = true, repo: String? = nil, conflicts: [ScheduleConflict] = [], id: UUID = UUID()
    ) -> ScheduleEntry {
        ScheduleEntry(taskID: id, projectID: project, title: title, status: status, version: 1, plannedAt: start, plannedMinutes: minutes,
                      plannedAllDay: allDay, dueAt: due, canEdit: canEdit, repositoryKey: repo, conflicts: conflicts)
    }

    // MARK: 15-minute snapping and defaults

    func testSnapRoundsToQuarterHoursAndStaysInsideTheDay() {
        XCTAssertEqual(CalendarRules.snap(minutes: 0), 0)
        XCTAssertEqual(CalendarRules.snap(minutes: 7), 0)
        XCTAssertEqual(CalendarRules.snap(minutes: 8), 15)
        XCTAssertEqual(CalendarRules.snap(minutes: 22), 15)
        XCTAssertEqual(CalendarRules.snap(minutes: 23), 30)
        XCTAssertEqual(CalendarRules.snap(minutes: 9 * 60 + 53), 10 * 60)
        XCTAssertEqual(CalendarRules.snap(minutes: 1439), 1425, "the last slot starts at 23:45, 24:00 would be the next day")
        XCTAssertEqual(CalendarRules.snap(minutes: 5000), 1425)
        XCTAssertEqual(CalendarRules.snap(minutes: -20), 0)
    }

    func testDefaultDurationIs30MinutesAndEndFollowsTheDuration() {
        let start = at(2026, 11, 23, 9)
        XCTAssertEqual(CalendarRules.defaultMinutes, 30)
        XCTAssertEqual(entry(start: start).minutes, 30)
        XCTAssertEqual(entry(start: start).end, at(2026, 11, 23, 9, 30))
        XCTAssertEqual(entry(start: start, minutes: 90).end, at(2026, 11, 23, 10, 30))
        XCTAssertNil(entry().start)
        XCTAssertNil(entry().end)
    }

    // MARK: Windows in local time

    func testWeekWindowStartsOnMondayInLocalTime() throws {
        let w = CalendarWindow.week(containing: at(2026, 11, 25, 15), calendar: cal)  // a Wednesday
        XCTAssertEqual(w.from, at(2026, 11, 23))
        XCTAssertEqual(w.to, at(2026, 11, 30))
        XCTAssertEqual(w.days.count, 7)
        XCTAssertEqual(w.days.first, at(2026, 11, 23))
        XCTAssertEqual(w.days.last, at(2026, 11, 29))
        XCTAssertTrue(w.isWithinServerLimit)
    }

    func testWeekWindowFollowsTheCalendarsFirstWeekday() {
        let w = CalendarWindow.week(containing: at(2026, 11, 25, 15), calendar: makeCalendar(firstWeekday: 1))
        XCTAssertEqual(w.from, at(2026, 11, 22), "Sunday first (US locale)")
        XCTAssertEqual(w.days.count, 7)
    }

    func testWindowsStayAlignedToLocalMidnightAcrossDaylightSaving() {
        // Berlin ends daylight saving on Sunday 25 Oct 2026 (that day has 25 hours) and starts it on 29 Mar (23 hours).
        let autumn = CalendarWindow.week(containing: at(2026, 10, 22, 12), calendar: cal)
        XCTAssertEqual(autumn.days.count, 7)
        XCTAssertEqual(autumn.from, at(2026, 10, 19))
        XCTAssertEqual(autumn.to, at(2026, 10, 26))
        XCTAssertEqual(autumn.to.timeIntervalSince(autumn.from), 7 * 86_400 + 3_600)
        let spring = CalendarWindow.week(containing: at(2026, 3, 29, 12), calendar: cal)
        XCTAssertEqual(spring.to.timeIntervalSince(spring.from), 7 * 86_400 - 3_600)
        for d in spring.days { XCTAssertEqual(cal.startOfDay(for: d), d) }
    }

    func testDayWindowAndServerLimit() {
        let d = CalendarWindow.day(containing: at(2026, 11, 25, 15), calendar: cal)
        XCTAssertEqual(d.from, at(2026, 11, 25))
        XCTAssertEqual(d.to, at(2026, 11, 26))
        XCTAssertEqual(d.days, [at(2026, 11, 25)])
        let tooLong = CalendarWindow(from: at(2026, 11, 1), to: at(2026, 11, 1).addingTimeInterval(86_400 * 120), days: [])
        XCTAssertFalse(tooLong.isWithinServerLimit, "the server answers 400 window_too_large above 62 days")
    }

    // MARK: Assigning entries to days, columns and overlap

    func testEntriesLandOnTheirLocalDayNotTheUTCDay() {
        // 23:30 UTC on 23 Nov is 00:30 on 24 Nov in Berlin and 08:30 on 24 Nov in Tokyo, but still 23 Nov in Lisbon.
        let instant = Date(timeIntervalSince1970: 1_795_476_600)  // 2026-11-23T23:30:00Z
        let e = entry("Nacht", start: instant, minutes: 30)
        let berlin = makeCalendar("Europe/Berlin"), tokyo = makeCalendar("Asia/Tokyo"), lisbon = makeCalendar("Europe/Lisbon")
        XCTAssertEqual(CalendarLayout.content(for: at(2026, 11, 24, calendar: berlin), entries: [e], calendar: berlin).timed.map(\.startMinute), [30])
        XCTAssertEqual(CalendarLayout.content(for: at(2026, 11, 24, calendar: tokyo), entries: [e], calendar: tokyo).timed.map(\.startMinute), [8 * 60 + 30])
        XCTAssertEqual(CalendarLayout.content(for: at(2026, 11, 23, calendar: lisbon), entries: [e], calendar: lisbon).timed.map(\.startMinute), [23 * 60 + 30])
        XCTAssertTrue(CalendarLayout.content(for: at(2026, 11, 23, calendar: berlin), entries: [e], calendar: berlin).timed.isEmpty)
    }

    func testOverlappingBlocksStandSideBySide() {
        let a = entry("A", start: at(2026, 11, 23, 9), minutes: 60)
        let b = entry("B", start: at(2026, 11, 23, 9, 30), minutes: 60)
        let c = entry("C", start: at(2026, 11, 23, 10), minutes: 15)
        let d = entry("D", start: at(2026, 11, 23, 12))
        let content = CalendarLayout.content(for: at(2026, 11, 23), entries: [d, c, b, a], calendar: cal)
        let byTitle = Dictionary(uniqueKeysWithValues: content.timed.map { ($0.entry.title, $0) })
        XCTAssertEqual(content.timed.map(\.entry.title), ["A", "B", "C", "D"], "ordered by start")
        XCTAssertEqual(byTitle["A"]?.column, 0)
        XCTAssertEqual(byTitle["B"]?.column, 1)
        XCTAssertEqual(byTitle["C"]?.column, 0, "A has ended at 10:00, its column is free again")
        XCTAssertEqual([byTitle["A"]!, byTitle["B"]!, byTitle["C"]!].map(\.columnCount), [2, 2, 2], "one cluster shares its widest column count")
        XCTAssertEqual(byTitle["D"]?.column, 0)
        XCTAssertEqual(byTitle["D"]?.columnCount, 1, "a later, free block uses the full width")
        XCTAssertEqual(byTitle["A"]?.startMinute, 540)
        XCTAssertEqual(byTitle["A"]?.endMinute, 600)
        XCTAssertEqual(byTitle["D"]?.endMinute, 12 * 60 + 30, "default duration 30 minutes")
    }

    func testBlocksTouchingEndToStartAreNotOverlapping() {
        let a = entry("A", start: at(2026, 11, 23, 9), minutes: 30)
        let b = entry("B", start: at(2026, 11, 23, 9, 30), minutes: 30)
        let content = CalendarLayout.content(for: at(2026, 11, 23), entries: [a, b], calendar: cal)
        XCTAssertEqual(content.timed.map(\.columnCount), [1, 1])
    }

    func testVeryShortBlocksStayVisibleAndNeverExceedTheDay() {
        let tiny = entry("Kurz", start: at(2026, 11, 23, 9), minutes: 5)
        let late = entry("Spät", start: at(2026, 11, 23, 23, 30), minutes: 120)
        let content = CalendarLayout.content(for: at(2026, 11, 23), entries: [tiny, late], calendar: cal)
        let p = Dictionary(uniqueKeysWithValues: content.timed.map { ($0.entry.title, $0) })
        XCTAssertEqual(p["Kurz"]?.endMinute, 9 * 60 + 15, "drawn at least one 15-minute slot high")
        XCTAssertEqual(p["Spät"]?.endMinute, 1440, "clipped at midnight")
        // The part after midnight shows on the next day.
        let next = CalendarLayout.content(for: at(2026, 11, 24), entries: [late], calendar: cal)
        XCTAssertEqual(next.timed.first?.startMinute, 0)
        XCTAssertEqual(next.timed.first?.endMinute, 90)
    }

    func testBlocksUseTheWallClockOnADaylightSavingDay() {
        // 29 Mar 2026: 02:00 jumps to 03:00. A card at 03:00 local sits in the 03:00 row, not in the 02:00 row.
        let e = entry("Sommerzeit", start: at(2026, 3, 29, 3), minutes: 60)
        let p = CalendarLayout.content(for: at(2026, 3, 29), entries: [e], calendar: cal).timed.first
        XCTAssertEqual(p?.startMinute, 180)
        XCTAssertEqual(p?.endMinute, 240)
    }

    func testAllDayAndDueMarkersAreSeparateFromTimedBlocks() {
        let day = at(2026, 11, 24)
        let allDay = entry("Ganztag", start: day, allDay: true)
        let timed = entry("Termin", start: at(2026, 11, 24, 10), minutes: 60, due: at(2026, 11, 24, 17))
        let dueOnly = entry("Nur Frist", due: at(2026, 11, 24, 8))
        let other = entry("Anderer Tag", start: at(2026, 11, 25, 10))
        let c = CalendarLayout.content(for: day, entries: [allDay, timed, dueOnly, other], calendar: cal)
        XCTAssertEqual(c.allDay.map(\.title), ["Ganztag"])
        XCTAssertEqual(c.timed.map(\.entry.title), ["Termin"])
        XCTAssertEqual(c.due.map(\.title), ["Nur Frist", "Termin"], "by due time; the mark sits at the due time even if the card is planned elsewhere")
        XCTAssertEqual(c.day, day)
    }

    func testWeekContentSplitsEntriesPerDayAndKeepsMultiDayBlocksOnBothDays() {
        let w = CalendarWindow.week(containing: at(2026, 11, 25), calendar: cal)
        let mon = entry("Mo", start: at(2026, 11, 23, 9))
        let overnight = entry("Nacht", start: at(2026, 11, 25, 23), minutes: 120)
        let outside = entry("Draußen", start: at(2026, 12, 3, 9))
        let days = CalendarLayout.contents(in: w, entries: [mon, overnight, outside], calendar: cal)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days[0].timed.map(\.entry.title), ["Mo"])
        XCTAssertEqual(days[2].timed.map(\.entry.title), ["Nacht"])
        XCTAssertEqual(days[3].timed.map(\.entry.title), ["Nacht"])
        XCTAssertEqual(days.flatMap(\.timed).filter { $0.entry.title == "Draußen" }.count, 0)
    }

    // MARK: Conflict marks (shown, never prevented)

    func testAfterDueIsRecomputedFromTheCurrentPlan() {
        // A stale server flag disappears after a move; a new overrun appears at once.
        let stale = entry(start: at(2026, 11, 23, 9), due: at(2026, 11, 23, 12), conflicts: [.afterDue])
        XCTAssertEqual(CalendarConflicts.conflicts(for: stale, among: [stale]), [])
        let late = entry(start: at(2026, 11, 23, 9), minutes: 60, due: at(2026, 11, 23, 9, 45))
        XCTAssertEqual(CalendarConflicts.conflicts(for: late, among: [late]), [.afterDue], "the end (10:00) lies behind the due time")
        let exactly = entry(start: at(2026, 11, 23, 9), minutes: 45, due: at(2026, 11, 23, 9, 45))
        XCTAssertEqual(CalendarConflicts.conflicts(for: exactly, among: [exactly]), [])
    }

    func testAllDayCardsAreAfterDueOnlyWhenTheirDayStartsBehindTheDueTime() {
        let day = at(2026, 11, 24)
        let ok = entry(start: day, allDay: true, due: at(2026, 11, 24, 9))
        XCTAssertEqual(CalendarConflicts.conflicts(for: ok, among: [ok]), [])
        let late = entry(start: day, allDay: true, due: at(2026, 11, 23, 17))
        XCTAssertEqual(CalendarConflicts.conflicts(for: late, among: [late]), [.afterDue])
    }

    func testPrerequisiteHintsComeFromTheServerInAFixedOrder() {
        let e = entry(start: at(2026, 11, 23, 9), conflicts: [.prerequisiteOpen, .prerequisiteLater])
        XCTAssertEqual(CalendarConflicts.conflicts(for: e, among: [e]), [.prerequisiteLater, .prerequisiteOpen])
    }

    func testRepositoryOverlapIsDetectedLocallyForTheSameBindingOnly() {
        let a = entry("A", start: at(2026, 11, 23, 9), minutes: 60, repo: "repo/x")
        let b = entry("B", start: at(2026, 11, 23, 9, 30), minutes: 60, repo: "repo/x")
        let c = entry("C", start: at(2026, 11, 23, 9, 30), minutes: 60, repo: "repo/other")
        let d = entry("D", start: at(2026, 11, 23, 10), minutes: 30, repo: "repo/x")  // starts when A ends: no overlap with A, overlaps B
        let all = [a, b, c, d]
        XCTAssertEqual(CalendarConflicts.conflicts(for: a, among: all), [.repositoryOverlap])
        XCTAssertEqual(CalendarConflicts.conflicts(for: c, among: all), [], "another binding runs in parallel")
        XCTAssertEqual(CalendarConflicts.conflicts(for: d, among: all), [.repositoryOverlap])
        let aloneOnTheDay = entry("E", start: at(2026, 11, 24, 9), minutes: 60, repo: "repo/x")
        XCTAssertEqual(CalendarConflicts.conflicts(for: aloneOnTheDay, among: all + [aloneOnTheDay]), [])
    }

    func testRepositoryOverlapIgnoresDoneAllDayAndUnboundCards() {
        let a = entry("A", start: at(2026, 11, 23, 9), minutes: 60, repo: "repo/x")
        let done = entry("Done", start: at(2026, 11, 23, 9), minutes: 60, status: "done", repo: "repo/x")
        let allDay = entry("Tag", start: at(2026, 11, 23), allDay: true, repo: "repo/x")
        let unbound = entry("Frei", start: at(2026, 11, 23, 9), minutes: 60)
        XCTAssertEqual(CalendarConflicts.conflicts(for: a, among: [a, done, allDay, unbound]), [])
        // The server's own hint is kept (it knows the job state, the client does not).
        let flagged = entry("S", start: at(2026, 11, 23, 9), repo: "repo/x", conflicts: [.repositoryOverlap])
        XCTAssertEqual(CalendarConflicts.conflicts(for: flagged, among: [flagged]), [.repositoryOverlap])
    }

    // MARK: Drop rules

    private func slot(_ day: Date, _ h: Int, _ m: Int = 0) -> DropTarget { .slot(day: day, minute: h * 60 + m) }

    func testSidebarToGridSetsTheSnappedStartAndKeepsEverythingElse() {
        let day = at(2026, 11, 24)
        let e = entry("Frei")
        let decision = CalendarDrop.decide(e, onto: slot(day, 9, 7), calendar: cal)
        XCTAssertEqual(decision, .apply(SchedulePatch(plannedAt: .set(at(2026, 11, 24, 9)))))
        let late = CalendarDrop.decide(e, onto: slot(day, 14, 22), calendar: cal)
        XCTAssertEqual(late, .apply(SchedulePatch(plannedAt: .set(at(2026, 11, 24, 14, 15)))))
    }

    func testGridToGridMovesTheStartAndKeepsTheDuration() {
        let e = entry("Termin", start: at(2026, 11, 23, 9), minutes: 90)
        let decision = CalendarDrop.decide(e, onto: slot(at(2026, 11, 25), 16, 0), calendar: cal)
        guard case .apply(let patch) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(patch.plannedAt, .set(at(2026, 11, 25, 16)))
        XCTAssertEqual(patch.plannedMinutes, .keep, "duration stays")
        XCTAssertNil(patch.plannedAllDay, "unchanged flags are not sent")
    }

    func testDroppingOnTheCurrentSlotChangesNothing() {
        let e = entry("Termin", start: at(2026, 11, 23, 9))
        XCTAssertEqual(CalendarDrop.decide(e, onto: slot(at(2026, 11, 23), 9, 6), calendar: cal), .noChange, "snaps to the same 09:00")
        let unscheduled = entry("Frei")
        XCTAssertEqual(CalendarDrop.decide(unscheduled, onto: .unscheduled, calendar: cal), .noChange)
    }

    func testDroppingBelowTheLastSlotClampsToTwentyThreeFortyFive() {
        let e = entry("Spät")
        XCTAssertEqual(CalendarDrop.decide(e, onto: .slot(day: at(2026, 11, 24), minute: 1439), calendar: cal),
                       .apply(SchedulePatch(plannedAt: .set(at(2026, 11, 24, 23, 45)))))
    }

    func testDropOnTheDayHeaderMakesItAllDayAtTheStartOfTheDay() {
        let e = entry("Termin", start: at(2026, 11, 23, 9), minutes: 60, due: at(2026, 11, 23, 12))
        let decision = CalendarDrop.decide(e, onto: .allDay(day: at(2026, 11, 26, 13)), calendar: cal)
        XCTAssertEqual(decision, .apply(SchedulePatch(plannedAt: .set(at(2026, 11, 26)), plannedAllDay: true)))
        // The patch type has no due date at all: dragging cannot change it.
        let again = entry("Tag", start: at(2026, 11, 26), allDay: true)
        XCTAssertEqual(CalendarDrop.decide(again, onto: .allDay(day: at(2026, 11, 26)), calendar: cal), .noChange)
    }

    func testDropFromAllDayBackIntoTheGridCountsTheDropTimeAndTurnsAllDayOff() {
        let e = entry("Tag", start: at(2026, 11, 26), allDay: true)
        XCTAssertEqual(CalendarDrop.decide(e, onto: slot(at(2026, 11, 26), 11, 30), calendar: cal),
                       .apply(SchedulePatch(plannedAt: .set(at(2026, 11, 26, 11, 30)), plannedAllDay: false)))
        // Same wall time as an all-day card's start is still a change: it is not all-day any more.
        XCTAssertEqual(CalendarDrop.decide(e, onto: slot(at(2026, 11, 26), 0, 0), calendar: cal),
                       .apply(SchedulePatch(plannedAt: .set(at(2026, 11, 26)), plannedAllDay: false)))
    }

    func testBackToTheSidebarClearsThePlannedStart() {
        let e = entry("Termin", start: at(2026, 11, 23, 9), minutes: 60)
        XCTAssertEqual(CalendarDrop.decide(e, onto: .unscheduled, calendar: cal), .apply(SchedulePatch(plannedAt: .clear)),
                       "the server clears duration and all-day with it")
        let allDay = entry("Tag", start: at(2026, 11, 23), allDay: true)
        XCTAssertEqual(CalendarDrop.decide(allDay, onto: .unscheduled, calendar: cal), .apply(SchedulePatch(plannedAt: .clear)))
    }

    func testBackToTheSidebarIsRefusedForARepeatingCardWithoutDueDate() {
        let e = entry("Wöchentlich", start: at(2026, 11, 23, 9))
        XCTAssertEqual(CalendarDrop.decide(e, onto: .unscheduled, hasRecurrence: true, calendar: cal), .refused(.recurrenceNeedsDate))
        let withDue = entry("Wöchentlich", start: at(2026, 11, 23, 9), due: at(2026, 11, 23, 18))
        XCTAssertEqual(CalendarDrop.decide(withDue, onto: .unscheduled, hasRecurrence: true, calendar: cal), .apply(SchedulePatch(plannedAt: .clear)))
        // Moving a repeating card inside the grid is fine.
        XCTAssertEqual(CalendarDrop.decide(e, onto: slot(at(2026, 11, 24), 9), hasRecurrence: true, calendar: cal),
                       .apply(SchedulePatch(plannedAt: .set(at(2026, 11, 24, 9)))))
    }

    func testOnlyEditorsCanDragAndDoneCardsStayPut() {
        let readOnly = entry("Lesen", start: at(2026, 11, 23, 9), canEdit: false)
        XCTAssertFalse(readOnly.canDrag)
        XCTAssertEqual(CalendarDrop.decide(readOnly, onto: slot(at(2026, 11, 24), 9), calendar: cal), .refused(.readOnly))
        let done = entry("Fertig", start: at(2026, 11, 23, 9), status: "done")
        XCTAssertFalse(done.canDrag)
        XCTAssertEqual(CalendarDrop.decide(done, onto: .unscheduled, calendar: cal), .refused(.done))
        let both = entry("Beides", status: "done", canEdit: false)
        XCTAssertEqual(CalendarDrop.decide(both, onto: slot(at(2026, 11, 24), 9), calendar: cal), .refused(.readOnly))
        XCTAssertTrue(entry("Offen", canEdit: true).canDrag)
    }

    func testDropOnANonexistentDaylightSavingTimeStaysOnTheDay() {
        let e = entry("Lücke")
        guard case .apply(let patch) = CalendarDrop.decide(e, onto: slot(at(2026, 3, 29), 2, 30), calendar: cal),
              case .set(let start) = patch.plannedAt else { return XCTFail("expected a start") }
        XCTAssertTrue(cal.isDate(start, inSameDayAs: at(2026, 3, 29)))
        XCTAssertGreaterThanOrEqual(cal.component(.hour, from: start), 3, "02:30 does not exist, the next valid time is used")
    }

    // MARK: Optimistic view and rollback

    func testPatchAppliedToEntryMatchesTheServerRules() {
        let planned = entry("A", start: at(2026, 11, 23, 9), minutes: 45)
        let moved = SchedulePatch(plannedAt: .set(at(2026, 11, 24, 10))).applied(to: planned)
        XCTAssertEqual(moved.plannedAt, at(2026, 11, 24, 10))
        XCTAssertEqual(moved.plannedMinutes, 45)
        let allDay = SchedulePatch(plannedAt: .set(at(2026, 11, 24)), plannedAllDay: true).applied(to: planned)
        XCTAssertTrue(allDay.plannedAllDay)
        let cleared = SchedulePatch(plannedAt: .clear).applied(to: allDay)
        XCTAssertNil(cleared.plannedAt)
        XCTAssertNil(cleared.plannedMinutes, "clearing the start clears the duration")
        XCTAssertFalse(cleared.plannedAllDay, "and all-day")
    }

    func testInversePatchRestoresTheEntryForRollbackAndUndo() {
        for before in [entry("A", start: at(2026, 11, 23, 9), minutes: 45), entry("B", start: at(2026, 11, 23), allDay: true), entry("C")] {
            let moves = [SchedulePatch(plannedAt: .set(at(2026, 11, 25, 16, 15))), SchedulePatch(plannedAt: .set(at(2026, 11, 25)), plannedAllDay: true), SchedulePatch(plannedAt: .clear)]
            for move in moves {
                let after = move.applied(to: before)
                let back = SchedulePatch.inverse(of: before).applied(to: after)
                XCTAssertEqual(back.plannedAt, before.plannedAt)
                XCTAssertEqual(back.plannedMinutes, before.plannedMinutes)
                XCTAssertEqual(back.plannedAllDay, before.plannedAllDay)
            }
        }
        // For an unscheduled card the inverse is "clear everything".
        let inv = SchedulePatch.inverse(of: entry("C"))
        XCTAssertEqual(inv.plannedAt, .clear)
        // The inverse of a card with a start sends it again, plus duration and all-day, so the server ends up identical.
        let inv2 = SchedulePatch.inverse(of: entry("A", start: at(2026, 11, 23, 9), minutes: 45))
        XCTAssertEqual(inv2.plannedAt, .set(at(2026, 11, 23, 9)))
        XCTAssertEqual(inv2.plannedMinutes, .set(45))
        XCTAssertEqual(inv2.plannedAllDay, false)
    }

    func testSidebarEntryFromAPlanningTask() {
        let t = TodoTask(id: task, projectID: project, title: "Ohne Termin", version: 4)
        let pt = PlanningTask(task: t, planning: PlanningData(dueAt: at(2026, 11, 28, 12), priority: 2))
        let e = ScheduleEntry(unscheduled: pt, canEdit: true)
        XCTAssertEqual(e.taskID, task)
        XCTAssertEqual(e.version, 4)
        XCTAssertNil(e.plannedAt)
        XCTAssertEqual(e.dueAt, at(2026, 11, 28, 12))
        XCTAssertTrue(e.canEdit)
        XCTAssertTrue(e.conflicts.isEmpty)
        XCTAssertFalse(ScheduleEntry(unscheduled: pt, canEdit: false).canDrag, "the planning list carries no role, the caller says")
    }

    // MARK: Online PATCH or sync queue

    func testOnlineWritesAlwaysGoThroughThePatchRoute() {
        let moves = [SchedulePatch(plannedAt: .set(at(2026, 11, 24, 9))), SchedulePatch(plannedAt: .set(at(2026, 11, 24)), plannedAllDay: true), SchedulePatch(plannedAt: .clear)]
        for m in moves { XCTAssertEqual(ScheduleWriteRoute.choose(m, isOnline: true), .patch) }
    }

    func testOfflineOnlyUsesTheQueueForWhatTaskPlanningCanCarryToday() {
        let move = SchedulePatch(plannedAt: .set(at(2026, 11, 24, 9)))
        XCTAssertEqual(ScheduleWriteRoute.choose(move, isOnline: false), .queue, "a plain move is a full planning replacement without new keys")
        XCTAssertEqual(ScheduleWriteRoute.choose(SchedulePatch(plannedAt: .clear), isOnline: false), .queue)
        let allDay = SchedulePatch(plannedAt: .set(at(2026, 11, 24)), plannedAllDay: true)
        XCTAssertEqual(ScheduleWriteRoute.choose(allDay, isOnline: false), .unavailableOffline, "the Swift queue does not carry plannedAllDay yet")
        XCTAssertEqual(ScheduleWriteRoute.choose(SchedulePatch(plannedMinutes: .set(45)), isOnline: false), .unavailableOffline)
        XCTAssertEqual(ScheduleWriteRoute.choose(allDay, isOnline: false, queueCarriesScheduleFields: true), .queue)
    }
}

/// The editor "Start und Dauer" (iPhone sheet, detail on iPad/Mac) turns its fields into a patch (card 8CECAD24, phase 2).
final class ScheduleEditingTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }
    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))! }
    private func entry(start: Date? = nil, minutes: Int? = nil, allDay: Bool = false, due: Date? = nil) -> ScheduleEntry {
        ScheduleEntry(taskID: UUID(), projectID: UUID(), title: "T", plannedAt: start, plannedMinutes: minutes, plannedAllDay: allDay, dueAt: due)
    }

    func testNewStartOnAnUnscheduledCardSnapsAndKeepsTheDurationUnsetWhenItIsTheDefault() {
        let r = ScheduleEditing.patch(for: entry(), start: at(24, 9, 7), minutes: 30, allDay: false, calendar: cal)
        XCTAssertEqual(r, .patch(SchedulePatch(plannedAt: .set(at(24, 9)))), "default 30 minutes is not sent: the server shows 30 without a value")
    }

    func testDurationOtherThanTheDefaultIsSent() {
        let r = ScheduleEditing.patch(for: entry(), start: at(24, 9), minutes: 90, allDay: false, calendar: cal)
        XCTAssertEqual(r, .patch(SchedulePatch(plannedAt: .set(at(24, 9)), plannedMinutes: .set(90))))
    }

    func testOnlyAChangedFieldIsSent() {
        let e = entry(start: at(23, 9), minutes: 45)
        XCTAssertEqual(ScheduleEditing.patch(for: e, start: at(23, 9), minutes: 60, allDay: false, calendar: cal), .patch(SchedulePatch(plannedMinutes: .set(60))))
        XCTAssertEqual(ScheduleEditing.patch(for: e, start: at(23, 10, 14), minutes: 45, allDay: false, calendar: cal), .patch(SchedulePatch(plannedAt: .set(at(23, 10, 15)))))
        XCTAssertEqual(ScheduleEditing.patch(for: e, start: at(23, 9, 6), minutes: 45, allDay: false, calendar: cal), .noChange, "snaps to the same 09:00")
    }

    func testAllDayUsesTheStartOfTheDayAndNoDuration() {
        let e = entry(start: at(23, 9), minutes: 45)
        XCTAssertEqual(ScheduleEditing.patch(for: e, start: at(25, 16), minutes: 45, allDay: true, calendar: cal),
                       .patch(SchedulePatch(plannedAt: .set(at(25, 0)), plannedAllDay: true)))
        let allDay = entry(start: at(25, 0), allDay: true)
        XCTAssertEqual(ScheduleEditing.patch(for: allDay, start: at(25, 18), minutes: nil, allDay: true, calendar: cal), .noChange)
    }

    func testAllDayBackToTimedTurnsTheFlagOff() {
        let allDay = entry(start: at(25, 0), allDay: true)
        XCTAssertEqual(ScheduleEditing.patch(for: allDay, start: at(25, 0), minutes: 30, allDay: false, calendar: cal),
                       .patch(SchedulePatch(plannedAt: .set(at(25, 0)), plannedAllDay: false)))
    }

    func testDurationOutsideTheServerRangeIsInvalid() {
        let e = entry(start: at(23, 9))
        XCTAssertEqual(ScheduleEditing.patch(for: e, start: at(23, 9), minutes: 4, allDay: false, calendar: cal), .invalidMinutes)
        XCTAssertEqual(ScheduleEditing.patch(for: e, start: at(23, 9), minutes: 1441, allDay: false, calendar: cal), .invalidMinutes)
        XCTAssertEqual(ScheduleEditing.patch(for: e, start: at(23, 9), minutes: 1440, allDay: false, calendar: cal), .patch(SchedulePatch(plannedMinutes: .set(1440))))
    }

    func testDueDateIsNeverPartOfThePatch() {
        let e = entry(start: at(23, 9), due: at(23, 12))
        guard case .patch(let p) = ScheduleEditing.patch(for: e, start: at(26, 15), minutes: 120, allDay: false, calendar: cal) else { return XCTFail("expected a patch") }
        XCTAssertEqual(p.plannedAt, .set(at(26, 15)))
        // SchedulePatch has no dueAt key at all; this documents the rule next to the editor.
        XCTAssertEqual(Mirror(reflecting: p).children.compactMap(\.label).sorted(), ["plannedAllDay", "plannedAt", "plannedMinutes"])
    }
}
