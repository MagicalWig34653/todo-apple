import XCTest
@testable import TodoCore

/// Review with variants (card 1D9C8B0C, contract command-center 1.8.0): tolerant decoding, choice helpers, decision request,
/// error mapping, undo window.
final class ReviewVariantsTests: XCTestCase {
    let store = InMemoryTokenStore()
    var client: APIClient!
    let pid = UUID(), tid = UUID(), rid = UUID(), att = UUID()

    override func setUp() {
        MockURLProtocol.seen = []
        MockURLProtocol.handler = nil
        try? store.save("tok")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: URL(string: "http://test.invalid")!, session: URLSession(configuration: config), tokenStore: store)
    }

    private func reply(_ s: String) { reply(200, s) }
    private func reply(_ status: Int, _ s: String) { MockURLProtocol.handler = { _ in (status, Data(s.utf8)) } }
    private var last: URLRequest { MockURLProtocol.seen.last! }
    private func body(_ r: URLRequest) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:] }

    private func reviewJSON(state: String = "pending", extra: String = "") -> String {
        #"{"id":"\#(rid)","taskID":"\#(tid)","taskTitle":"T","projectID":"\#(pid)","projectName":"P","state":"\#(state)","requestedByType":"Integration","requestedByID":"\#(UUID())","requestedByLabel":"Claude","reviewerID":null,"summary":"Kartenwahl","decidedBy":null,"decidedAt":null,"decisionNote":null,"agentJobID":null,"createdAt":"2026-11-18T10:00:00Z","version":1\#(extra)}"#
    }
    private var twoVariants: String {
        #","variants":[{"id":"a","label":"Windkarte","description":"Wind als Pfeile","attachmentID":"\#(att.uuidString.lowercased())"},{"id":"b","label":"Radarkarte"}]"#
    }
    private func decode(_ json: String) throws -> Review { try APIClient.decoder.decode(Review.self, from: Data(json.utf8)) }

    // MARK: Decoding

    func testReviewWithoutVariantsIsPlain() throws {
        let r = try decode(reviewJSON())
        XCTAssertTrue(r.variants.isEmpty)
        XCTAssertNil(r.chosenVariantID)
        XCTAssertNil(r.undoUntil)
        XCTAssertFalse(r.needsChoice)
        XCTAssertNil(r.chosenText)
    }

    func testReviewWithVariantsDecodes() throws {
        let r = try decode(reviewJSON(extra: twoVariants))
        XCTAssertEqual(r.variants.map(\.id), ["a", "b"])
        XCTAssertEqual(r.variants[0].label, "Windkarte")
        XCTAssertEqual(r.variants[0].description, "Wind als Pfeile")
        XCTAssertEqual(r.variants[0].attachmentID, att)
        XCTAssertNil(r.variants[1].description)
        XCTAssertNil(r.variants[1].attachmentID, "no attachment, no picture slot")
        XCTAssertTrue(r.needsChoice)
    }

    func testMalformedVariantsAreDroppedAndFewerThanTwoMeanNoChoice() throws {
        let mixed = #","variants":[{"id":"a","label":"A"},{"id":"","label":"leer"},{"label":"ohne id"},{"id":"c"},"quatsch",{"id":"d","label":"D","attachmentID":"kein-uuid"}]"#
        let r = try decode(reviewJSON(extra: mixed))
        XCTAssertEqual(r.variants.map(\.id), ["a", "d"])
        XCTAssertNil(r.variants[1].attachmentID, "invalid attachment id is ignored, not fatal")

        let single = try decode(reviewJSON(extra: #","variants":[{"id":"a","label":"A"},{"id":"b"}]"#))
        XCTAssertTrue(single.variants.isEmpty, "a single valid variant is not a choice")
        XCTAssertFalse(single.needsChoice)

        XCTAssertTrue(try decode(reviewJSON(extra: #","variants":"kaputt""#)).variants.isEmpty)
        XCTAssertTrue(try decode(reviewJSON(extra: #","variants":null"#)).variants.isEmpty)
    }

    func testUnknownFieldsAndMoreThanFourStayReadable() throws {
        let five = (1...5).map { #"{"id":"v\#($0)","label":"L\#($0)","neu":1}"# }.joined(separator: ",")
        let r = try decode(reviewJSON(extra: #","variants":[\#(five)],"zukunft":{"a":1}"#))
        XCTAssertEqual(r.variants.count, 5, "the client does not enforce the server's limit of 4")
    }

    func testAcceptedReviewKeepsChosenVariantAndUndoUntil() throws {
        let r = try decode(reviewJSON(state: "accepted", extra: twoVariants + #","chosenVariantID":"b","undoUntil":"2026-11-18T10:05:00.5Z""#))
        XCTAssertEqual(r.chosenVariantID, "b")
        XCTAssertNotNil(r.undoUntil)
        XCTAssertFalse(r.needsChoice, "decided: no choice any more")
    }

    func testReviewBriefOnCardCarriesVariants() throws {
        let json = #"{"id":"\#(rid)","summary":"S","requestedByType":"Integration","requestedByLabel":"Claude","reviewerID":null,"agentJobID":null,"createdAt":"2026-11-18T10:00:00Z"\#(twoVariants)}"#
        let brief = try APIClient.decoder.decode(ReviewBrief.self, from: Data(json.utf8))
        XCTAssertEqual(brief.variants.map(\.label), ["Windkarte", "Radarkarte"])
        XCTAssertTrue(brief.needsChoice)
        let old = try APIClient.decoder.decode(ReviewBrief.self, from: Data(#"{"id":"\#(rid)","summary":"S","requestedByType":"Person"}"#.utf8))
        XCTAssertTrue(old.variants.isEmpty)
        XCTAssertFalse(old.needsChoice)
    }

    // MARK: Helpers

    func testChosenTextMatchesServerWording() throws {
        let r = try decode(reviewJSON(state: "accepted", extra: twoVariants + #","chosenVariantID":"b""#))
        XCTAssertEqual(r.chosenVariant?.label, "Radarkarte")
        XCTAssertEqual(r.chosenText, "Variante B gewählt: Radarkarte")
        XCTAssertEqual(r.otherVariants.map(\.id), ["a"])
    }

    func testSlugIdsAreShownAsWrittenAndUnknownChoiceIsNil() throws {
        let slugs = #","variants":[{"id":"karte-wind","label":"Wind"},{"id":"karte-radar","label":"Radar"}]"#
        let r = try decode(reviewJSON(state: "accepted", extra: slugs + #","chosenVariantID":"karte-radar""#))
        XCTAssertEqual(r.chosenText, "Variante karte-radar gewählt: Radar")
        let unknown = try decode(reviewJSON(state: "accepted", extra: slugs + #","chosenVariantID":"zzz""#))
        XCTAssertNil(unknown.chosenVariant)
        XCTAssertNil(unknown.chosenText)
        XCTAssertEqual(unknown.otherVariants.count, 2)
    }

    func testPendingWithChoiceNeedsChoiceOnlyWhilePending() throws {
        XCTAssertTrue(try decode(reviewJSON(extra: twoVariants)).needsChoice)
        XCTAssertFalse(try decode(reviewJSON(state: "changes_requested", extra: twoVariants)).needsChoice)
        XCTAssertFalse(try decode(reviewJSON(state: "withdrawn", extra: twoVariants)).needsChoice)
    }

    /// Shape of a real `GET /v1/tasks/{id}/context` answer of the 1.8.0 server (no `taskTitle`, no `claimedLabel`, ids upper case).
    func testTaskContextWithVariantsDecodes() async throws {
        let task = #"{"boardPosition":0,"projectID":"\#(pid)","title":"Wetterdaten-Anbieter","version":2,"id":"\#(tid)","description":"","status":"in_review"}"#
        let review = #"{"requestedByID":"\#(UUID())","createdAt":"2026-11-19T15:13:18Z","requestedByLabel":"Claude","id":"\#(rid)","taskID":"\#(tid)","requestedByType":"Person","version":1,"state":"pending","summary":"Zwei Anbieter","variants":[{"id":"a","label":"Open-Meteo","description":"Kostenlos"},{"id":"b","label":"Wetterdienst A"}]}"#
        reply(#"{"builds":[],"task":\#(task),"projectID":"\#(pid)","workflow":{"taskID":"\#(tid)","kind":"task","isFeature":false,"orphaned":false},"progressNotes":[],"criteria":[],"progress":{"percent":0,"subtasksTotal":0,"subtasksDone":0,"criteriaDone":0,"source":"none","criteriaTotal":0},"subtasks":[],"questions":[],"review":\#(review),"comments":[]}"#)
        let context = try await client.taskContext(tid)
        XCTAssertEqual(context.review?.variants.map(\.id), ["a", "b"])
        XCTAssertTrue(context.review?.needsChoice ?? false)
    }

    func testChoiceReviewIDsPicksOnlyPendingChoices() throws {
        let withChoice = try decode(reviewJSON(extra: twoVariants))
        let plain = try decode(reviewJSON().replacingOccurrences(of: rid.uuidString, with: UUID().uuidString))
        let decided = try decode(reviewJSON(state: "accepted", extra: twoVariants).replacingOccurrences(of: rid.uuidString, with: UUID().uuidString))
        XCTAssertEqual([withChoice, plain, decided].choiceReviewIDs, [withChoice.id])
        XCTAssertTrue([Review]().choiceReviewIDs.isEmpty)
    }

    func testPreviewStateHasNoSlotWithoutAttachment() {
        let with = ReviewVariant(id: "a", label: "A", description: nil, attachmentID: UUID())
        let without = ReviewVariant(id: "b", label: "B", description: nil, attachmentID: nil)
        XCTAssertEqual(with.previewState(loadFailed: false), .image)
        XCTAssertEqual(with.previewState(loadFailed: true), .fallback)
        XCTAssertEqual(without.previewState(loadFailed: false), .none)
        XCTAssertEqual(without.previewState(loadFailed: true), .none)
    }

    func testKeyboardNavigationStopsAtTheEnds() {
        typealias N = VariantNavigation
        XCTAssertEqual(N.next.index(from: 0, count: 3), 1)
        XCTAssertEqual(N.next.index(from: 2, count: 3), 2, "no wrapping")
        XCTAssertEqual(N.previous.index(from: 0, count: 3), 0)
        XCTAssertEqual(N.previous.index(from: 2, count: 3), 1)
        XCTAssertEqual(N.first.index(from: 2, count: 3), 0)
        XCTAssertEqual(N.last.index(from: 0, count: 3), 2)
        XCTAssertEqual(N.next.index(from: 9, count: 3), 2, "out-of-range start is clamped")
        XCTAssertNil(N.next.index(from: 0, count: 0))
    }

    // MARK: Request and errors

    func testDecideAcceptSendsVariantID() async throws {
        reply(reviewJSON(state: "accepted", extra: twoVariants + #","chosenVariantID":"b","undoUntil":"2026-11-18T10:05:00Z""#))
        let r = try await client.decideReview(taskID: tid, decision: .accept, variantID: "b")
        XCTAssertEqual(last.url?.path, "/v1/tasks/\(tid.uuidString.lowercased())/review/decision")
        XCTAssertEqual(body(last)["decision"] as? String, "accept")
        XCTAssertEqual(body(last)["variantID"] as? String, "b")
        XCTAssertNil(body(last)["note"])
        XCTAssertEqual(r.chosenVariantID, "b")
    }

    func testDecideWithoutVariantOmitsTheField() async throws {
        reply(reviewJSON(state: "changes_requested"))
        _ = try await client.decideReview(taskID: tid, decision: .requestChanges, note: "Bitte nochmal")
        XCTAssertNil(body(last)["variantID"])
        XCTAssertEqual(body(last)["note"] as? String, "Bitte nochmal")
        reply(reviewJSON(state: "accepted"))
        _ = try await client.decideReview(taskID: tid, decision: .accept, variantID: "  ")
        XCTAssertNil(body(last)["variantID"], "blank variant id is not sent")
    }

    func testVariantErrorsAreMapped() async {
        for (code, expected) in [("variant_required", ReviewVariantError.variantRequired), ("unknown_variant", .unknownVariant), ("unexpected_variant", .unexpectedVariant)] {
            reply(422, #"{"error":true,"reason":"\#(code)"}"#)
            do { _ = try await client.decideReview(taskID: tid, decision: .accept); XCTFail("422 expected") } catch {
                XCTAssertEqual(error as? APIError, .invalidInput(reason: code))
                XCTAssertEqual(ReviewVariantError(error), expected)
            }
        }
        XCTAssertNil(ReviewVariantError(APIError.invalidInput(reason: "invalid_note")))
        XCTAssertNil(ReviewVariantError(APIError.conflict(reason: "variant_required")))
        XCTAssertNil(ReviewVariantError(APIError.transport("x")))
    }

    func testUndoRequestAndConflicts() async throws {
        reply(reviewJSON(extra: twoVariants))
        let r = try await client.undoReviewDecision(taskID: tid)
        XCTAssertEqual(last.httpMethod, "POST")
        XCTAssertEqual(last.url?.path, "/v1/tasks/\(tid.uuidString.lowercased())/review/undo")
        XCTAssertTrue(r.needsChoice, "after undo all variants are open again")
        XCTAssertNil(r.chosenVariantID)
        for code in ["nothing_to_undo", "not_undoable", "undo_window_expired", "already_acted_on"] {
            reply(409, #"{"error":true,"reason":"\#(code)"}"#)
            do { _ = try await client.undoReviewDecision(taskID: tid); XCTFail() } catch {
                XCTAssertEqual(error as? APIError, .conflict(reason: code))
            }
        }
    }

    // MARK: Undo window

    func testUndoRemainingAndFormat() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(ReviewUndo.remaining(until: now.addingTimeInterval(272), now: now), 272)
        XCTAssertEqual(ReviewUndo.remaining(until: now.addingTimeInterval(-1), now: now), 0)
        XCTAssertEqual(ReviewUndo.remaining(until: nil, now: now), 0)
        XCTAssertEqual(ReviewUndo.format(272), "4:32")
        XCTAssertEqual(ReviewUndo.format(300), "5:00")
        XCTAssertEqual(ReviewUndo.format(0.2), "0:01", "rounds up like the PWA")
        XCTAssertEqual(ReviewUndo.format(-5), "0:00")
    }

    func testUndoWindowIsFiveMinutes() {
        XCTAssertEqual(ReviewUndo.windowMinutes, 5)
        XCTAssertEqual(ReviewUndo.window, 300)
    }

    /// Guards the single constant against the server value without copying it: reads `WorkflowLimits.reviewUndoWindow` from the
    /// main repository when it can be found (`TODO_MAIN_REPO`, the sibling checkout or `.workspace.local.json`), else skips.
    func testUndoWindowMatchesBackendWorkflowLimits() throws {
        let relative = "Sources/TodoKit/CommandCenter/WorkflowService.swift"
        var roots: [URL] = []
        if let env = ProcessInfo.processInfo.environment["TODO_MAIN_REPO"] { roots.append(URL(fileURLWithPath: env)) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Sibling layout: <dev>/Xcode/<apple checkout> next to <dev>/PhpstormProjects/todo.
        roots.append(repo.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PhpstormProjects/todo"))
        if let data = try? Data(contentsOf: repo.appendingPathComponent(".workspace.local.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String], let main = json["mainRepo"] { roots.append(URL(fileURLWithPath: main)) }
        guard let file = roots.map({ $0.appendingPathComponent(relative) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let source = try? String(contentsOf: file, encoding: .utf8) else {
            throw XCTSkip("main repository not found (set TODO_MAIN_REPO)")
        }
        let line = try XCTUnwrap(source.components(separatedBy: "\n").first { $0.contains("reviewUndoWindow") && $0.contains("TimeInterval") }, "reviewUndoWindow not found in \(file.path)")
        let expression = try XCTUnwrap(line.components(separatedBy: "=").last).trimmingCharacters(in: .whitespaces)
        let factors = expression.components(separatedBy: "*").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertFalse(factors.isEmpty, "unexpected form: \(line)")
        XCTAssertEqual(factors.reduce(1, *), ReviewUndo.window, "server undo window differs from ReviewUndo.window")
    }
}
