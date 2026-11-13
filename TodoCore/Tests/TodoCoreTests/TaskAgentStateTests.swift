import XCTest
@testable import TodoCore

final class TaskAgentStateTests: XCTestCase {
    func testLaneWinsForAttentionStates() {
        XCTAssertEqual(TaskAgentState(lane: "question", status: "in_progress"), .question)
        XCTAssertEqual(TaskAgentState(lane: "review", status: "in_review"), .review)
        XCTAssertEqual(TaskAgentState(lane: "running", status: "open"), .running)
    }

    func testCalmLanesShowNothing() {
        XCTAssertNil(TaskAgentState(lane: "ready", status: "open"))
        XCTAssertNil(TaskAgentState(lane: "blocked", status: "open"))
        XCTAssertNil(TaskAgentState(lane: "backlog", status: "open"))
        XCTAssertNil(TaskAgentState(lane: "done", status: "done"))
    }

    func testDoneTaskNeverShowsAState() {
        // A task completed locally while the overview still has the old lane.
        XCTAssertNil(TaskAgentState(lane: "question", status: "done"))
        XCTAssertNil(TaskAgentState(lane: "running", status: "done"))
    }

    func testFallsBackToStatusWithoutLane() {
        XCTAssertEqual(TaskAgentState(lane: nil, status: "in_review"), .review)
        XCTAssertEqual(TaskAgentState(lane: nil, status: "in_progress"), .running)
        XCTAssertNil(TaskAgentState(lane: nil, status: "open"))
        XCTAssertNil(TaskAgentState(lane: nil, status: "done"))
    }

    func testUnknownLaneFallsBackToStatus() {
        XCTAssertEqual(TaskAgentState(lane: "future_lane", status: "in_progress"), .running)
        XCTAssertNil(TaskAgentState(lane: "future_lane", status: "open"))
    }

    func testLaneKeyMatchesCommandLane() {
        for state in TaskAgentState.allCases { XCTAssertNotNil(CommandLane(rawValue: state.rawValue)) }
    }
}
