import SwiftUI
import TodoCore

/// State of the "Für dich" feed (backend ADR 0023): items that need the user on top, chronological posts below.
/// Page 1 is refetched on appear, on pull-to-refresh and on live-refresh hints; later pages append.
@MainActor @Observable
final class FeedModel {
    private(set) var state = FeedState()
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var unsupported = false
    private(set) var failed = false
    private(set) var busy: Set<String> = []
    var errorKey: String?

    func load(_ app: AppModel) async {
        guard let client = app.client, !loading else { return }
        LiveHub.shared.subscribe(self) { [weak self] in
            if let self, self.busy.isEmpty { await self.load(app) }
        }
        loading = true; defer { loading = false }
        do {
            let page = try await client.feed(limit: 30)
            var next = state
            next.replace(with: page)
            if next != state { state = next }
            unsupported = false; failed = false
        } catch APIError.notFound {
            unsupported = true
        } catch APIError.unauthorized {
            await app.handle(APIError.unauthorized(reason: nil))
        } catch {
            failed = true
            if !state.loaded { errorKey = AppModel.key(for: error) }
        }
    }

    func loadMore(_ app: AppModel) async {
        guard let client = app.client, let cursor = state.nextCursor, !loadingMore, !loading else { return }
        loadingMore = true; defer { loadingMore = false }
        do { state.append(try await client.feed(cursor: cursor, limit: 30)) }
        catch { failed = true }
    }

    /// Runs a server-described action; the item disappears at once and the feed is refetched afterwards.
    func perform(_ item: FeedNeedsYou, _ action: FeedAction, input: String? = nil, _ app: AppModel) async {
        guard let client = app.client, !busy.contains(item.id) else { return }
        busy.insert(item.id)
        do {
            try await client.perform(action, input: input)
            state.remove(needsYouID: item.id)
            Haptics.success()
        } catch APIError.conflict { errorKey = "feed.error.alreadyHandled"
        } catch APIError.forbidden { errorKey = "error.forbidden"
        } catch { errorKey = AppModel.key(for: error) }
        busy.remove(item.id)
        await load(app)
        await app.reload()
    }
}
