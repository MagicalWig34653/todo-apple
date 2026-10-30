import Foundation
import XCTest

@testable import TodoCore

/// Opt-in: the command-center client against a real backend (fixture and virtual passkeys from `LiveEtappe2Tests`).
/// Skipped unless `TODO_LIVE_BASE_URL` is set; needs a backend with a fresh database.
extension LiveEtappe2Tests {
    private func png() -> Data {
        // 1x1 PNG
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    }

    func testCommandCenterEndToEnd() async throws {
        let f = try await fixture()
        let a = f.admin
        let project = try await a.createProject(name: "CC \(f.suffix)")
        let sub = try await a.createProject(name: "CC Sub \(f.suffix)", parentID: project.id)

        // Default agent columns + brief.
        let columns = try await a.applyAgentWorkflowColumns(projectID: project.id)
        XCTAssertEqual(columns.count, 6)
        let brief0 = try await a.agentBrief(projectID: project.id)
        XCTAssertEqual(brief0.version, 0)
        let brief1 = try await a.saveAgentBrief(projectID: project.id, text: "# Goals\nShip it", version: 0)
        XCTAssertEqual(brief1.version, 1)
        do { _ = try await a.saveAgentBrief(projectID: project.id, text: "stale", version: 0); XCTFail("stale write accepted") }
        catch { XCTAssertEqual(error as? APIError, .versionConflict) }
        let brief2 = try await a.saveAgentBrief(projectID: project.id, text: "# Goals\nShip it v2", version: brief1.version)
        XCTAssertEqual(brief2.text, "# Goals\nShip it v2")
        // A non-manager cannot read or write (invisible project => 404).
        do { _ = try await f.bob.agentBrief(projectID: project.id); XCTFail("bob read the brief") }
        catch { XCTAssertEqual(error as? APIError, .notFound) }

        // Feature with a running subtask, a question, a review, a blocked and a done task.
        let feature = try await a.createTask(projectID: project.id, title: "Feature Login")
        let child1 = try await a.createTask(projectID: project.id, title: "Schema")
        let child2 = try await a.createTask(projectID: project.id, title: "Endpunkte")
        try await a.setTaskStructure(feature.id, kind: "feature")
        try await a.setTaskStructure(child1.id, parentTaskID: feature.id)
        try await a.setTaskStructure(child2.id, parentTaskID: feature.id)
        _ = try await a.claimTask(child1.id, agentName: "Claude")
        _ = try await a.postProgressNote(taskID: child1.id, note: "Schema entworfen", percent: 30)
        let question = try await a.askQuestion(taskID: child2.id, prompt: "Welche Datenbank?", options: ["MariaDB", "SQLite"], blocking: true, agentName: "Claude")
        XCTAssertTrue(question.isOpen)
        let toReview = try await a.createTask(projectID: sub.id, title: "Review-Kandidat")
        _ = try await a.requestReview(taskID: toReview.id, summary: "Alles fertig", agentName: "Claude")
        let blocked = try await a.createTask(projectID: project.id, title: "Wartet auf Zugang")
        try await a.setTaskStructure(blocked.id, blockedReason: "Zugangsdaten fehlen")
        let done = try await a.createTask(projectID: project.id, title: "Erledigt")
        _ = try await a.updateTask(done.id, version: done.version, TaskUpdate(status: .done))

        // Build screenshot.
        let attachment = try await a.uploadAttachment(taskID: child1.id, filename: "shot.png", role: .result, mediaType: "image/png", data: png())
        let build = try await a.registerBuild(attachmentID: attachment.id, buildID: "b-\(f.suffix)", label: "Login", platform: "ios")
        XCTAssertEqual(build.attachmentID, attachment.id)

        // Project-scope kanban, including sub-projects.
        let cc = try await a.commandCenter(CommandCenterOptions(projectID: project.id))
        XCTAssertEqual(cc.scope, "project")
        XCTAssertEqual(cc.view, "kanban")
        let lanes = try XCTUnwrap(cc.lanes)
        XCTAssertEqual(lanes.map(\.key), ["running", "question", "review", "ready", "blocked", "done"])
        func ids(_ key: String) -> [UUID] { lanes.first { $0.key == key }?.cards.map(\.id) ?? [] }
        XCTAssertTrue(ids("question").contains(feature.id) || ids("question").contains(child2.id), "question lane has the feature or its subtask")
        XCTAssertTrue(ids("review").contains(toReview.id), "sub-project review is included")
        XCTAssertTrue(ids("blocked").contains(blocked.id))
        XCTAssertTrue(ids("done").contains(done.id))
        XCTAssertEqual(cc.summary.pendingReviews, 1)
        XCTAssertEqual(cc.summary.openQuestions, 1)
        XCTAssertFalse(cc.updates.isEmpty)
        let featureCard = try XCTUnwrap(lanes.flatMap(\.cards).first { $0.id == feature.id })
        XCTAssertTrue(featureCard.isFeature)
        XCTAssertEqual(featureCard.subtasks.count, 2)
        XCTAssertEqual(featureCard.progress.source, "subtasks")
        XCTAssertEqual(featureCard.openQuestionCount, 1)
        XCTAssertEqual(featureCard.questions.first?.options, ["MariaDB", "SQLite"])
        let withBuild = lanes.flatMap(\.cards).first { $0.buildCount > 0 }
        XCTAssertEqual(withBuild?.builds.first?.attachmentID, attachment.id)
        XCTAssertFalse(cc.builds.isEmpty)
        // The preview route serves the screenshot with the client's auth.
        let preview = try await a.previewAttachment(attachment.id)
        XCTAssertFalse(preview.isEmpty)
        let blockedCard = try XCTUnwrap(lanes.flatMap(\.cards).first { $0.id == blocked.id })
        XCTAssertEqual(blockedCard.blockedReason, "Zugangsdaten fehlen")

        // Without sub-projects the review disappears.
        var narrow = CommandCenterOptions(projectID: project.id)
        narrow.includeSubprojects = false
        let narrowed = try await a.commandCenter(narrow)
        XCTAssertFalse((narrowed.lanes ?? []).flatMap(\.cards).contains { $0.id == toReview.id })

        // List view with filters.
        var list = CommandCenterOptions(projectID: project.id, view: .list)
        list.hasQuestion = true
        list.includeSubtasks = true
        let listed = try await a.commandCenter(list)
        XCTAssertNil(listed.lanes)
        XCTAssertTrue((listed.items ?? []).contains { $0.openQuestionCount > 0 })
        XCTAssertEqual(listed.total, listed.items?.count)

        // Account scope sees the project's cards too.
        let account = try await a.commandCenter()
        XCTAssertEqual(account.scope, "account")
        XCTAssertTrue((account.lanes ?? []).flatMap(\.cards).contains { $0.id == blocked.id })
        // Bob sees nothing of it.
        let bobCC = try await f.bob.commandCenter()
        XCTAssertFalse((bobCC.lanes ?? []).flatMap(\.cards).contains { $0.id == blocked.id })
        do { _ = try await f.bob.commandCenter(CommandCenterOptions(projectID: project.id)); XCTFail("invisible project") }
        catch { XCTAssertEqual(error as? APIError, .notFound) }

        // Questions: list, invalid option, answer, repeated answer.
        let open = try await a.questions(projectID: project.id)
        XCTAssertEqual(open.map(\.id), [question.id])
        XCTAssertEqual(open.first?.taskTitle, "Endpunkte")
        do { _ = try await a.answerQuestion(question.id, answer: "Postgres"); XCTFail("bad option accepted") }
        catch { XCTAssertEqual(error as? APIError, .invalidInput(reason: "invalid_answer_option")) }
        let answered = try await a.answerQuestion(question.id, answer: "MariaDB")
        XCTAssertEqual(answered.state, "answered")
        XCTAssertEqual(answered.answer, "MariaDB")
        do { _ = try await a.answerQuestion(question.id, answer: "SQLite"); XCTFail("second answer accepted") }
        catch { XCTAssertEqual(error as? APIError, .conflict(reason: "question_already_answered")) }
        let stillOpen = try await a.questions(projectID: project.id)
        XCTAssertTrue(stillOpen.isEmpty)
        let all = try await a.questions(projectID: project.id, state: .all)
        XCTAssertEqual(all.count, 1)

        // Free-text question (no options).
        let free = try await a.askQuestion(taskID: blocked.id, prompt: "Wie lautet das Passwort-Schema?", agentName: "Claude")
        XCTAssertEqual(free.options, [])
        let freeAnswer = try await a.answerQuestion(free.id, answer: "Mindestens 12 Zeichen")
        XCTAssertEqual(freeAnswer.answer, "Mindestens 12 Zeichen")

        // Reviews: pending list, request changes, then a new review and accept.
        let pending = try await a.reviews(projectID: project.id)
        XCTAssertEqual(pending.map(\.taskID), [toReview.id])
        let changes = try await a.decideReview(taskID: toReview.id, decision: .requestChanges, note: "Bitte Tests ergaenzen")
        XCTAssertEqual(changes.state, "changes_requested")
        do { _ = try await a.decideReview(taskID: toReview.id, decision: .accept); XCTFail("no pending review") }
        catch { XCTAssertEqual(error as? APIError, .conflict(reason: "no_pending_review")) }
        _ = try await a.requestReview(taskID: toReview.id, summary: "Tests ergaenzt", agentName: "Claude")
        let accepted = try await a.decideReview(taskID: toReview.id, decision: .accept)
        XCTAssertEqual(accepted.state, "accepted")
        let after = try await a.commandCenter(CommandCenterOptions(projectID: project.id))
        XCTAssertTrue((after.lanes ?? []).first { $0.key == "done" }?.cards.contains { $0.id == toReview.id } ?? false)

        // Task context.
        let ctx = try await a.taskContext(child1.id)
        XCTAssertEqual(ctx.projectID, project.id)
        XCTAssertEqual(ctx.workflow.parentTaskID, feature.id)
        XCTAssertEqual(ctx.progressNotes.first?.note, "Schema entworfen")
        XCTAssertEqual(ctx.builds.count, 1)
    }

    /// Seeds a rich command-center demo (needs `TODO_LIVE_SEED_CC_OUT` for the token file and optionally
    /// `TODO_LIVE_SEED_SCREENSHOTS` with a comma-separated list of PNG paths used as build screenshots).
    func testSeedCommandCenterDemo() async throws {
        guard let out = ProcessInfo.processInfo.environment["TODO_LIVE_SEED_CC_OUT"] else { throw XCTSkip("TODO_LIVE_SEED_CC_OUT not set") }
        let f = try await fixture()
        let a = f.admin
        let shots = (ProcessInfo.processInfo.environment["TODO_LIVE_SEED_SCREENSHOTS"] ?? "").split(separator: ",").compactMap { try? Data(contentsOf: URL(fileURLWithPath: String($0))) }
        let app = try await a.createProject(name: "Todo-App")
        let web = try await a.createProject(name: "Website")
        _ = try await a.applyAgentWorkflowColumns(projectID: app.id)
        _ = try await a.saveAgentBrief(projectID: app.id, text: "# Goals\nNative Apps fuer iOS und macOS.\n\n# Constraints\n- Texte Deutsch\n- Code Englisch\n\n# Definition of done\nTests gruen, Screenshot angehaengt.", version: 0)

        let login = try await a.createTask(projectID: app.id, title: "Anmeldung mit Passkey")
        try await a.setTaskStructure(login.id, kind: "feature")
        let s1 = try await a.createTask(projectID: app.id, title: "Registrierung")
        let s2 = try await a.createTask(projectID: app.id, title: "Anmeldung")
        let s3 = try await a.createTask(projectID: app.id, title: "Wiederherstellung")
        for s in [s1, s2, s3] { try await a.setTaskStructure(s.id, parentTaskID: login.id) }
        _ = try await a.updateTask(s1.id, version: s1.version, TaskUpdate(status: .done))
        _ = try await a.claimTask(s2.id, agentName: "Claude Code")
        _ = try await a.postProgressNote(taskID: s2.id, note: "Passkey-Ablauf implementiert, Tests laufen", percent: 60)
        _ = try await a.askQuestion(taskID: s3.id, prompt: "Soll die Wiederherstellung per E-Mail oder per Recovery-Code laufen?", options: ["E-Mail", "Recovery-Code"], blocking: true, agentName: "Claude Code")

        let board = try await a.createTask(projectID: app.id, title: "Kanban-Board")
        try await a.setTaskStructure(board.id, kind: "feature")
        _ = try await a.claimTask(board.id, agentName: "Claude Code")
        _ = try await a.postProgressNote(taskID: board.id, note: "Spalten und Karten fertig, Drag and Drop offen", percent: 70)
        for (i, data) in shots.enumerated() {
            let att = try await a.uploadAttachment(taskID: board.id, filename: "build-\(i).png", role: .result, mediaType: "image/png", data: data)
            _ = try await a.registerBuild(attachmentID: att.id, buildID: "2610300\(i + 1)", label: i == 0 ? "Board iPhone" : "Board iPad", platform: "ios")
        }

        let review = try await a.createTask(projectID: app.id, title: "Suche mit Filtern")
        _ = try await a.requestReview(taskID: review.id, summary: "Suche nach Text, Etikett und Projekt umgesetzt; 12 Tests gruen.", agentName: "Claude Code")
        let review2 = try await a.createTask(projectID: web.id, title: "Startseite Texte")
        _ = try await a.requestReview(taskID: review2.id, summary: "Neue Texte eingepflegt.", agentName: "Claude Code")

        let free = try await a.createTask(projectID: web.id, title: "Impressum anlegen")
        _ = try await a.askQuestion(taskID: free.id, prompt: "Welche Anschrift soll im Impressum stehen?", blocking: true, agentName: "Claude Code")

        _ = try await a.createTask(projectID: app.id, title: "Hellmodus pruefen")
        _ = try await a.createTask(projectID: web.id, title: "Cookie-Hinweis")
        let blocked = try await a.createTask(projectID: app.id, title: "TestFlight-Upload")
        try await a.setTaskStructure(blocked.id, blockedReason: "Wartet auf App-Store-Connect-Eintrag")
        let done = try await a.createTask(projectID: web.id, title: "Domain einrichten")
        _ = try await a.updateTask(done.id, version: done.version, TaskUpdate(status: .done))
        let seed = try JSONSerialization.data(withJSONObject: ["token": try f.adminStore.load() ?? "", "appProject": app.id.uuidString, "webProject": web.id.uuidString])
        try seed.write(to: URL(fileURLWithPath: out))
    }
}
