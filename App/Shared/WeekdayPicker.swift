import SwiftUI

/// The seven weekdays of a weekly rule as toggle chips, Monday first (ISO 1 ... 7). Seven in a row where they fit with a
/// full tap target, wrapping on narrow widths and at large text sizes.
struct WeekdayPicker: View {
    let selected: Set<Int>
    let toggle: (Int) -> Void
    @ScaledMetric(relativeTo: .subheadline) private var side = TapTarget.minimum

    /// Same language as the rest of the app, independent of the region settings.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "de")
        return calendar
    }()

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: side), spacing: Space.xs)], spacing: Space.xs) {
            ForEach(1...7, id: \.self) { day in chip(day) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("task.repeat.weekdays"))
    }

    private func chip(_ day: Int) -> some View {
        let on = selected.contains(day)
        // The symbol lists start on Sunday.
        let short = Self.calendar.shortStandaloneWeekdaySymbols[day % 7]
        let long = Self.calendar.standaloneWeekdaySymbols[day % 7]
        let shape = RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
        return Button { toggle(day) } label: {
            Text(verbatim: short)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(on ? Color.onBrand : Color.primary)
                .frame(maxWidth: .infinity, minHeight: side)
                .background(on ? Color.brand : Color.canvas, in: shape)
                .overlay(shape.strokeBorder(on ? Color.brand : Color.hairline))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: long))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("repeat.weekday.\(day)")
    }
}

#if DEBUG
private func weekdayPickerPreview() -> some View {
    WeekdayPicker(selected: [1, 4]) { _ in }.padding(Space.m).background(Color.canvasRaised)
}
#Preview("Weekdays light") { weekdayPickerPreview().preferredColorScheme(.light) }
#Preview("Weekdays dark") { weekdayPickerPreview().preferredColorScheme(.dark) }
#Preview("Weekdays accessibility5") { weekdayPickerPreview().dynamicTypeSize(.accessibility5) }
#endif
