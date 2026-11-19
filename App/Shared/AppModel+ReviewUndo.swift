import Foundation
import TodoCore

/// Taking back a review decision (server window `ReviewUndo.window`, only the deciding person, only while nothing else happened).
extension AppModel {
    /// Remembers a fresh decision so the undo bar can offer to take it back; without `undoUntil` (older server, agent decision,
    /// window already over) nothing is offered.
    func offerReviewUndo(for review: Review, message: String) {
        guard let until = review.undoUntil, until > Date() else { return }
        reviewUndo = ReviewUndoOffer(taskID: review.taskID, until: until, message: message)
    }

    /// What the bar says after a decision: the choice for a review with variants, else the plain outcome.
    static func decisionMessage(for review: Review, decision: ReviewDecision) -> String {
        if decision == .accept, let text = review.chosenText { return text }
        return decision == .accept ? String(localized: "review.undo.accepted") : String(localized: "review.undo.changes")
    }

    /// Clears the offer once its time is over (only the offer that ran out, not a newer one).
    func expireReviewUndo(_ offer: ReviewUndoOffer) {
        if reviewUndo == offer { reviewUndo = nil }
    }

    /// Takes the decision back; afterwards the review is pending again with all variants open. The lists reload.
    func undoReviewDecision(_ offer: ReviewUndoOffer) async {
        guard let client else { return }
        do {
            _ = try await client.undoReviewDecision(taskID: offer.taskID)
            if reviewUndo == offer { reviewUndo = nil }
            Haptics.success()
        } catch APIError.conflict(let reason) {
            if reviewUndo == offer { reviewUndo = nil }
            noticeKey = switch reason {
            case "undo_window_expired": "review.undo.error.expired"
            case "already_acted_on": "review.undo.error.actedOn"
            default: "review.undo.error.notUndoable"
            }
        } catch {
            await handle(error)
        }
        await reload()
        await refreshCommandSummary()
        reviewUndoGeneration += 1
    }
}
