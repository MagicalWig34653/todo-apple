import SwiftUI
import TodoCore

/// State of the "Jetzt" screen. The overview is computed by the server per request (no sync feed), so it is refetched
/// on appear, in the foreground, on pull-to-refresh and through the live hub (ADR 0022): no polling of its own.
@MainActor @Observable
final class OverviewNowModel {
    private(set) var data: OverviewNow?
    private(set) var loading = false
    /// True when the server answered 404: an older backend without the overview.
    private(set) var unsupported = false
    private(set) var loadFailed = false
    private(set) var fetchedAt: Date?
    /// Server minus device clock at the last fetch, so ages and the 24-hour rule follow the server's time.
    private var clockOffset: TimeInterval = 0

    @ObservationIgnored private let defaults: UserDefaults
    /// Fixed sample data (previews, debug screenshots): never fetched.
    @ObservationIgnored private var isStub = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Fixed data without a network (previews and debug screenshots).
    init(stub: OverviewNow, now: Date, defaults: UserDefaults = UserDefaults(suiteName: "todolino.now.preview") ?? .standard) {
        self.defaults = defaults
        data = stub
        isStub = true
        fetchedAt = now
        clockOffset = now.timeIntervalSince(Date())
    }

    var now: Date { Date().addingTimeInterval(clockOffset) }
    var groups: OverviewGroups { (data ?? OverviewNow()).grouped(at: now) }
    /// Nothing to show at all (no project with content).
    var isEmpty: Bool { (data ?? OverviewNow()).showsEmptyPage }
    /// The block "Ohne Lebenszeichen" starts collapsed on every visit.
    var silentExpanded = false

    #if DEBUG
    /// `TODO_DEBUG_NOW_STUB=empty|full`: sample data inside the real app shell (UI tests, screenshots); nil without the variable.
    static func debugStub() -> OverviewNowModel? {
        guard let variant = ProcessInfo.processInfo.environment["TODO_DEBUG_NOW_STUB"] else { return nil }
        let data: OverviewNow
        switch variant {
        case "empty": data = OverviewNow(serverTime: OverviewNowSample.now, now: NowBlock())
        // Nothing running or waiting, only done and silent: the short page where all of it is on screen at once.
        case "tail": data = OverviewNow(serverTime: OverviewNowSample.now, now: NowBlock(recentlyDone: OverviewNowSample.block.recentlyDone, silent: OverviewNowSample.block.silent))
        default: data = OverviewNowSample.data
        }
        return OverviewNowModel(stub: data, now: OverviewNowSample.now)
    }
    #endif

    // MARK: Loading

    func refresh(_ app: AppModel) async {
        guard !isStub, let client = app.client, !loading else { return }
        LiveHub.shared.subscribe(self) { [weak self] in
            if let self { await self.refresh(app) }
        }
        loading = true
        defer { loading = false }
        do {
            switch try await client.fetchOverviewNow() {
            case .loaded(let next):
                if data != next { data = next }
                unsupported = false; loadFailed = false
                let received = Date()
                fetchedAt = received
                clockOffset = next.serverTime.map { $0.timeIntervalSince(received) } ?? 0
            case .unsupported:
                unsupported = true; loadFailed = false; data = nil
            }
        } catch APIError.unauthorized {
            await app.handle(APIError.unauthorized(reason: nil))
        } catch {
            // A background refresh keeps the last known state; the screen shows a hint.
            loadFailed = true
        }
    }

    // MARK: Expanded state per project (UserDefaults)

    enum Category: String { case waiting, active, quiet }

    /// The key includes the category: a choice made while a project was quiet must not hide the open question that
    /// moves it to the top later.
    private func key(_ id: UUID, _ category: Category) -> String { "pref.now.expanded.\(id.uuidString).\(category.rawValue)" }

    func isExpanded(_ id: UUID, _ category: Category) -> Bool {
        let k = key(id, category)
        if defaults.object(forKey: k) != nil { return defaults.bool(forKey: k) }
        return category != .quiet
    }

    func setExpanded(_ value: Bool, _ id: UUID, _ category: Category) { defaults.set(value, forKey: key(id, category)) }
}
