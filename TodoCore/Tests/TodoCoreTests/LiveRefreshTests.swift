import XCTest
@testable import TodoCore

/// Virtual clock: `sleep` returns almost at once and advances time, so backoff and polling run instantly but are recorded.
final class VirtualClock: LiveRefreshClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time = 1000.0
    private var slept: [Double] = []
    func now() -> Double { lock.withLock { time } }
    func sleep(seconds: Double) async throws {
        try Task.checkCancellation()
        lock.withLock { time += seconds; slept.append(seconds) }
        try await Task.sleep(nanoseconds: 1_000_000)  // yield so tests can observe and cancel
    }
    var sleeps: [Double] { lock.withLock { slept } }
}

/// Scripted transport: calls consume the scripts in order; an empty wait script parks the call (like a long poll).
final class FakeLiveTransport: LiveRefreshTransport, @unchecked Sendable {
    enum Step<T: Sendable>: @unchecked Sendable { case ok(T), fail(any Error) }
    private let lock = NSLock()
    var capability: Step<LiveRefreshCapability?> = .ok(LiveRefreshCapability())
    private var heads: [Step<LiveHead?>] = []
    private var waits: [Step<LiveWait>] = []
    private var calls: [String] = []
    private var sinces: [String?] = []
    private var repeatHead: LiveHead?

    func script(heads: [Step<LiveHead?>] = [], waits: [Step<LiveWait>] = [], repeatHead: LiveHead? = nil) {
        lock.withLock { self.heads += heads; self.waits += waits; self.repeatHead = repeatHead }
    }
    func count(_ name: String) -> Int { lock.withLock { calls.filter { $0 == name }.count } }
    var total: Int { lock.withLock { calls.count } }
    var waitSince: [String?] { lock.withLock { sinces } }

    func liveCapability() async throws -> LiveRefreshCapability? {
        lock.withLock { calls.append("cap") }
        switch capability { case .ok(let c): return c; case .fail(let e): throw e }
    }
    func liveHead(ifNoneMatch: String?) async throws -> LiveHead? {
        let next: Step<LiveHead?>? = lock.withLock {
            calls.append("head")
            return heads.isEmpty ? repeatHead.map { .ok($0) } : heads.removeFirst()
        }
        guard let next else { try await park(); throw CancellationError() }
        switch next { case .ok(let h): return h; case .fail(let e): throw e }
    }
    func liveWait(since: String?, timeout: Int) async throws -> LiveWait {
        let next: Step<LiveWait>? = lock.withLock {
            calls.append("wait"); sinces.append(since)
            return waits.isEmpty ? nil : waits.removeFirst()
        }
        guard let next else { try await park(); throw CancellationError() }
        switch next { case .ok(let w): return w; case .fail(let e): throw e }
    }
    private func park() async throws { try await Task.sleep(nanoseconds: 60_000_000_000) }
}

private func head(_ t: String) -> FakeLiveTransport.Step<LiveHead?> { .ok(LiveHead(cursor: "c1", token: t)) }
private func waitStep(_ t: String, _ changed: Bool, retryAfter: Double? = nil) -> FakeLiveTransport.Step<LiveWait> {
    .ok(LiveWait(token: t, changed: changed, cursor: "c1", retryAfter: retryAfter))
}

final class LiveRefreshTests: XCTestCase {
    let clock = VirtualClock()
    let fake = FakeLiveTransport()
    let syncCount = Counter()

    final class Counter: @unchecked Sendable {
        private let l = NSLock(); private var n = 0
        func bump() { l.withLock { n += 1 } }
        var value: Int { l.withLock { n } }
    }

    private func make(lowPower: Bool = false, gap: Double = 1) -> LiveRefresh {
        let c = syncCount
        return LiveRefresh(transport: fake, clock: clock, minNotifyGap: gap, lowPower: { lowPower }, jitter: { 1 },
                           syncAction: { c.bump() })
    }

    private func until(_ what: String = "", timeout: Double = 3, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(cond(), "timeout: \(what)")
    }

    /// Reads events until `count` changes arrived (with a safety timeout through the sleeping test clock).
    private func awaitChanges(_ stream: AsyncStream<LiveEvent>, _ count: Int) async {
        var n = 0
        for await e in stream { if e == .changed { n += 1 }; if n == count { break } }
    }

    func testLoopSyncsAndNotifiesOnChangeAndWaitsAgainOnTimeout() async {
        fake.script(heads: [head("t0")], waits: [waitStep("t0", false), waitStep("t1", true), waitStep("t1", false), waitStep("t2", true)])
        let live = make()
        let stream = await live.events()
        await live.start(); await live.setForeground(true)
        await awaitChanges(stream, 2)
        XCTAssertEqual(syncCount.value, 2)
        XCTAssertEqual(fake.waitSince.prefix(4).map { $0 ?? "-" }, ["t0", "t0", "t1", "t1"])  // always the latest token
        let mode = await live.mode
        XCTAssertEqual(mode, .longPoll)
        await live.stop()
    }

    func testFirstStartOnlyRemembersTokenWithoutNotifying() async {
        fake.script(heads: [head("t0")])
        let live = make()
        await live.start(); await live.setForeground(true)
        await until("wait started") { self.fake.count("wait") >= 1 }
        XCTAssertEqual(syncCount.value, 0)
        await live.stop()
    }

    func testBundlingMaxOnePerSecond() async {
        fake.script(heads: [head("t0")], waits: [waitStep("t1", true), waitStep("t2", true), waitStep("t3", true)])
        let live = make()
        let stream = await live.events()
        await live.start(); await live.setForeground(true)
        await awaitChanges(stream, 3)
        // The virtual clock only advances through sleeps, so each later notification waits (nearly) the full gap.
        XCTAssertEqual(clock.sleeps.filter { $0 > 0.5 && $0 <= 1 }.count, 2)
        await live.stop()
    }

    func testBackoffGrowsAndProbesHeadInFiveSecondChunks() async {
        let boom = FakeLiveTransport.Step<LiveWait>.fail(APIError.transport("down"))
        fake.script(heads: [head("t0")], waits: [boom, boom, boom, boom, boom, boom, waitStep("t0", false)], repeatHead: LiveHead(cursor: "c", token: "t0"))
        // head probes inside long backoffs would succeed and cut them short; make them fail instead.
        let live = make()
        await live.start(); await live.setForeground(true)
        await until("recovered") { self.fake.count("wait") >= 4 }
        let s = clock.sleeps
        XCTAssertEqual(Array(s.prefix(3)), [1, 2, 4])
        XCTAssertLessThanOrEqual(s.max() ?? 99, 5)
        await live.stop()
    }

    func testRecoveryNotifiesWhenTokenMovedWhileOffline() async {
        fake.script(heads: [head("t0"), head("t9")], waits: [.fail(APIError.server(status: 503, reason: nil))])
        let live = make()
        let stream = await live.events()
        await live.start(); await live.setForeground(true)
        await awaitChanges(stream, 1)
        XCTAssertEqual(syncCount.value, 1)
        await live.stop()
    }

    func testUnauthorizedReportsSignedOutAndStopsLoop() async {
        fake.script(heads: [head("t0")], waits: [.fail(APIError.unauthorized(reason: nil))])
        let live = make()
        let stream = await live.events()
        await live.start(); await live.setForeground(true)
        for await e in stream { if e == .signedOut { break } }
        let running = await live.isRunning
        XCTAssertFalse(running)
        let before = fake.count("wait")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fake.count("wait"), before, "no loop after 401")
    }

    func testRateLimitedWaitsRetryAfterWithoutBackoff() async {
        fake.script(heads: [head("t0")], waits: [.fail(LiveRefreshError.rateLimited(retryAfter: 7)), waitStep("t0", false)])
        let live = make()
        await live.start(); await live.setForeground(true)
        await until("second wait") { self.fake.count("wait") >= 2 }
        XCTAssertEqual(clock.sleeps.first, 7)
        await live.stop()
    }

    func testRetryAfterFromShutdownDelaysReconnect() async {
        fake.script(heads: [head("t0")], waits: [waitStep("t0", false, retryAfter: 3), waitStep("t0", false)])
        let live = make()
        await live.start(); await live.setForeground(true)
        await until("reconnect") { self.fake.count("wait") >= 2 }
        XCTAssertEqual(clock.sleeps.first, 3)
        await live.stop()
    }

    func testWait404FallsBackToHeadPollingEvery5Seconds() async {
        fake.script(heads: [head("t0"), head("t0"), head("t1")], waits: [.fail(APIError.notFound)])
        let live = make()
        let stream = await live.events()
        await live.start(); await live.setForeground(true)
        await awaitChanges(stream, 1)
        XCTAssertEqual(syncCount.value, 1)
        XCTAssertTrue(clock.sleeps.contains(5))
        let mode = await live.mode
        XCTAssertEqual(mode, .polling)
        await live.stop()
    }

    func testMissingCapabilityAndHead404FallsBackToSyncPolling() async {
        fake.capability = .ok(nil)
        fake.script(heads: [.fail(APIError.notFound)])
        let live = make()
        let stream = await live.events()
        await live.start(); await live.setForeground(true)
        await awaitChanges(stream, 2)
        XCTAssertGreaterThanOrEqual(syncCount.value, 2)
        let mode = await live.mode
        XCTAssertEqual(mode, .syncPolling)
        XCTAssertEqual(fake.count("wait"), 0)
        await live.stop()
    }

    func testLowPowerModeDoublesPollingInterval() async {
        fake.capability = .ok(LiveRefreshCapability(wait: false))
        fake.script(heads: [head("t0")], repeatHead: LiveHead(cursor: "c", token: "t0"))
        let live = make(lowPower: true)
        await live.start(); await live.setForeground(true)
        await until("polled") { self.clock.sleeps.contains(10) }
        await live.stop()
    }

    func testForegroundLifecycleOneLoopAndHeadCheckOnReturn() async {
        fake.script(heads: [head("t0"), head("t5")], waits: [waitStep("t0", false)])
        let live = make()
        let stream = await live.events()
        await live.start(); await live.start()
        await live.setForeground(true); await live.setForeground(true)
        await until("waiting") { self.fake.count("wait") >= 2 }
        XCTAssertEqual(fake.count("cap"), 1, "one loop only")
        await live.setForeground(false)
        let running = await live.isRunning
        XCTAssertFalse(running)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let calls = fake.total
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fake.total, calls, "nothing in the background")
        await live.setForeground(true)  // returns: head first, token moved -> changed
        await awaitChanges(stream, 1)
        XCTAssertEqual(syncCount.value, 1)
        await live.stop()
    }

    func testStopEndsLoop() async {
        fake.script(heads: [head("t0")])
        let live = make()
        await live.start(); await live.setForeground(true)
        await until("waiting") { self.fake.count("wait") >= 1 }
        await live.stop()
        let running = await live.isRunning
        XCTAssertFalse(running)
    }
}

final class LiveRefreshClientTests: XCTestCase {
    var client: APIClient!
    override func setUp() {
        MockURLProtocol.seen = []; MockURLProtocol.handler = nil
        let store = InMemoryTokenStore(); try? store.save("tok")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: URL(string: "http://test.invalid")!, session: URLSession(configuration: config), tokenStore: store)
    }

    func testCapabilityBlockDecodesAndIsOptional() async throws {
        MockURLProtocol.handler = { _ in (200, Data(#"{"passkey":true,"password":false,"bootstrapOpen":false,"liveRefresh":{"head":true,"wait":true,"stream":false,"pollSeconds":5,"waitMaxSeconds":25}}"#.utf8)) }
        let c = try await client.liveCapability()
        XCTAssertEqual(c, LiveRefreshCapability())
        MockURLProtocol.handler = { _ in (200, Data(#"{"passkey":true,"password":false,"bootstrapOpen":false}"#.utf8)) }
        let none = try await client.liveCapability()
        XCTAssertNil(none)
    }

    func testHeadRequestEtagAnd304() async throws {
        MockURLProtocol.handler = { _ in (200, Data(#"{"cursor":"c4","token":"l1.2.3"}"#.utf8)) }
        let h = try await client.liveHead(ifNoneMatch: nil)
        XCTAssertEqual(h, LiveHead(cursor: "c4", token: "l1.2.3"))
        XCTAssertEqual(MockURLProtocol.seen.last?.url?.path, "/v1/sync/head")
        XCTAssertEqual(MockURLProtocol.seen.last?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        MockURLProtocol.handler = { _ in (304, Data()) }
        let same = try await client.liveHead(ifNoneMatch: "l1.2.3")
        XCTAssertNil(same)
        XCTAssertEqual(MockURLProtocol.seen.last?.value(forHTTPHeaderField: "If-None-Match"), "\"l1.2.3\"")
    }

    func testWaitRequestAndErrors() async throws {
        MockURLProtocol.handler = { _ in (200, Data(#"{"token":"l2","changed":true,"cursor":"c5"}"#.utf8)) }
        let w = try await client.liveWait(since: "l1", timeout: 25)
        XCTAssertEqual(w, LiveWait(token: "l2", changed: true, cursor: "c5"))
        let r = MockURLProtocol.seen.last!
        XCTAssertEqual(r.url?.path, "/v1/sync/wait")
        XCTAssertTrue(r.url?.query?.contains("since=l1") == true && r.url?.query?.contains("timeout=25") == true)
        XCTAssertEqual(r.timeoutInterval, 35)
        for (status, expected) in [(401, APIError.unauthorized(reason: nil)), (404, APIError.notFound)] {
            MockURLProtocol.handler = { _ in (status, Data()) }
            do { _ = try await client.liveWait(since: nil, timeout: 25); XCTFail() }
            catch let e as APIError { XCTAssertEqual(e, expected) }
        }
        MockURLProtocol.handler = { _ in (429, Data()) }
        do { _ = try await client.liveWait(since: nil, timeout: 25); XCTFail() }
        catch let e as LiveRefreshError { XCTAssertEqual(e, .rateLimited(retryAfter: 5)) }
    }
}
