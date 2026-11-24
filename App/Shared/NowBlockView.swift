import SwiftUI
import TodoCore

/// Block "Jetzt" (contract session-status 1.4.0, field `now`) above the project cards: what runs right now, what waits for the
/// user, what finished in the last 6 hours and, collapsed, what is in progress without a sign of life. Same order as the web page.
struct NowBlockView: View {
    let block: NowBlock
    let now: Date
    @Binding var silentExpanded: Bool
    /// Opens the task detail: task, project, title (the title is a placeholder until the detail loads the real card).
    let open: (UUID, UUID, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            running
            if !block.waiting.isEmpty { waiting }
            if !block.recentlyDone.isEmpty { done }
            if block.counts.silent > 0 { silent }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Läuft gerade

    private var running: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            NowBlockHeading(title: "now.block.running", count: block.counts.running)
            if block.running.isEmpty {
                Text("now.block.runningEmpty").font(.subheadline).foregroundStyle(Color.textSecondary)
                    .accessibilityIdentifier("now.block.running.empty")
            } else {
                VStack(alignment: .leading, spacing: Space.m) {
                    ForEach(block.running) { NowActiveRow(item: $0, now: now, muted: false, identifier: "now.block.running.item", open: open) }
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now.block.running")
    }

    // MARK: Wartet auf dich

    private var waiting: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            NowBlockHeading(title: "now.block.waiting", count: block.counts.waiting)
            ForEach(block.waiting) { NowWaitingRow(item: $0, now: now, open: open) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now.block.waiting")
    }

    // MARK: Zuletzt fertig

    private var done: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            NowBlockHeading(title: "now.block.done", count: nil, hint: "now.block.doneHint")
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(block.recentlyDone) { NowDoneRow(item: $0, now: now, open: open) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now.block.done")
    }

    // MARK: Ohne Lebenszeichen (collapsed)

    private var silent: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button { withAnimation(.snappy) { silentExpanded.toggle() } } label: {
                HStack(spacing: Space.s) {
                    Text("now.block.silent \(block.counts.silent)").font(.subheadline.weight(.medium)).foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.textSecondary)
                        .rotationEffect(.degrees(silentExpanded ? 90 : 0)).accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).tapTarget()
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(Text(silentExpanded ? "now.block.expanded" : "now.block.collapsed"))
            .accessibilityIdentifier("now.block.silent")
            if silentExpanded {
                Text("now.block.silentHint").font(.footnote).foregroundStyle(Color.textSecondary)
                VStack(alignment: .leading, spacing: Space.m) {
                    ForEach(block.silent) { NowActiveRow(item: $0, now: now, muted: true, identifier: "now.block.silent.item", open: open) }
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.hairline.opacity(0.25), in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).strokeBorder(Color.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

private struct NowBlockHeading: View {
    let title: LocalizedStringKey
    let count: Int?
    var hint: LocalizedStringKey?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(title).font(.headline)
            if let count, count > 0 { Text(verbatim: "(\(count))").font(.subheadline).foregroundStyle(Color.textSecondary) }
            if let hint { Text(hint).font(.footnote).foregroundStyle(Color.textSecondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Durations

enum NowDuration {
    /// "5 Min.", "2 Std.", "3 Tg." (one unit, localized); nil below one minute.
    static func text(_ seconds: TimeInterval) -> String? {
        guard seconds >= 60 else { return nil }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.maximumUnitCount = 1
        f.unitsStyle = .short
        return f.string(from: seconds)
    }
}

// MARK: Rows

private struct NowActiveRow: View {
    let item: NowActive
    let now: Date
    let muted: Bool
    let identifier: String
    let open: (UUID, UUID, String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if let taskID = item.taskID, item.kind == .task {
            Button { open(taskID, item.projectID, item.title) } label: { content }
                .buttonStyle(.plain).tapTarget()
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier(identifier)
        } else {
            content.accessibilityIdentifier(identifier)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            AdaptiveStack(spacing: Space.s, verticalAlignment: .firstTextBaseline) {
                Text(verbatim: item.title).font(.body.weight(.semibold)).lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                    .multilineTextAlignment(.leading)
                if item.kind == .session {
                    Text("now.block.session").font(.caption.weight(.medium)).foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                        .overlay(Capsule().strokeBorder(Color.hairline))
                }
                if let worker = item.worker, !worker.isEmpty {
                    Text(verbatim: worker).font(.caption.weight(.medium)).foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                        .background(Color.hairline.opacity(0.5), in: Capsule())
                }
            }
            Text(verbatim: item.projectName).font(.footnote).foregroundStyle(Color.textSecondary)
            if !item.text.isEmpty {
                Text(verbatim: item.text).font(.footnote).foregroundStyle(muted ? Color.textSecondary : Color.primary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 3).multilineTextAlignment(.leading)
            }
            if let percent = item.percent {
                ProgressView(value: Double(percent), total: 100).tint(muted ? Color.textSecondary : LanePresentation.color("running"))
                    .accessibilityLabel(Text("now.progress \(percent)"))
            }
            FlowLayout(spacing: Space.s) {
                if let since = item.since, let d = NowDuration.text(now.timeIntervalSince(since)) { Text("now.block.since \(d)") }
                Text(lifeSign)
                if let due = item.dueAt { dueText(due) }
            }
            .font(.footnote).foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var lifeSign: LocalizedStringKey {
        let age = item.lastSignAt.map { now.timeIntervalSince($0) } ?? item.ageSeconds.map(TimeInterval.init) ?? 0
        if let d = NowDuration.text(age) { return "now.block.lifeSign \(d)" }
        return "now.block.lifeSignNow"
    }

    @ViewBuilder private func dueText(_ due: Date) -> some View {
        if item.isOverdue(at: now), let d = NowDuration.text(now.timeIntervalSince(due)) {
            Label("now.block.overdue \(d)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.dueOverdue).fontWeight(.medium)
        } else {
            Text("now.block.due \(due.formatted(date: .abbreviated, time: .shortened))")
        }
    }
}

private struct NowWaitingRow: View {
    let item: NowWaiting
    let now: Date
    let open: (UUID, UUID, String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xs) {
                (Text(item.isQuestion ? "now.question" : "now.review").fontWeight(.bold) + Text(verbatim: ": ") + Text(verbatim: item.text))
                    .font(.subheadline).lineLimit(typeSize.isAccessibilitySize ? nil : 4)
                FlowLayout(spacing: Space.xs) {
                    if !item.taskTitle.isEmpty { Text(verbatim: item.taskTitle).lineLimit(2) }
                    Text(verbatim: "· " + item.projectName).lineLimit(1)
                    if let at = item.createdAt { Text(verbatim: "· " + CommandFormat.relative(at, now: now)) }
                }
                .font(.footnote).foregroundStyle(Color.textSecondary)
            }
            // Both open the task detail: it holds the answer field and the review decision.
            if item.isQuestion {
                Button { open(item.taskID, item.projectID, item.taskTitle) } label: { Text("now.answer").frame(minHeight: TapTarget.minimum - Space.l) }
                    .buttonStyle(.borderedProminent).tint(.brand)
                    .accessibilityIdentifier("now.block.answer")
            } else {
                Button { open(item.taskID, item.projectID, item.taskTitle) } label: { Text("now.look").frame(minHeight: TapTarget.minimum - Space.l) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("now.block.look")
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.priority(2).opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .accessibilityIdentifier("now.block.waiting.item")
    }
}

private struct NowDoneRow: View {
    let item: NowDone
    let now: Date
    let open: (UUID, UUID, String) -> Void

    var body: some View {
        Button { open(item.taskID, item.projectID, item.title) } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.textSecondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(verbatim: item.title).font(.subheadline).lineLimit(3).multilineTextAlignment(.leading)
                    HStack(spacing: Space.xs) {
                        Text(verbatim: item.projectName + " ·")
                        if let at = item.doneAt { Text("now.block.doneAgo \(CommandFormat.relative(at, now: now))") }
                    }
                    .font(.footnote).foregroundStyle(Color.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).tapTarget()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("now.block.done.item")
    }
}
