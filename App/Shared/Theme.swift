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
    static func select() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    static func warning() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

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

// MARK: Design system tokens

/// Spacing scale (points). Use these instead of literals so rhythm stays consistent.
enum Space {
    static let xxs: CGFloat = 2, xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
}

/// Corner radii.
enum Radius {
    static let s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 18, xl: CGFloat = 26
}

/// Type scale. Rounded design for headings gives the app its own voice; all styles scale with Dynamic Type.
extension Font {
    static let screenTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let sectionTitle = Font.system(.subheadline, design: .rounded).weight(.bold)
    static let rowTitle = Font.system(.body, design: .default).weight(.regular)
    static let rowMeta = Font.system(.caption, design: .default).weight(.medium)
    static let detailTitle = Font.system(.title2, design: .rounded).weight(.bold)
}

/// Tinted tile colors for sidebar and property icons (fixed hues that work on light and dark).
extension Color {
    static let tileBlue = Color(red: 0.20, green: 0.48, blue: 0.95)
    static let tileGreen = Color(red: 0.20, green: 0.70, blue: 0.40)
    static let tileOrange = Color(red: 0.96, green: 0.58, blue: 0.12)
    static let tilePurple = Color(red: 0.52, green: 0.38, blue: 0.90)
    static let tileTeal = Color(red: 0.12, green: 0.68, blue: 0.72)
    static let tileGray = Color(red: 0.50, green: 0.52, blue: 0.56)
}

/// Raised surface with a hairline border and a soft shadow (cards, grouped property blocks).
struct CardSurface: ViewModifier {
    var radius: CGFloat = Radius.l
    func body(content: Content) -> some View {
        content
            .background(Color.canvasRaised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.hairline.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

extension View {
    func cardSurface(radius: CGFloat = Radius.l) -> some View { modifier(CardSurface(radius: radius)) }
}

/// Button style with a subtle press scale, used for chips, FAB and tiles.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}

/// Rounded icon tile (sidebar rows, property rows).
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    var body: some View {
        let side = size * scale
        Image(systemName: symbol)
            .font(.system(size: side * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: side * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension View {
    /// Guarantees the 44 x 44 pt minimum touch target of the HIG on touch platforms without changing the visual size.
    func tapTarget() -> some View {
        #if os(iOS)
        self.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        #else
        self
        #endif
    }
}

/// Counter capsule used in the sidebar and tab badges.
struct CountBadge: View {
    let count: Int
    var tint: Color = .secondary
    var body: some View {
        Text(verbatim: String(count))
            .font(.caption.weight(.semibold)).monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: Dates (text helpers live above); small views

struct ProjectDot: View {
    let id: UUID?
    var size: CGFloat = 9
    @Environment(AppModel.self) private var model
    var body: some View { Circle().fill(model.projectColor(id)).frame(width: size, height: size) }
}

/// Label as a small tinted pill.
struct LabelChip: View {
    let name: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "tag.fill").font(.caption2).imageScale(.small)
            Text(verbatim: name).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.project(name.hashValueUUID))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Color.project(name.hashValueUUID).opacity(0.13), in: Capsule())
    }
}

extension String {
    /// Stable pseudo-UUID derived from the text so equal names always get the same tint.
    var hashValueUUID: UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in utf8.enumerated() { bytes[i % 16] = bytes[i % 16] &* 31 &+ b &+ UInt8(truncatingIfNeeded: i) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Small icon + text fragment for a row's meta line.
struct MetaItem: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.caption2.weight(.semibold))
            Text(verbatim: text).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
        }
        .foregroundStyle(tint)
    }
}

/// Empty state built from SF Symbols only: layered tinted discs, the main symbol and animated accents.
struct EmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey?
    var tint: Color = .brand
    @State private var float = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Space.m) {
            ZStack {
                Circle().fill(tint.opacity(0.07)).frame(width: 168, height: 168)
                Circle().fill(tint.opacity(0.11)).frame(width: 118, height: 118)
                Circle().stroke(tint.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [2, 6])).frame(width: 168, height: 168)
                    .rotationEffect(.degrees(float ? 8 : -8))
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.canvasRaised).frame(width: 84, height: 84)
                    .shadow(color: tint.opacity(0.25), radius: 14, y: 6)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1))
                Image(systemName: symbol).font(.system(size: 38, weight: .medium)).foregroundStyle(tint.gradient)
                Image(systemName: "sparkle").font(.system(size: 18)).foregroundStyle(Color.tileOrange).offset(x: 66, y: float ? -58 : -52)
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Color.tileBlue).offset(x: -70, y: float ? 40 : 46)
                Image(systemName: "sparkle").font(.system(size: 11)).foregroundStyle(tint.opacity(0.6)).offset(x: -54, y: float ? -66 : -60)
            }
            .frame(height: 180)
            .accessibilityHidden(true)
            Text(title).font(.system(.title3, design: .rounded).weight(.semibold)).multilineTextAlignment(.center)
            if let message { Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding(Space.xxl)
        .frame(maxWidth: 380)
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { float = true } } }
    }
}

/// Placeholder rows shown while the first load is running.
struct SkeletonRows: View {
    var count = 6
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                HStack(alignment: .top, spacing: Space.m) {
                    Circle().fill(Color.hairline).frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.hairline).frame(width: CGFloat(150 + (i * 47) % 120), height: 13)
                        RoundedRectangle(cornerRadius: 4).fill(Color.hairline.opacity(0.6)).frame(width: CGFloat(80 + (i * 31) % 70), height: 9)
                    }
                    Spacer()
                }
                .padding(.horizontal, Space.l).padding(.vertical, Space.m)
            }
        }
        .opacity(pulse ? 0.45 : 1)
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("loading"))
    }
}

/// Dismissible inline banner for errors and hints.
struct NoticeBanner: View {
    let symbol: String
    let text: LocalizedStringKey
    var tint: Color = .dueOverdue
    var action: (() -> Void)?
    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol)
            Text(text).font(.footnote.weight(.medium))
            Spacer(minLength: 0)
            if let action { Button(action: action) { Image(systemName: "xmark").font(.caption.weight(.bold)) }.buttonStyle(.plain).accessibilityLabel(Text("ok")) }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Space.m).padding(.vertical, Space.s + 2)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .padding(.horizontal, Space.l)
    }
}
