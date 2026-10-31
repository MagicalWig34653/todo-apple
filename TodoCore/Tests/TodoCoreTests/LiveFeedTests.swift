import Foundation
import XCTest

@testable import TodoCore

/// Opt-in: the feed client against a real backend (see `LiveEtappe2Tests` for the fixture). Skipped without `TODO_LIVE_BASE_URL`.
extension LiveEtappe2Tests {
    func testFeedEndToEnd() async throws {
        let f = try await fixture()
        let a = f.admin
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let project = try await a.createProject(name: "Feed \(f.suffix)")
        let task = try await a.createTask(projectID: project.id, title: "Feed Aufgabe")
        _ = try await a.postProgressNote(taskID: task.id, note: "Halbzeit", percent: 50)
        let question = try await a.askQuestion(taskID: task.id, prompt: "Welche DB?", options: ["A", "B"], blocking: true, agentName: "Claude")
        let attachment = try await a.uploadAttachment(taskID: task.id, filename: "shot.png", role: .result, mediaType: "image/png", data: png)
        _ = try await a.registerBuild(attachmentID: attachment.id, buildID: "feed-\(f.suffix)", label: "Login", platform: "ios")

        let page = try await a.feed(projectID: project.id)
        let need = try XCTUnwrap(page.needsYou.first { $0.questionID == question.id })
        XCTAssertEqual(need.kind, "question")
        XCTAssertEqual(need.actions.map(\.label), ["A", "B"])
        let kinds = Set(page.posts.map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: ["progress", "build"]), "\(kinds)")
        let build = try XCTUnwrap(page.posts.first { $0.postKind == .build })
        XCTAssertEqual(build.images.first?.attachmentID, attachment.id)
        let bytes = try await a.previewAttachment(attachment.id)
        XCTAssertFalse(bytes.isEmpty)
        // Pagination with limit 1 reaches every post exactly once.
        var seen: [UUID] = [], cursor: String?
        repeat {
            let p = try await a.feed(cursor: cursor, limit: 1, projectID: project.id)
            seen += p.posts.map(\.id); cursor = p.nextCursor
        } while cursor != nil
        XCTAssertEqual(seen.count, Set(seen).count)
        XCTAssertEqual(seen, page.posts.map(\.id))
        // The returned action answers the question over the existing endpoint.
        try await a.perform(need.actions[0])
        let after = try await a.feed(projectID: project.id)
        XCTAssertFalse(after.needsYou.contains { $0.questionID == question.id })
        XCTAssertTrue(after.posts.contains { $0.postKind == .question })
        // Classic mode hides agent posts; a foreign project is invisible.
        let classic = try await a.feed(projectID: project.id, mode: .classic)
        XCTAssertFalse(classic.posts.contains { $0.postKind == .progress || $0.postKind == .build })
        do { _ = try await f.bob.feed(projectID: project.id); XCTFail("bob saw the feed of a foreign project") }
        catch { XCTAssertEqual(error as? APIError, .notFound) }
        let bob = try await f.bob.feed()
        XCTAssertFalse(bob.posts.contains { $0.projectID == project.id })
    }
}
