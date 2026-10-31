import SwiftUI
import TodoCore

/// Live refresh in the app (ADR 0022): owns the single `LiveRefresh` loop of the signed-in account, keeps it running
/// only in the foreground and tells visible views to refetch what the sync feed does not carry (command center,
/// questions, reviews, comments, activity, runner jobs). Feed data (projects, tasks, columns) is refreshed through
/// `AppModel.reload()` before subscribers run. Subscribers are weak and re-register on every load, so only views that
/// are alive refetch; each one replaces its data only if it changed.
@MainActor @Observable
final class LiveHub {
    static let shared = LiveHub()

    /// Increments for every `changed` notification (for views that prefer `onChange`).
    private(set) var tick = 0
    private(set) var mode: LiveRefresh.Mode = .idle
    private(set) var foreground = false

    private struct Subscriber {
        weak var owner: AnyObject?
        let refetch: @MainActor () async -> Void
    }
    @ObservationIgnored private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    @ObservationIgnored private var live: LiveRefresh?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var accountID: UUID?

    /// Registers (or replaces) the refetch of a view model. Call it from the model's `load`.
    func subscribe(_ owner: AnyObject, _ refetch: @escaping @MainActor () async -> Void) {
        subscribers = subscribers.filter { $0.value.owner != nil }
        subscribers[ObjectIdentifier(owner)] = Subscriber(owner: owner, refetch: refetch)
    }

    /// Account signed in (idempotent per account). The loop only runs while `setForeground(true)`.
    func begin(_ model: AppModel) {
        guard let client = model.client, let id = model.user?.id else { return }
        if accountID == id, live != nil { return }
        end()
        accountID = id
        let live = LiveRefresh(
            transport: client,
            lowPower: { ProcessInfo.processInfo.isLowPowerModeEnabled },
            syncAction: { [weak model] in await model?.reload() })
        self.live = live
        eventTask = Task { [weak self, weak model] in
            let stream = await live.events()
            await live.start()
            await live.setForeground(await MainActor.run { self?.foreground ?? false })
            for await event in stream {
                guard let self, let model else { return }
                await self.handle(event, model)
            }
        }
    }

    /// Sign-out or account switch.
    func end() {
        eventTask?.cancel(); eventTask = nil
        let old = live
        live = nil; accountID = nil; mode = .idle
        if let old { Task { await old.stop() } }
    }

    func setForeground(_ on: Bool) {
        guard on != foreground else { return }
        foreground = on
        if let live { Task { await live.setForeground(on) } }
    }

    private func handle(_ event: LiveEvent, _ model: AppModel) async {
        switch event {
        case .changed:
            guard foreground else { return }
            tick += 1
            await model.refreshCommandSummary()  // sidebar counters
            for sub in Array(subscribers.values) {
                guard sub.owner != nil else { continue }
                await sub.refetch()
            }
            subscribers = subscribers.filter { $0.value.owner != nil }
        case .signedOut:
            await model.handle(APIError.unauthorized(reason: nil))
        case .modeChanged(let m):
            mode = m
        }
    }
}

/// Live refresh lifecycle (ADR 0022): one loop for the account, foreground only; on return `head` is checked at once.
struct LiveRefreshLifecycle: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task { LiveHub.shared.begin(model); LiveHub.shared.setForeground(scenePhase == .active) }
            .onDisappear { LiveHub.shared.end() }
            .onChange(of: scenePhase) { _, phase in LiveHub.shared.setForeground(phase == .active) }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in LiveHub.shared.setForeground(true) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in LiveHub.shared.setForeground(false) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in LiveHub.shared.setForeground(NSApp.isActive) }
            #endif
    }
}
