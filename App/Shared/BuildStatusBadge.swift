import SwiftUI
import TodoCore

/// Build state as symbol plus text, never colour alone. Failed is the loudest variant (filled, stroked, bold).
/// Shows nothing for an unknown or missing status, so callers can place it without a check.
struct BuildStatusBadge: View {
    let status: BuildStatus?
    var body: some View {
        if let status {
            HStack(spacing: Space.xs) {
                Image(systemName: status.symbol).font(.caption2.weight(.bold)).accessibilityHidden(true)
                status.title.lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            .font(status == .failed ? .caption.weight(.bold) : .caption.weight(.semibold))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
            .background(status.tint.opacity(status == .failed ? 0.30 : 0.16), in: Capsule())
            .overlay { if status == .failed { Capsule().stroke(status.tint, lineWidth: 1.5) } }
            .accessibilityElement(children: .combine)
        }
    }
}

extension BuildStatus {
    var title: Text {
        switch self {
        case .building: Text("build.status.building")
        case .succeeded: Text("build.status.succeeded")
        case .failed: Text("build.status.failed")
        }
    }
    var symbol: String {
        switch self {
        case .building: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }
    var tint: Color {
        switch self {
        case .building: .tileBlue
        case .succeeded: .tileGreen
        case .failed: .dueOverdue
        }
    }
}

#if DEBUG
#Preview("Build-Status light") { BuildStatusPreview().preferredColorScheme(.light) }
#Preview("Build-Status dark") { BuildStatusPreview().preferredColorScheme(.dark) }
#Preview("Build-Status klein") { BuildStatusPreview().frame(width: 200) }
#Preview("Build-Status accessibility5") { BuildStatusPreview().dynamicTypeSize(.accessibility5) }

private struct BuildStatusPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            BuildStatusBadge(status: .building)
            BuildStatusBadge(status: .succeeded)
            BuildStatusBadge(status: .failed)
            BuildStatusBadge(status: nil)
        }.padding(Space.l)
    }
}
#endif
