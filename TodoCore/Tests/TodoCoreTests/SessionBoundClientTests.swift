import Foundation
import XCTest

@testable import TodoCore

/// Card 346B7A6F: a client handed out for one signed-in session must stop working when that session ends: no request
/// (the token store may hold the next account's token by then) and no late answer (neither success nor "401").
final class SessionBoundClientTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var isCurrent: Bool { lock.withLock { value } }
        func end() { lock.withLock { value = false } }
    }

    private final class Transport: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (status, body) = Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private final class Counter: @unchecked Sendable { var requests = 0 }

    private func makeClient(_ flag: Flag) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Transport.self]
        return APIClient(
            baseURL: URL(string: "https://a.invalid")!, session: URLSession(configuration: config), tokenStore: InMemoryTokenStore(token: "t")
        ).bound { flag.isCurrent }
    }

    private func assertCancelled(_ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await work(); XCTFail("accepted although the session ended", file: file, line: line) }
        catch is CancellationError {}
        catch { XCTFail("expected CancellationError, got \(error)", file: file, line: line) }
    }

    func testCurrentSessionWorksAsBefore() async throws {
        Transport.handler = { _ in (200, "[]") }
        let list = try await makeClient(Flag()).projects()
        XCTAssertTrue(list.isEmpty)
    }

    func testEndedSessionSendsNothing() async {
        let flag = Flag(), counter = Counter()
        Transport.handler = { _ in counter.requests += 1; return (200, "[]") }
        let client = makeClient(flag)
        flag.end()
        await assertCancelled { _ = try await client.projects() }
        await assertCancelled { _ = try await client.liveHead(ifNoneMatch: nil) }
        XCTAssertEqual(counter.requests, 0)
    }

    func testLateSuccessIsDiscarded() async {
        let flag = Flag()
        Transport.handler = { _ in flag.end(); return (200, "[]") }
        await assertCancelled { _ = try await self.makeClient(flag).projects() }
    }

    func testLateUnauthorizedIsDiscarded() async {
        let flag = Flag()
        Transport.handler = { _ in flag.end(); return (401, "{}") }
        await assertCancelled { _ = try await self.makeClient(flag).projects() }
    }

    func testLateLiveAnswerIsDiscarded() async {
        let flag = Flag()
        Transport.handler = { _ in flag.end(); return (401, "{}") }
        await assertCancelled { _ = try await self.makeClient(flag).liveWait(since: nil, timeout: 1) }
    }
}
