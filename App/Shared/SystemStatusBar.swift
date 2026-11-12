import SwiftUI
import TodoCore

/// Lage-Ampel state (contract system-status): the watcher's latest report, refetched on live hints and every 60 s
/// as the fallback. A failed or empty load keeps the last answer (it turns grey by age); a 404 hides the bar.
@MainActor @Observable
final class SystemStatusModel {
    private(set) var response: SystemStatusResponse?
    private(set) var fetchedAt = Date()
    @ObservationIgnored private var loading = false

    func load(_ app: AppModel) async {
        #if DEBUG
        if let stub = Self.debugStub { response = stub; fetchedAt = Date(); return }
        #endif
        guard let client = app.client, !loading else { return }
        LiveHub.shared.subscribe(self) { [weak self] in await self?.load(app) }
        loading = true; defer { loading = false }
        do {
            let next = try await client.systemStatus()
            if next != response { response = next }
            fetchedAt = Date()
        } catch APIError.notFound {
            response = nil
        } catch {
            // Background widget: keep the last answer.
        }
    }

    /// Polling fallback, cancelled with the view's task.
    func poll(_ app: AppModel) async {
        await load(app)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if Task.isCancelled { return }
            await load(app)
        }
    }

    #if DEBUG
    /// `TODO_DEBUG_SYSTEM_STATUS` holds a response JSON; `{AGE:<min>}` inside reportedAt/now is not supported, instead
    /// `TODO_DEBUG_SYSTEM_STATUS_AGE` (minutes) sets how old the report is relative to now.
    private static var debugStub: SystemStatusResponse? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["TODO_DEBUG_SYSTEM_STATUS"] else { return nil }
        struct Stub: Decodable { let status: SystemStatusDocument }
        guard let stub = try? JSONDecoder().decode(Stub.self, from: Data(raw.utf8)) else { return nil }
        let age = Double(env["TODO_DEBUG_SYSTEM_STATUS_AGE"] ?? "") ?? 2
        let now = Date()
        return SystemStatusResponse(items: [SystemStatusItem(source: "default", label: nil, reportedAt: now.addingTimeInterval(-age * 60), status: stub.status)], now: now)
    }
    #endif
}

/// Compact one-card row: Claude (light + usable accounts), Codex (used vs allowed), disk (GB free), "vor X min".
/// Older than 30 min = grey with a hint. Without data the row is hidden.
struct SystemStatusBar: View {
    @Environment(AppModel.self) private var app

    /// The host view runs `app.systemStatus.poll(app)` in its own `.task`: a task on this view would never start while
    /// the bar is empty (modifiers on an empty view do not run).
    var body: some View {
        let model = app.systemStatus
        if let response = model.response, !response.items.isEmpty {
            // The clock only advances the "vor X min" text, every 15 s.
            TimelineView(.periodic(from: .now, by: 15)) { context in
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(response.items) { item in
                        let age = item.ageMinutes(serverNow: response.now, fetchedAt: model.fetchedAt, now: context.date)
                        SystemStatusRow(item: item, ageMinutes: age)
                    }
                }
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("lage.label"))
            .accessibilityIdentifier("systemStatus")
        }
    }
}

struct SystemStatusRow: View {
    let item: SystemStatusItem
    let ageMinutes: Int

    private var stale: Bool { SystemStatusItem.isStale(ageMinutes: ageMinutes) }
    private var s: SystemStatusDocument { item.status }

    /// Same palette as the lanes and due dates: green, orange, red; grey when the report is stale.
    private func color(_ ampel: Ampel?) -> Color {
        if stale { return .textSecondary }
        switch ampel {
        case .gruen: return .dueToday
        case .gelb: return .priority(2)
        case .rot: return .dueOverdue
        case nil: return .textSecondary
        }
    }

    private func ampelName(_ a: Ampel) -> LocalizedStringKey {
        switch a { case .gruen: "lage.ampel.gruen"; case .gelb: "lage.ampel.gelb"; case .rot: "lage.ampel.rot" }
    }

    private static func number(_ n: Double) -> String {
        let r = (n * 10).rounded() / 10
        return (r == r.rounded() ? String(Int(r)) : String(r)).replacingOccurrences(of: ".", with: ",")
    }

    private static func pct(_ n: Double) -> String { number(n) + " %" }

    var body: some View {
        FlowLayout(spacing: Space.xs) {
            if s.hasClaude { claude }
            if let codex = s.codex { codexChip(codex) }
            if s.hasDisk { disk }
            age
        }
        .font(.caption.weight(.semibold))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(stale ? "systemStatus.stale" : "systemStatus.row")
    }

    private func chip(_ title: LocalizedStringKey, color: Color, @ViewBuilder detail: () -> some View) -> some View {
        HStack(spacing: Space.xs) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(title).foregroundStyle(Color.textSecondary)
            detail().foregroundStyle(color)
        }
        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
        .background(color.opacity(0.10), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    private var claude: some View {
        chip("lage.claude", color: color(s.claudeAmpel)) {
            if s.claudeAccounts.isEmpty { Text("lage.noAccounts") }
            else { Text("lage.accounts \(s.claudeAccounts.map(String.init).joined(separator: ", "))") }
        }
        .accessibilityIdentifier("systemStatus.claude")
    }

    private func codexChip(_ codex: CodexStatus) -> some View {
        chip("lage.codex", color: stale ? .textSecondary : (codex.isWarning ? .priority(2) : .dueToday)) {
            if let allowed = codex.allowedPct { Text("lage.codexUsed \(Self.pct(codex.usedPct)) \(Self.pct(allowed))") }
            else { Text("lage.codexUsedOnly \(Self.pct(codex.usedPct))") }
        }
        .accessibilityIdentifier("systemStatus.codex")
    }

    private var disk: some View {
        chip("lage.disk", color: color(s.diskAmpel)) {
            if let gb = s.diskFreeGB { Text("lage.diskFree \(Self.number(gb))") }
            else if let a = s.diskAmpel { Text(ampelName(a)) }
        }
        .accessibilityIdentifier("systemStatus.disk")
    }

    private var age: some View {
        HStack(spacing: Space.xs) {
            if ageMinutes < 1 { Text("lage.agoNow") } else { Text("lage.ago \(ageMinutes)") }
            if stale { Text("lage.stale").padding(.horizontal, Space.xs).background(Color.textSecondary.opacity(0.15), in: Capsule()) }
        }
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, Space.xs).padding(.vertical, Space.xs)
        .accessibilityIdentifier("systemStatus.age")
    }
}
