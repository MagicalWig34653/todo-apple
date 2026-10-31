import SwiftUI
import TodoCore

// Server-backed project state (ADR 0012): favourites, display settings, description/colour, order, plus the one-time
// import of the former device-local values and the board column operations through the sync queue.

enum ProjectDropZone { case before, after, into }

private struct PrefsCache: Codable {
    var prefs: [ProjectDisplayPrefs] = []
    var pending: [String: ProjectPrefsPatch] = [:]
}

private struct LegacyOptions: Codable {
    var mode: String = "list"
    var sort: String = "manual"
    var group: String = "none"
    var showCompleted = false
}

extension AppModel {
    // MARK: Account-scoped cache of the display settings

    private var accountKey: String { "\(serverURL)|\(user?.id.uuidString ?? "-")" }
    private var prefsCacheKey: String { "prefsCache.\(accountKey)" }

    func loadPrefsCache() {
        guard let data = UserDefaults.standard.data(forKey: prefsCacheKey),
            let cache = try? JSONDecoder().decode(PrefsCache.self, from: data)
        else { displayPrefs = [:]; pendingPrefs = [:]; return }
        displayPrefs = Dictionary(cache.prefs.map { ($0.projectID, $0) }, uniquingKeysWith: { a, _ in a })
        pendingPrefs = Dictionary(uniqueKeysWithValues: cache.pending.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
    }

    private func savePrefsCache() {
        let cache = PrefsCache(prefs: Array(displayPrefs.values), pending: Dictionary(uniqueKeysWithValues: pendingPrefs.map { ($0.key.uuidString, $0.value) }))
        UserDefaults.standard.set(try? JSONEncoder().encode(cache), forKey: prefsCacheKey)
    }

    // MARK: Display settings

    /// The account's settings for a project (server values, unsent local edits on top; server defaults otherwise).
    func prefs(for id: UUID) -> ProjectDisplayPrefs {
        var p = displayPrefs[id] ?? ProjectDisplayPrefs(projectID: id)
        #if DEBUG
        if displayPrefs[id] == nil, ProcessInfo.processInfo.environment["TODO_DEBUG_BOARD"] == "1" { p.view = "board" }
        #endif
        if let patch = pendingPrefs[id] { p = patch.applied(to: p) }
        return p
    }

    func setPrefs(_ patch: ProjectPrefsPatch, for id: UUID) {
        guard !patch.isEmpty else { return }
        pendingPrefs[id] = (pendingPrefs[id] ?? ProjectPrefsPatch()).merged(with: patch)
        savePrefsCache()
        Task { await flushPrefs() }
    }

    /// Sends unsent settings; transport problems keep them for the next sync, a stale revision is refetched once.
    func flushPrefs() async {
        guard let client, !prefsFlushing, !pendingPrefs.isEmpty else { return }
        prefsFlushing = true
        defer { prefsFlushing = false }
        for (id, patch) in pendingPrefs {
            var revision = displayPrefs[id]?.revision ?? 0
            for _ in 0..<2 {
                do {
                    let result = try await client.patchProjectPrefs(id, revision: revision, patch)
                    displayPrefs[id] = result
                    if pendingPrefs[id] == patch { pendingPrefs[id] = nil }
                    break
                } catch APIError.conflict(let reason) where reason == "revision_conflict" {
                    guard let fresh = try? await client.projectPrefs(for: id) else { break }
                    displayPrefs[id] = fresh
                    revision = fresh.revision
                } catch APIError.notFound {
                    pendingPrefs[id] = nil
                    break
                } catch { break }
            }
        }
        savePrefsCache()
    }

    /// After a sync: send local settings, fetch the stored ones, import the old device-local values once.
    func refreshServerState() async {
        guard let client else { return }
        await flushPrefs()
        if let list = try? await client.projectPrefs() {
            displayPrefs = Dictionary(list.map { ($0.projectID, $0) }, uniquingKeysWith: { a, _ in a })
            savePrefsCache()
        }
        await importLegacyIfNeeded(client)
    }

    /// One-time import of the former UserDefaults values (favourites, display options, descriptions) into the
    /// account, but only where the server has nothing yet. Skipped silently while offline and retried later.
    private func importLegacyIfNeeded(_ client: APIClient) async {
        let d = UserDefaults.standard
        let doneKey = "legacyImport.\(accountKey)"
        guard !d.bool(forKey: doneKey), user != nil else { return }
        let favs = (d.stringArray(forKey: "pref.favorites") ?? []).compactMap(UUID.init(uuidString:))
        let options = d.data(forKey: "pref.projectOptions").flatMap { try? JSONDecoder().decode([String: LegacyOptions].self, from: $0) } ?? [:]
        let descriptions = d.dictionary(forKey: "pref.projectDescriptions") as? [String: String] ?? [:]
        func clearLegacy() {
            for k in ["pref.favorites", "pref.projectOptions", "pref.projectDescriptions"] { d.removeObject(forKey: k) }
            d.set(true, forKey: doneKey)
        }
        if favs.isEmpty && options.isEmpty && descriptions.isEmpty { d.set(true, forKey: doneKey); return }
        guard !projects.isEmpty, let serverFavorites = try? await client.favorites() else { return }
        let known = Set(projects.map(\.id))
        if serverFavorites.isEmpty {
            var entries: [FavoriteEntry] = []
            for id in favs where known.contains(id) {
                guard let list = try? await client.setFavorite(id) else { return }
                entries = list
            }
            if !entries.isEmpty { await applyFavorites(entries) }
        }
        for (key, o) in options {
            guard let id = UUID(uuidString: key), known.contains(id), (displayPrefs[id]?.revision ?? 0) == 0 else { continue }
            let patch = ProjectPrefsPatch(
                view: o.mode, sort: o.sort == "name" ? "title" : o.sort, grouping: o.group, showCompleted: o.showCompleted)
            setPrefs(patch, for: id)
        }
        for (key, text) in descriptions {
            guard let id = UUID(uuidString: key), let p = projects.first(where: { $0.id == id }),
                (p.description ?? "").isEmpty, !text.isEmpty else { continue }
            await updateProject(p, ProjectUpdate(description: text))
        }
        clearLegacy()
    }

    /// Server colour of the project, else the stable id-derived fallback.
    func projectColor(_ id: UUID?) -> Color {
        if let id, let hex = projects.first(where: { $0.id == id })?.color, let c = Color(hex: hex) { return c }
        return Color.project(id)
    }

    // MARK: Favourites

    var favoriteProjects: [Project] {
        projects.filter(\.isFavorite).sorted { ($0.favoritePosition ?? Int.max, $0.name) < ($1.favoritePosition ?? Int.max, $1.name) }
    }

    private func applyFavorites(_ entries: [FavoriteEntry]) async {
        guard let engine, !usesREST else { return }
        try? await engine.applyFavorites(entries)
        publish(await engine.snapshot())
    }

    func toggleFavorite(_ project: Project) async {
        guard let client else { return }
        let before = favoriteProjects.enumerated().map { FavoriteEntry(projectID: $1.id, position: $0) }
        var after = before.filter { $0.projectID != project.id }
        if !project.isFavorite { after.append(FavoriteEntry(projectID: project.id, position: after.count)) }
        after = after.enumerated().map { FavoriteEntry(projectID: $1.projectID, position: $0) }
        await applyFavorites(after)  // optimistic
        do {
            let confirmed: [FavoriteEntry]
            if project.isFavorite { try await client.removeFavorite(project.id); confirmed = try await client.favorites() }
            else { confirmed = try await client.setFavorite(project.id) }
            if hasEngine { await applyFavorites(confirmed) } else { await reloadREST() }
        } catch {
            await applyFavorites(before)
            await handle(error)
        }
    }

    // MARK: Project details and order

    func updateProject(_ project: Project, _ update: ProjectUpdate) async {
        guard let client else { return }
        if await queueChange({ try await $0.updateProject(project.id, update) }) { return }
        do { _ = try await client.updateProject(project.id, version: project.version, update); await reloadREST() }
        catch { await handle(error) }
    }

    func setProjectColor(_ project: Project, hex: String) async { await updateProject(project, ProjectUpdate(color: hex)) }

    func effectiveParent(of p: Project) -> UUID? { p.parentID.flatMap { id in projects.contains { $0.id == id } ? id : nil } }

    private func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {
        var current: UUID? = id
        var seen = Set<UUID>()
        while let c = current, seen.insert(c).inserted {
            if c == ancestor { return true }
            current = projects.first { $0.id == c }.flatMap(effectiveParent(of:))
        }
        return false
    }

    /// Moves a project under `parent` (nil = top level) at `index` among that parent's other children (nil = end).
    /// A move inside the same parent is a purely personal reorder; a new parent changes the shared tree.
    func moveProject(_ id: UUID, toParent parent: UUID?, at index: Int?) async {
        guard let client, let p = projects.first(where: { $0.id == id }) else { return }
        if let parent, parent == id || isDescendant(parent, of: id) { noticeKey = "notice.projectCycle"; return }
        let siblings = projects.filter { effectiveParent(of: $0) == parent && $0.id != id }
        let target = min(max(index ?? siblings.count, 0), siblings.count)
        let change: ProjectParentChange = parent == effectiveParent(of: p) ? .keep : (parent.map { .parent($0) } ?? .root)
        if await queueChange({ try await $0.moveProject(id, index: target, parent: change) }) { return }
        do {
            _ = try await client.putProjectPosition(id, index: target, parent: change, version: change == .keep ? nil : p.version)
            await reloadREST()
        } catch { await handle(error) }
    }

    /// Drop of a dragged project onto a sidebar row: above/below the row (sibling) or onto it (child).
    /// Moves a task to another project: offline-first through the sync queue (`task.update` with `projectID`), REST otherwise.
    func moveTask(_ task: TodoTask, toProject projectID: UUID) async {
        guard task.projectID != projectID else { return }
        if await queueChange({ try await $0.updateTask(task.id, TaskUpdate(projectID: projectID)) }) { return }
        guard let client else { return }
        do { apply(try await client.updateTask(task.id, version: task.version, TaskUpdate(projectID: projectID))) }
        catch { await handle(error) }
    }

    func dropProject(_ id: UUID, on target: Project, zone: ProjectDropZone) async {
        guard id != target.id else { return }
        switch zone {
        case .into:
            await moveProject(id, toParent: target.id, at: nil)
        case .before, .after:
            let parent = effectiveParent(of: target)
            let siblings = projects.filter { effectiveParent(of: $0) == parent && $0.id != id }
            guard let i = siblings.firstIndex(where: { $0.id == target.id }) else { return }
            await moveProject(id, toParent: parent, at: zone == .before ? i : i + 1)
        }
    }

    // MARK: Board columns and cards (offline-capable through the sync queue)

    func createColumn(projectID: UUID, name: String, isDone: Bool? = nil) async {
        guard let client else { return }
        if await queueChange({ try await $0.createColumn(projectID: projectID, name: name, isDone: isDone) }) { return }
        do { _ = try await client.createColumn(projectID: projectID, name: name, isDone: isDone) } catch { await handle(error) }
    }

    func updateColumn(_ column: BoardColumn, projectID: UUID, name: String? = nil, color: String? = nil, isDone: Bool? = nil, index: Int? = nil) async {
        guard let client, let id = column.id, let version = column.version else { return }
        if await queueChange({ try await $0.updateColumn(id, name: name, color: color, isDone: isDone, index: index) }) { return }
        do { _ = try await client.updateColumn(projectID: projectID, columnID: id, version: version, name: name, color: color, isDone: isDone, index: index) }
        catch { await handle(error) }
    }

    func deleteColumn(_ column: BoardColumn, projectID: UUID) async {
        guard let client, let id = column.id else { return }
        if await queueChange({ try await $0.deleteColumn(id) }) { return }
        do { try await client.deleteColumn(projectID: projectID, columnID: id, version: column.version) } catch { await handle(error) }
    }

    /// Returns the task as it now looks (optimistic with the sync queue, the server answer without).
    @discardableResult
    func moveTask(_ task: TodoTask, toColumn columnID: UUID?, index: Int?) async -> TodoTask? {
        guard let client else { return nil }
        if await queueChange({ try await $0.moveTask(task.id, toColumn: columnID, index: index) }) { return tasks.first { $0.id == task.id } }
        do { let updated = try await client.moveTask(task.id, version: task.version, toColumn: columnID, index: index); apply(updated); return updated }
        catch { await handle(error); return nil }
    }
}
