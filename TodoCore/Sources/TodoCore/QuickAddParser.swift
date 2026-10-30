import Foundation

/// Natural-language quick add (German). Extracts due date/time, priority, recurrence, `#project` and `@label` tokens
/// from a typed line and returns the remaining text as title. Pure function: `now` and `calendar` are injected.
public struct QuickAddParse: Equatable, Sendable {
    public var title: String
    public var due: Date?
    public var hasTime = false
    /// Stored priority (0 none ... 3 highest); nil when the text did not mention one.
    public var priority: Int?
    public var recurrence: RecurrenceRule.Frequency?
    public var projectToken: String?
    public var labelTokens: [String] = []
    /// The phrases that were recognised and removed from the title (for chips and highlighting).
    public var recognized: [String] = []
}

public enum QuickAddParser {
    private static let weekdays: [(names: [String], weekday: Int)] = [
        (["sonntag", "so"], 1), (["montag", "mo"], 2), (["dienstag", "di"], 3), (["mittwoch", "mi"], 4),
        (["donnerstag", "do"], 5), (["freitag", "fr"], 6), (["samstag", "sa"], 7),
    ]

    public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> QuickAddParse {
        var words = input.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var result = QuickAddParse(title: "")
        let today = calendar.startOfDay(for: now)
        var dayOffset: Int?
        var dayDate: Date?
        var time: (h: Int, m: Int)?

        func norm(_ s: String) -> String {
            s.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "de_DE"))
                .trimmingCharacters(in: CharacterSet(charactersIn: ",.;!?"))
        }
        func take(_ i: Int, _ n: Int) { result.recognized.append(words[i..<i + n].joined(separator: " ")); words.removeSubrange(i..<i + n) }

        var i = 0
        while i < words.count {
            let raw = words[i], w = norm(raw)
            let next = i + 1 < words.count ? norm(words[i + 1]) : ""
            let next2 = i + 2 < words.count ? norm(words[i + 2]) : ""
            if raw.hasPrefix("#"), raw.count > 1 { result.projectToken = String(raw.dropFirst()); result.recognized.append(raw); words.remove(at: i); continue }
            if raw.hasPrefix("@"), raw.count > 1 { result.labelTokens.append(String(raw.dropFirst())); result.recognized.append(raw); words.remove(at: i); continue }
            if ["p1", "p2", "p3", "p4", "!1", "!2", "!3", "!4"].contains(w), let n = Int(w.dropFirst()) {
                result.priority = 4 - n; take(i, 1); continue
            }
            switch w {
            case "heute": dayOffset = 0; take(i, 1); continue
            case "morgen": dayOffset = 1; take(i, 1); continue
            case "uebermorgen": dayOffset = 2; take(i, 1); continue
            case "taeglich": result.recurrence = .daily; take(i, 1); continue
            case "woechentlich": result.recurrence = .weekly; take(i, 1); continue
            case "monatlich": result.recurrence = .monthly; take(i, 1); continue
            default: break
            }
            if ["jeden", "jede", "jedes"].contains(w) {
                if next == "tag" { result.recurrence = .daily; take(i, 2); continue }
                if next == "woche" { result.recurrence = .weekly; take(i, 2); continue }
                if next == "monat" { result.recurrence = .monthly; take(i, 2); continue }
            }
            if w == "naechste" || w == "naechsten" || w == "kommenden", next == "woche" {
                dayDate = nextWeekday(2, after: today, calendar: calendar); take(i, 2); continue
            }
            if w == "am" || w == "naechsten" || w == "kommenden", next == "wochenende" {
                dayDate = nextWeekday(7, after: today, calendar: calendar); take(i, 2); continue
            }
            if w == "wochenende" { dayDate = nextWeekday(7, after: today, calendar: calendar); take(i, 1); continue }
            if w == "in", let n = Int(next), n > 0, n < 400 {
                switch next2 {
                case "tag", "tagen": dayOffset = n; take(i, 3); continue
                case "woche", "wochen": dayOffset = n * 7; take(i, 3); continue
                default: break
                }
            }
            if let entry = weekdays.first(where: { $0.names.contains(w) && (w.count > 2 || (i > 0 && norm(words[i - 1]) == "am")) }) {
                var consumed = 1, start = i
                if i > 0, ["am", "naechsten", "naechster"].contains(norm(words[i - 1])) { start = i - 1; consumed = 2 }
                dayDate = nextWeekday(entry.weekday, after: today, calendar: calendar)
                take(start, consumed); i = start; continue
            }
            // Times: "um 14 Uhr", "14:30", "14.30 Uhr", "um 9".
            if let t = parseClock(w) {
                time = t
                if i > 0, norm(words[i - 1]) == "um" { take(i - 1, next == "uhr" ? 3 : 2); i -= 1 }
                else if next == "uhr" { take(i, 2) } else { take(i, 1) }
                continue
            }
            if w == "um", let n = Int(next), n >= 0, n < 24 {
                time = (n, 0); take(i, next2 == "uhr" ? 3 : 2); continue
            }
            if let n = Int(w), n >= 0, n < 24, next == "uhr" { time = (n, 0); take(i, 2); continue }
            i += 1
        }

        if let dayDate { result.due = dayDate } else if let dayOffset { result.due = calendar.date(byAdding: .day, value: dayOffset, to: today) }
        else if time != nil || result.recurrence != nil { result.due = today }
        if let time, let d = result.due {
            result.due = calendar.date(bySettingHour: time.h, minute: time.m, second: 0, of: d)
            result.hasTime = true
            if dayDate == nil, dayOffset == nil, let due = result.due, due < now { result.due = calendar.date(byAdding: .day, value: 1, to: due) }
        }
        result.title = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return result
    }

    private static func parseClock(_ w: String) -> (Int, Int)? {
        let parts = w.split(whereSeparator: { $0 == ":" || $0 == "." })
        guard parts.count == 2, parts[1].count == 2, let h = Int(parts[0]), let m = Int(parts[1]), h < 24, m < 60, w.contains(":") || w.contains(".") else { return nil }
        // "3.50" could be a number; only accept the colon form or a trailing "uhr" handled by the caller.
        return w.contains(":") ? (h, m) : nil
    }

    private static func nextWeekday(_ weekday: Int, after day: Date, calendar: Calendar) -> Date {
        var c = DateComponents(); c.weekday = weekday
        return calendar.nextDate(after: day, matching: c, matchingPolicy: .nextTime) ?? day
    }
}
