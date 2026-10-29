import SwiftUI
import TodoCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Design tokens. The colors live in `Assets.xcassets` (light and dark variants); nothing else hard-codes colors.
extension Color {
    static let brand = Color("Brand")
    static let canvas = Color("Canvas")
    static let canvasRaised = Color("CanvasRaised")
    static let hairline = Color("Hairline")
    static let dueOverdue = Color("DueOverdue")
    static let dueToday = Color("DueToday")
    static let dueTomorrow = Color("DueTomorrow")

    /// Ring color of the checkbox for the stored priority (0 none ... 3 highest): P4 gray, P3 blue, P2 orange, P1 red.
    static func priority(_ value: Int) -> Color {
        switch value {
        case 3...: Color("PriorityP1")
        case 2: Color("PriorityP2")
        case 1: Color("PriorityP3")
        default: Color("PriorityP4")
        }
    }

    /// Stable project dot color derived from the project id (the server has no project colors yet).
    static func project(_ id: UUID?) -> Color {
        guard let id else { return Color("PriorityP4") }
        let palette: [Color] = [
            Color(red: 0.86, green: 0.30, blue: 0.25), Color(red: 0.92, green: 0.54, blue: 0.04),
            Color(red: 0.76, green: 0.65, blue: 0.10), Color(red: 0.27, green: 0.68, blue: 0.36),
            Color(red: 0.16, green: 0.67, blue: 0.67), Color(red: 0.14, green: 0.44, blue: 0.88),
            Color(red: 0.42, green: 0.35, blue: 0.85), Color(red: 0.72, green: 0.32, blue: 0.78),
            Color(red: 0.88, green: 0.32, blue: 0.55), Color(red: 0.45, green: 0.45, blue: 0.48),
        ]
        let sum = withUnsafeBytes(of: id.uuid) { $0.enumerated().reduce(0) { ($0 &* 131 &+ Int($1.element) &+ $1.offset) & 0xFFFFFF } }
        return palette[sum % palette.count]
    }
}

enum Haptics {
    static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        #endif
    }

    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        #endif
    }
}

// MARK: Dates

enum DueStyle {
    case overdue, today, tomorrow, later

    var color: Color {
        switch self {
        case .overdue: .dueOverdue
        case .today: .dueToday
        case .tomorrow: .dueTomorrow
        case .later: .secondary
        }
    }
}

enum DueFormat {
    static func style(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> DueStyle {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        if day < today { return .overdue }
        if day == today { return .today }
        if calendar.date(byAdding: .day, value: 1, to: today) == day { return .tomorrow }
        return .later
    }

    static func hasTime(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0
    }

    /// "Heute", "Morgen", weekday within a week, otherwise "28. Okt."; the time is appended when set.
    static func text(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let diff = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        var base: String
        switch diff {
        case 0: base = String(localized: "due.today")
        case 1: base = String(localized: "due.tomorrow")
        case -1: base = String(localized: "due.yesterday")
        case 2...6: base = date.formatted(.dateTime.weekday(.wide))
        default:
            base = calendar.isDate(date, equalTo: now, toGranularity: .year)
                ? date.formatted(.dateTime.day().month(.abbreviated))
                : date.formatted(.dateTime.day().month(.abbreviated).year())
        }
        if hasTime(date, calendar: calendar) { base += " " + date.formatted(.dateTime.hour().minute()) }
        return base
    }

    static func startOfToday(_ calendar: Calendar = .current) -> Date { calendar.startOfDay(for: Date()) }

    /// Next Saturday at 09:00 (today if it is Saturday already and before 09:00 is not special-cased).
    static func weekend(calendar: Calendar = .current, now: Date = Date()) -> Date {
        var c = DateComponents(); c.weekday = 7
        let sat = calendar.nextDate(after: calendar.startOfDay(for: now).addingTimeInterval(-1), matching: c, matchingPolicy: .nextTime) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: sat) ?? sat
    }

    static func nextWeek(calendar: Calendar = .current, now: Date = Date()) -> Date {
        var c = DateComponents(); c.weekday = 2
        let mon = calendar.nextDate(after: now, matching: c, matchingPolicy: .nextTime) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: mon) ?? mon
    }

    static func tomorrow(calendar: Calendar = .current, now: Date = Date()) -> Date {
        let d = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d
    }

    /// Today at 17:00, or the next full hour if that has passed.
    static func today(calendar: Calendar = .current, now: Date = Date()) -> Date {
        let t = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: now) ?? now
        return t > now ? t : calendar.date(byAdding: .hour, value: 1, to: now) ?? now
    }
}

// MARK: Small views

struct ProjectDot: View {
    let id: UUID?
    var size: CGFloat = 9
    var body: some View { Circle().fill(Color.project(id)).frame(width: size, height: size) }
}

struct LabelChip: View {
    let name: String
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "tag.fill").font(.system(size: 8))
            Text(verbatim: name).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.hairline.opacity(0.7), in: Capsule())
    }
}

/// Empty state built from SF Symbols only: a tinted disc, the main symbol and two small accents.
struct EmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.brand.opacity(0.10)).frame(width: 132, height: 132)
                Circle().stroke(Color.brand.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [3, 5])).frame(width: 164, height: 164)
                Image(systemName: symbol).font(.system(size: 52, weight: .regular)).foregroundStyle(Color.brand)
                Image(systemName: "sparkle").font(.system(size: 16)).foregroundStyle(Color.dueTomorrow).offset(x: 62, y: -52)
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Color.priority(1)).offset(x: -66, y: 40)
                Image(systemName: "sparkle").font(.system(size: 10)).foregroundStyle(Color.brand.opacity(0.6)).offset(x: -52, y: -62)
            }
            .frame(height: 170)
            .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            if let message { Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding(32)
        .frame(maxWidth: 360)
    }
}
