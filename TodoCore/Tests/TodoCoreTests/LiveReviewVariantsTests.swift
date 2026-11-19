import XCTest
@testable import TodoCore

/// Opt-in run against a real backend with a fresh scratch database (command-center 1.8.0, review with variants):
/// `TEST_RUNNER_TODO_LIVE_BASE_URL=http://127.0.0.1:28080` (and `TODO_LIVE_RP_ORIGIN` as for the other live tests).
/// `testVariantFlowEndToEnd` checks the server rules through `APIClient`; `testSeedVariantReviews` leaves pending reviews with
/// variants for the screenshot tour and writes `{"token":...}` to `TODO_LIVE_SEED_OUT`. Image variants need
/// `TODO_LIVE_VARIANT_IMAGES` (directory with `windkarte.png`, `radarkarte.png`, `temperaturkarte.png`), else a 1x1 PNG is used.
final class LiveReviewVariantsTests: XCTestCase {
    struct VariantInput: Encodable { let id: String; let label: String; let description: String?; let attachmentID: UUID? }
    struct ReviewInput: Encodable { let summary: String; let agentName: String?; let variants: [VariantInput]? }

    /// One person for the whole run: the bootstrap token works once.
    actor Cache {
        static let shared = Cache()
        var made: (APIClient, InMemoryTokenStore, String)?
        func get(_ make: () async throws -> (APIClient, InMemoryTokenStore, String)) async throws -> (APIClient, InMemoryTokenStore, String) {
            if let made { return made }
            let value = try await make()
            made = value
            return value
        }
    }

    private func admin() async throws -> (APIClient, InMemoryTokenStore, String) {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["TODO_LIVE_BASE_URL"], let url = URL(string: raw) else { throw XCTSkip("TODO_LIVE_BASE_URL not set") }
        let origin = env["TODO_LIVE_RP_ORIGIN"] ?? "http://localhost:25173"
        let token = env["TODO_LIVE_BOOTSTRAP_TOKEN"] ?? "dev-bootstrap-only"
        return try await Cache.shared.get {
            let store = InMemoryTokenStore()
            let client = APIClient(baseURL: url, tokenStore: store)
            guard try await client.capabilities().bootstrapOpen else { throw XCTSkip("bootstrap already used; start a fresh backend database") }
            let suffix = String(UUID().uuidString.prefix(6)).lowercased()
            _ = try await client.registerWithPasskey(token: token, displayName: "Lino \(suffix)", authenticator: VirtualPasskey(origin: origin))
            return (client, store, suffix)
        }
    }

    private func image(_ name: String) -> Data {
        if let dir = ProcessInfo.processInfo.environment["TODO_LIVE_VARIANT_IMAGES"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) { return data }
        return Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    }

    private func requestReview(_ a: APIClient, task: UUID, summary: String, variants: [VariantInput]?) async throws -> Review {
        try await a.send("POST", "v1/tasks/\(task.uuidString.lowercased())/review", body: ReviewInput(summary: summary, agentName: "Claude", variants: variants))
    }

    private func imageVariants(_ a: APIClient, task: UUID) async throws -> [VariantInput] {
        var out: [VariantInput] = []
        for (id, label, text, file) in [("a", "Windkarte", "Wind als Pfeile über der Strecke, ruhig und gut lesbar.", "windkarte"),
                                        ("b", "Radarkarte", "Niederschlagsradar mit Zeitleiste, zeigt Schauer in der Nähe.", "radarkarte"),
                                        ("c", "Temperaturkarte", "Farbflächen nach Temperatur, braucht eine Legende.", "temperaturkarte")] {
            let att = try await a.uploadAttachment(taskID: task, filename: "\(file).png", role: .result, mediaType: "image/png", data: image(file))
            out.append(VariantInput(id: id, label: label, description: text, attachmentID: att.id))
        }
        return out
    }

    private let textVariants = [
        VariantInput(id: "a", label: "Open-Meteo", description: "Kostenlos, ohne Schlüssel, großzügiges Rate-Limit.", attachmentID: nil),
        VariantInput(id: "b", label: "Wetterdienst A", description: "Genauere Regenvorhersage, kostenpflichtig ab 1.000 Abrufen am Tag.", attachmentID: nil),
    ]

    func testVariantFlowEndToEnd() async throws {
        let (a, _, suffix) = try await admin()
        let p = try await a.createProject(name: "Varianten \(suffix)")
        let t = try await a.createTask(projectID: p.id, title: "Kartenwahl")
        let variants = try await imageVariants(a, task: t.id)
        let review = try await requestReview(a, task: t.id, summary: "Kartenwahl: drei Entwürfe", variants: variants)
        XCTAssertEqual(review.variants.map(\.id), ["a", "b", "c"], "variants round-trip through the real server")
        XCTAssertTrue(review.needsChoice)
        XCTAssertEqual(review.variants.first?.attachmentID, variants.first?.attachmentID)

        // The card detail (task context) carries them too, and the decided review keeps the choice there.
        let context = try await a.taskContext(t.id)
        XCTAssertEqual(context.review?.variants.map(\.id), ["a", "b", "c"])
        XCTAssertTrue(context.review?.needsChoice ?? false)

        // The card of the command center carries the variants.
        let cc = try await a.commandCenter(CommandCenterOptions(view: .list))
        let card = try XCTUnwrap(cc.items?.first { $0.task.id == t.id })
        XCTAssertEqual(card.pendingReview?.variants.count, 3)
        XCTAssertTrue(card.pendingReview?.needsChoice ?? false)

        // 422 codes, each mapped.
        func expect(_ code: ReviewVariantError, _ decision: ReviewDecision, variant: String?, note: String? = nil, file: StaticString = #filePath, line: UInt = #line) async {
            do { _ = try await a.decideReview(taskID: t.id, decision: decision, note: note, variantID: variant); XCTFail("422 expected", file: file, line: line) }
            catch { XCTAssertEqual(ReviewVariantError(error), code, file: file, line: line) }
        }
        await expect(.variantRequired, .accept, variant: nil)
        await expect(.unknownVariant, .accept, variant: "zzz")
        await expect(.unexpectedVariant, .requestChanges, variant: "b", note: "x")

        // Choose B: accepted, choice stored, undo window open.
        let before = Date()
        let chosen = try await a.decideReview(taskID: t.id, decision: .accept, variantID: "b")
        XCTAssertEqual(chosen.state, "accepted")
        XCTAssertEqual(chosen.chosenVariantID, "b")
        XCTAssertEqual(chosen.chosenText, "Variante B gewählt: Radarkarte")
        XCTAssertFalse(chosen.needsChoice)
        let until = try XCTUnwrap(chosen.undoUntil)
        XCTAssertEqual(until.timeIntervalSince(before), ReviewUndo.window, accuracy: 15, "server window equals ReviewUndo.window")

        // The server wrote the history line into the review chat.
        let chat = try await a.comments(taskID: t.id, thread: .review(chosen.id))
        XCTAssertTrue(chat.contains { $0.body.contains("Variante B gewählt: Radarkarte") }, "chat: \(chat.map(\.body))")

        // Undo: pending again, all variants open, no choice.
        let undone = try await a.undoReviewDecision(taskID: t.id)
        XCTAssertEqual(undone.state, "pending")
        XCTAssertNil(undone.chosenVariantID)
        XCTAssertTrue(undone.needsChoice)
        XCTAssertEqual(undone.otherVariants.count, 3)

        // "Änderungen anfordern" stays possible without a variant.
        let changes = try await a.decideReview(taskID: t.id, decision: .requestChanges, note: "Bitte größere Beschriftung")
        XCTAssertEqual(changes.state, "changes_requested")
        XCTAssertNil(changes.chosenVariantID)

        // A plain review: no variants, accepting with a variant is rejected, without it works.
        let plain = try await a.createTask(projectID: p.id, title: "Ohne Varianten")
        let plainReview = try await requestReview(a, task: plain.id, summary: "Ganz normales Review", variants: nil)
        XCTAssertTrue(plainReview.variants.isEmpty)
        XCTAssertFalse(plainReview.needsChoice)
        do { _ = try await a.decideReview(taskID: plain.id, decision: .accept, variantID: "a"); XCTFail("422 expected") }
        catch { XCTAssertEqual(ReviewVariantError(error), .unexpectedVariant) }
        let accepted = try await a.decideReview(taskID: plain.id, decision: .accept)
        XCTAssertEqual(accepted.state, "accepted")
        XCTAssertNil(accepted.chosenText)
    }

    /// Reviews for the screenshot tour (project "ShowerNow"); the UI test chooses on some of them.
    func testSeedVariantReviews() async throws {
        guard let out = ProcessInfo.processInfo.environment["TODO_LIVE_SEED_OUT"] else { throw XCTSkip("TODO_LIVE_SEED_OUT not set") }
        let (a, store, _) = try await admin()
        let p = try await a.createProject(name: "ShowerNow")
        let maps = try await a.createTask(projectID: p.id, title: "Kartenwahl ShowerNow")
        _ = try await requestReview(a, task: maps.id, summary: "Drei Entwürfe für die Karte auf der Startseite. Bitte eine Variante wählen.", variants: try await imageVariants(a, task: maps.id))
        let provider = try await a.createTask(projectID: p.id, title: "Wetterdaten-Anbieter")
        _ = try await requestReview(a, task: provider.id, summary: "Zwei Anbieter für die Regenvorhersage im Vergleich.", variants: textVariants)
        let chooseLight = try await a.createTask(projectID: p.id, title: "Anbieter Hell")
        _ = try await requestReview(a, task: chooseLight.id, summary: "Zwei Anbieter, Wahl im Hellmodus.", variants: textVariants)
        let chooseDark = try await a.createTask(projectID: p.id, title: "Anbieter Dunkel")
        _ = try await requestReview(a, task: chooseDark.id, summary: "Zwei Anbieter, Wahl im Dunkelmodus.", variants: textVariants)
        let chooseImage = try await a.createTask(projectID: p.id, title: "Karte Wahl Bild")
        _ = try await requestReview(a, task: chooseImage.id, summary: "Drei Entwürfe, Wahl mit Bild.", variants: try await imageVariants(a, task: chooseImage.id))
        let plain = try await a.createTask(projectID: p.id, title: "Texte freigeben")
        _ = try await requestReview(a, task: plain.id, summary: "Texte sind eingebaut. Ganz normales Review ohne Varianten.", variants: nil)
        let token = try XCTUnwrap(try store.load())
        try JSONSerialization.data(withJSONObject: ["token": token]).write(to: URL(fileURLWithPath: out))
    }
}
