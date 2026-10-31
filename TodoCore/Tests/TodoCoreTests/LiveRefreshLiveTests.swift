import Foundation
import XCTest

@testable import TodoCore

/// Opt-in (TODO_LIVE_BASE_URL, fresh backend): a change made by a second client reaches the LiveRefresh loop in < 6 s.
extension LiveEtappe2Tests {
    func testLiveRefreshDeliversChangeOfSecondClientQuickly() async throws {
        let f = try await fixture()
        let caps = try await f.admin.capabilities()
        let cap = try XCTUnwrap(caps.liveRefresh, "backend without liveRefresh")
        XCTAssertTrue(cap.head && cap.wait)
        let syncs = LiveRefreshTests.Counter()
        let live = LiveRefresh(transport: f.admin, syncAction: { syncs.bump() })
        let stream = await live.events()
        await live.start(); await live.setForeground(true)

        // Second client: same account (own session through the same token store is fine for the hint stream).
        let project = try await f.admin.createProject(name: "Live \(f.suffix)")
        let task = try await f.admin.createTask(projectID: project.id, title: "Live")
        try await Task.sleep(nanoseconds: 1_500_000_000)  // loop is waiting with the latest token

        let stream2 = await live.events()  // earlier hints (own setup writes) are not counted
        let started = Date()
        let arrival = Task { () -> TimeInterval? in
            for await e in stream2 where e == .changed { return Date().timeIntervalSince(started) }
            return nil
        }
        let timeout = Task { try await Task.sleep(nanoseconds: 6_000_000_000); arrival.cancel() }
        _ = try await f.bob.me()
        // Bob cannot see admin's task; the admin's second client is a fresh APIClient with the same token.
        let second = APIClient(baseURL: f.admin.baseURL, tokenStore: f.adminStore)
        _ = try await second.addComment(taskID: task.id, body: "von Client zwei")
        let seconds = await arrival.value
        timeout.cancel()
        let s = try XCTUnwrap(seconds, "no change within 6 s")
        print("LIVE-REFRESH latency: \(s) s")
        XCTAssertLessThan(s, 6)
        XCTAssertGreaterThanOrEqual(syncs.value, 1)
        await live.stop()
    }
}
