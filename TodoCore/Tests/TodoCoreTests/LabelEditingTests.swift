import XCTest

@testable import TodoCore

/// What the label management screen needs from the core (card 9E4572D1): the rename check that decides between "error
/// text", "nothing to do" and "send", and the unsent rename/delete laid over the confirmed label list.
final class LabelEditingTests: XCTestCase {
    private let home = TaskLabel(id: UUID(), name: "Haus", version: 3)
    private let work = TaskLabel(id: UUID(), name: "Büro", version: 1)

    func testRenameCheckAcceptsAndTrimsAValidName() {
        XCTAssertEqual(LabelEditing.checkRename("  Zuhause \n", of: home), .valid("Zuhause"))
        XCTAssertEqual(LabelEditing.checkRename("haus", of: home), .valid("haus"), "only the case differs: a real rename")
    }

    func testRenameCheckReportsInvalidNames() {
        XCTAssertEqual(LabelEditing.checkRename("", of: home), .invalid(.empty))
        XCTAssertEqual(LabelEditing.checkRename(" \t ", of: home), .invalid(.empty))
        XCTAssertEqual(LabelEditing.checkRename(String(repeating: "x", count: 201), of: home), .invalid(.tooLong))
        XCTAssertEqual(LabelEditing.checkRename(String(repeating: "x", count: 200), of: home), .valid(String(repeating: "x", count: 200)))
    }

    func testRenameCheckKnowsTheUnchangedName() {
        XCTAssertEqual(LabelEditing.checkRename("Haus", of: home), .unchanged)
        XCTAssertEqual(LabelEditing.checkRename("  Haus  ", of: home), .unchanged)
    }

    func testOverlayShowsQueuedRenameAndHidesQueuedDelete() {
        var overlay = OutboxSnapshot()
        overlay.renamedLabels[home.id] = "Zuhause"
        overlay.deletedLabels.insert(work.id)
        let shown = LabelEditing.applying(overlay, to: [home, work])
        XCTAssertEqual(shown.map(\.name), ["Zuhause"])
        XCTAssertEqual(shown.first?.id, home.id)
        XCTAssertEqual(shown.first?.version, home.version, "the confirmed version stays, the sync layer owns it")
    }

    func testOverlayWithoutEditsKeepsTheListAndTheOrder() {
        XCTAssertEqual(LabelEditing.applying(OutboxSnapshot(), to: [work, home]), [work, home])
    }

    func testEngineOverlayCarriesRenameAndDeleteIntoTheAppSnapshot() {
        var meta = OutboxSnapshot()
        meta.renamedLabels[home.id] = "Zuhause"
        meta.deletedLabels.insert(work.id)
        var legacy = OutboxSnapshot()
        legacy.renamedLabels[home.id] = "alt"
        legacy.deletedLabels.insert(UUID())
        let merged = LabelEditing.merged(legacy: legacy, engine: meta)
        XCTAssertEqual(merged.renamedLabels[home.id], "Zuhause", "the engine's newer rename wins")
        XCTAssertTrue(merged.deletedLabels.contains(work.id))
        XCTAssertEqual(merged.deletedLabels.count, 2, "deletes of both queues add up")
    }
}
