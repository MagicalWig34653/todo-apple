import XCTest
@testable import TodoCore

/// Card B6D004D4: a confirmation decided in "Für dich" stays where it was, so its outcome line stays in view.
final class FeedConfirmationOrderTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    private func item(_ id: UUID) -> FeedConfirmation {
        FeedConfirmation(id: id, tool: "delete_task", summary: "Aufgabe löschen",
                         impact: ActionImpact(targetType: "task", targetID: UUID(), targetName: "Alt", destructive: true),
                         expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }
    private func outcome(_ id: UUID, _ state: ActionRequestState) -> ActionRequest {
        ActionRequest(id: id, tool: "delete_task", state: state, summary: "Aufgabe löschen",
                      impact: ActionImpact(targetType: "task", targetID: UUID(), targetName: "Alt", destructive: true),
                      agentLabel: nil, result: nil, createdAt: nil, decidedAt: nil, executedAt: nil,
                      expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }
    private func page(_ ids: [UUID]) -> FeedPage {
        FeedPage(generatedAt: Date(), mode: "all", projectID: nil, needsYou: [], needsYouTotal: 0,
                 confirmations: ids.map(item), posts: [], nextCursor: nil)
    }

    func testDecidingTheSecondCardKeepsTheOrder() {
        var state = FeedState()
        state.replace(with: page([a, b, c]))

        state.decide(item(b), result: outcome(b, .rejected))
        XCTAssertEqual(state.confirmationCards.map(\.item.id), [a, b, c], "the decided card stays in its place")
        XCTAssertEqual(state.confirmationCards[1].result?.state, .rejected)
        XCTAssertNil(state.confirmationCards[0].result)
        XCTAssertNil(state.confirmationCards[2].result)

        // Refetch of page 1 no longer lists B; it keeps its place all the same.
        state.replace(with: page([a, c]))
        XCTAssertEqual(state.confirmationCards.map(\.item.id), [a, b, c])

        // Deciding the others in any order still keeps the list as it was.
        state.decide(item(c), result: outcome(c, .executed))
        state.decide(item(a), result: outcome(a, .rejected))
        XCTAssertEqual(state.confirmationCards.map(\.item.id), [a, b, c])
        XCTAssertEqual(state.confirmationCards.map(\.result?.state), [.rejected, .rejected, .executed])

        state.replace(with: page([]))
        XCTAssertEqual(state.confirmationCards.map(\.item.id), [a, b, c])
    }

    /// A live refresh may drop the card before the answer to the decision is there.
    func testRefetchBeforeTheAnswerKeepsThePlace() {
        var state = FeedState()
        state.replace(with: page([a, b, c]))
        let above = state.cardsAbove(confirmationID: b)
        state.replace(with: page([a, c]))
        state.decide(item(b), result: outcome(b, .rejected), below: above)
        XCTAssertEqual(state.confirmationCards.map(\.item.id), [a, b, c])
    }

    /// Cards above the decided one come and go (decided elsewhere, new request); it stays between its neighbours.
    func testChangesAboveDoNotMoveTheDecidedCardPastItsNeighbours() {
        var state = FeedState()
        state.replace(with: page([a, b, c]))
        state.decide(item(b), result: outcome(b, .rejected))
        state.replace(with: page([c]))
        XCTAssertEqual(state.confirmationCards.map(\.item.id), [b, c], "the card above is gone")
        let new = UUID()
        state.replace(with: page([new, a, c]))
        XCTAssertEqual(state.confirmationCards.map(\.item.id), [new, a, b, c], "a new request arrived on top")
    }
}
