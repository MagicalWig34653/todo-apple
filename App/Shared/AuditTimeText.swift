import SwiftUI
import TodoCore

/// Audit time line ("erstellt vor 3 Min."): relative text from the system, the exact Berlin moment as tooltip (Mac), as
/// accessibility value and in the long-press menu (iPhone/iPad), like the PWA tooltip. Draws nothing without a date.
struct AuditTimeText: View {
    let date: Date?
    var label: LocalizedStringKey?
    var identifier: String?

    var body: some View {
        if let date {
            let exact = AuditTime.exact(date)
            HStack(spacing: Space.xxs) {
                if let label { Text(label) }
                Text(verbatim: CommandFormat.relative(date))
            }
            .help(exact)
            .contextMenu { Label { Text(verbatim: exact) } icon: { Image(systemName: "clock") } }
            .accessibilityElement(children: .combine)
            .accessibilityValue(Text(verbatim: exact))
            .accessibilityIdentifier(identifier ?? "audit.time")
        }
    }
}

#Preview("Audit time") {
    VStack(alignment: .leading, spacing: Space.s) {
        AuditTimeText(date: Date().addingTimeInterval(-180), label: "time.created")
        AuditTimeText(date: Date().addingTimeInterval(-7200), label: "time.requested")
        AuditTimeText(date: nil, label: "time.decided")
    }
    .font(.caption).padding()
}
