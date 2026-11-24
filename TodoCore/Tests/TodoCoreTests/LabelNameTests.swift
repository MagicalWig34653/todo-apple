import XCTest

@testable import TodoCore

/// Label names for rename/create in the sync queue (contracts/discovery.yaml `LabelCreate.name`: trimmed, 1...200 characters).
/// The UI for renaming and deleting labels must reject bad names at once instead of showing a server rejection after the sync.
extension SyncEngineTests {
    func testLabelNameNormalizedTrimsAndChecksLength() throws {
        XCTAssertEqual(try LabelName.normalized("  Zuhause \n"), "Zuhause")
        XCTAssertEqual(try LabelName.normalized("Büro Berlin"), "Büro Berlin", "inner spaces stay")
        XCTAssertThrowsError(try LabelName.normalized("")) { XCTAssertEqual($0 as? LabelNameError, .empty) }
        XCTAssertThrowsError(try LabelName.normalized(" \t\n ")) { XCTAssertEqual($0 as? LabelNameError, .empty) }
        XCTAssertEqual(try LabelName.normalized(String(repeating: "a", count: 200)).count, 200)
        XCTAssertThrowsError(try LabelName.normalized(String(repeating: "a", count: 201))) { XCTAssertEqual($0 as? LabelNameError, .tooLong) }
        // The limit counts the way JSON Schema `maxLength` does (Unicode scalars), so an emoji is one character.
        XCTAssertEqual(try LabelName.normalized(String(repeating: "🏠", count: 200)).unicodeScalars.count, 200)
        XCTAssertThrowsError(try LabelName.normalized(String(repeating: "🏠", count: 201))) { XCTAssertEqual($0 as? LabelNameError, .tooLong) }
        // The length is checked after trimming.
        XCTAssertEqual(try LabelName.normalized(" " + String(repeating: "a", count: 200) + " ").count, 200)
    }

    func testRenameLabelSendsTheTrimmedNameOnTheWire() async throws {
        let l1 = UUID()
        serve(feed: baseFeed(extra: [upsertLabel(4, l1, "Haus")]), mutation: { [self] m in ok14(m, label: labelJSON(l1, m["name"] as! String, version: 2)) })
        let e = try engine()
        _ = try await e.sync()
        let snap = try await e.renameLabel(l1, name: "  Zuhause \n")
        XCTAssertEqual(snap.metaOverlay.renamedLabels[l1], "Zuhause")
        _ = try await e.sync()
        XCTAssertEqual(mutationRequests.last?["type"] as? String, "label.rename")
        XCTAssertEqual(mutationRequests.last?["name"] as? String, "Zuhause")
    }

    func testRenameLabelRejectsEmptyAndTooLongNamesBeforeQueueing() async throws {
        let l1 = UUID()
        serve(feed: baseFeed(extra: [upsertLabel(4, l1, "Haus")]))
        let e = try engine()
        _ = try await e.sync()
        do { _ = try await e.renameLabel(l1, name: "   "); XCTFail("empty name must throw") } catch { XCTAssertEqual(error as? LabelNameError, .empty) }
        do { _ = try await e.renameLabel(l1, name: String(repeating: "x", count: 201)); XCTFail("too long must throw") } catch { XCTAssertEqual(error as? LabelNameError, .tooLong) }
        var snap = await e.snapshot()
        XCTAssertEqual(snap.pending, 0, "nothing was queued")
        snap = try await e.renameLabel(l1, name: String(repeating: "x", count: 200))
        XCTAssertEqual(snap.pending, 1, "exactly 200 characters is fine")
    }

    func testRenameLabelToItsCurrentNameQueuesNothing() async throws {
        let l1 = UUID()
        serve(feed: baseFeed(extra: [upsertLabel(4, l1, "Haus")]))
        let e = try engine()
        _ = try await e.sync()
        var snap = try await e.renameLabel(l1, name: " Haus ")
        XCTAssertEqual(snap.pending, 0)
        // Only the case differs: that is a real rename.
        snap = try await e.renameLabel(l1, name: "haus")
        XCTAssertEqual(snap.pending, 1)
        // Back to the confirmed name: the queued rename nets out (no request would be sent).
        snap = try await e.renameLabel(l1, name: "Haus")
        XCTAssertEqual(snap.pending, 0)
        XCTAssertTrue(mutationRequests.isEmpty)
    }

    func testQueuedRenameAndDeleteOfConfirmedLabelShowInTheOptimisticOverlay() async throws {
        let l1 = UUID(), l2 = UUID()
        serve(feed: baseFeed(extra: [upsertLabel(4, l1, "Haus"), upsertLabel(5, l2, "Büro")]))
        let e = try engine()
        _ = try await e.sync()
        try await e.renameLabel(l1, name: "Zuhause")
        try await e.renameLabel(l1, name: "Daheim")
        var snap = await e.snapshot()
        XCTAssertEqual(snap.metaOverlay.renamedLabels, [l1: "Daheim"], "the last queued name wins")
        XCTAssertEqual(snap.labels.first { $0.id == l1 }?.name, "Haus", "the confirmed name does not change before the server answers")
        snap = try await e.deleteLabel(l1)
        XCTAssertTrue(snap.metaOverlay.renamedLabels.isEmpty, "a delete swallows the queued rename")
        XCTAssertEqual(snap.metaOverlay.deletedLabels, [l1])
        XCTAssertEqual(snap.pending, 1)
        snap = try await e.renameLabel(l2, name: "Arbeit")
        XCTAssertEqual(snap.metaOverlay.renamedLabels, [l2: "Arbeit"])
        XCTAssertEqual(snap.metaOverlay.deletedLabels, [l1])
    }

    func testCreateLabelValidatesAndTrimsLikeRename() async throws {
        let e = try engine()
        serve(feed: baseFeed())
        _ = try await e.sync()
        do { _ = try await e.createLabel(name: "  "); XCTFail("empty name must throw") } catch { XCTAssertEqual(error as? LabelNameError, .empty) }
        var snap = await e.snapshot()
        XCTAssertEqual(snap.pending, 0)
        snap = try await e.createLabel(name: " Neu ")
        XCTAssertEqual(snap.metaOverlay.newLabels.map(\.name), ["Neu"])
    }
}
