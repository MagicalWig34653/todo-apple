import Foundation
import TodoCore

// Push integration of the app model (ADR 0021): registration, deep links from notifications, actions.
extension AppModel {
    /// Detects server support, loads preferences, registers the device when the system permission already exists.
    func pushSync() async {
        guard phase == .signedIn else { return }
        await PushCoordinator.shared.sync(client: client, userID: user?.id)
    }

    func pushTokenChanged() async {
        guard phase == .signedIn else { return }
        await PushCoordinator.shared.register(client: client, userID: user?.id)
    }

    func enablePush() async {
        await PushCoordinator.shared.requestAuthorization(client: client, userID: user?.id)
    }

    /// Opens the destination of a tapped notification, if there is one waiting. The link stays pending while its project
    /// cannot be shown yet (`PushLink.readiness`): `beginSync` calls again once the lists are there.
    func openPendingPushLink() {
        guard phase == .signedIn, let link = PushCoordinator.shared.pendingLink else { return }
        switch link.readiness(knownProjects: Set(projects.map(\.id)), initialDataLoaded: initialDataLoaded) {
        case .wait: return
        case .refresh: refreshForPushLink()
        case .now:
            PushCoordinator.shared.pendingLink = nil
            open(link)
        }
    }

    /// The push is about a project that is not in the lists: fetch, then open the latest pending link whatever came of it
    /// (offline or no access any more: the fallback destination). A sync that is already running makes `reload` return
    /// at once, hence the few short retries.
    private func refreshForPushLink() {
        guard !pushLinkRefreshing else { return }
        pushLinkRefreshing = true
        let generation = sessionGeneration
        Task {
            defer { pushLinkRefreshing = false }
            for attempt in 0..<4 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(700)) }
                await reload()
                guard generation == sessionGeneration else { return }
                if let id = PushCoordinator.shared.pendingLink?.requiredProjectID, projects.contains(where: { $0.id == id }) { break }
            }
            guard phase == .signedIn, let link = PushCoordinator.shared.pendingLink else { return }
            PushCoordinator.shared.pendingLink = nil
            open(link)
        }
    }

    func open(_ link: PushLink) {
        func placeholder(_ id: UUID, _ projectID: UUID?) -> TodoTask? {
            if let known = tasks.first(where: { $0.id == id }) { return known }
            guard let projectID = projectID ?? projects.first?.id else { return nil }
            return TodoTask(id: id, projectID: projectID, title: String(localized: "push.task.fallbackTitle"))
        }
        switch link {
        case .task(let taskID, let projectID):
            if let projectID, projects.contains(where: { $0.id == projectID }) { selection = .project(projectID) }
            path = placeholder(taskID, projectID).map { [$0] } ?? []
        case .commandCenter(let taskID, let projectID):
            if let projectID, projects.contains(where: { $0.id == projectID }) { selection = .projectCommandCenter(projectID) }
            else { selection = .commandCenter }
            path = taskID.flatMap { placeholder($0, projectID) }.map { [$0] } ?? []
        case .project(let id):
            if projects.contains(where: { $0.id == id }) { selection = .project(id) }
        case .forYou(let requestID):
            // "Für dich" is the entry whatever happens next; the feed looks for the request after its refresh.
            path = []
            confirmationFocus = requestID
            selection = .feed
        }
    }

    /// "Erledigen" from a reminder notification: through the sync queue when the task is known, REST otherwise.
    func markDoneFromPush(taskID: UUID, projectID: UUID?) async -> Bool {
        if let task = tasks.first(where: { $0.id == taskID }) {
            if task.isDone { return true }
            await toggle(task)
            return true
        }
        guard let client, let projectID else { return false }
        do {
            guard let task = try await client.tasks(projectID: projectID).first(where: { $0.id == taskID }) else { return false }
            if task.isDone { return true }
            let updated = try await client.updateTask(taskID, version: task.version, TaskUpdate(status: .done))
            apply(updated)
            return true
        } catch { return false }
    }
}
