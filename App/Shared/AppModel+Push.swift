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

    /// Opens the destination of a tapped notification, if there is one waiting.
    func openPendingPushLink() {
        guard phase == .signedIn, let link = PushCoordinator.shared.pendingLink else { return }
        PushCoordinator.shared.pendingLink = nil
        open(link)
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
