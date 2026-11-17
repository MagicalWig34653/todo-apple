import XCTest
import TodoCore
@testable import TodoApp

final class ReviewURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) async throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task {
            do {
                let data = try await Self.handler!(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}

@MainActor
final class ReviewFixTests: XCTestCase {
    func testInvalidatedSyncCannotPersistOrPublishDelayedFeed() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewURLProtocol.self]
        let session = URLSession(configuration: config)
        let app = AppModel(session: session, tokenStoreForServer: { _ in InMemoryTokenStore() })
        let store = InMemorySyncStore()
        let engine = try SyncEngine(client: APIClient(baseURL: URL(string: "https://a.invalid")!, session: session), store: store)
        app.engine = engine
        let started = expectation(description: "feed started")
        var response: CheckedContinuation<Void, Never>?
        ReviewURLProtocol.handler = { _ in
            await withCheckedContinuation { response = $0; started.fulfill() }
            return Data(#"{"changes":[],"cursor":"c9","hasMore":false}"#.utf8)
        }
        let sync = Task { await app.syncNow() }
        await fulfillment(of: [started], timeout: 2)
        app.sessionGeneration = UUID()
        app.engine = nil
        try await engine.reset()
        response?.resume()
        await sync.value
        XCTAssertEqual(try store.load().cursor, "c0")
        XCTAssertFalse(app.usesREST)
        XCTAssertTrue(app.tasks.isEmpty)
        do { _ = try await engine.createProject(name: "late"); XCTFail("Invalidated engine accepted a write") }
        catch is CancellationError {}
    }

    func testServerSwitchDiscardsDelayedLoginAndScopesToken() async throws {
        let a = InMemoryTokenStore(), b = InMemoryTokenStore()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewURLProtocol.self]
        let app = AppModel(session: URLSession(configuration: config), tokenStoreForServer: { $0.host == "a.invalid" ? a : b })
        app.serverURL = "https://a.invalid"
        let started = expectation(description: "login started")
        var response: CheckedContinuation<Void, Never>?
        ReviewURLProtocol.handler = { request in
            if request.url!.path.contains("capabilities") { return Data(#"{"password":true,"passkey":true,"bootstrapOpen":false}"#.utf8) }
            await withCheckedContinuation { response = $0; started.fulfill() }
            return Data(#"{"token":"a-token","expiresAt":"2026-11-18T12:00:00Z","user":{"id":"00000000-0000-0000-0000-000000000001","displayName":"A","isAdmin":false}}"#.utf8)
        }
        let login = Task { await app.loginWithPassword(username: "A", password: "pw") }
        await fulfillment(of: [started], timeout: 2)
        app.serverURL = "https://b.invalid"
        response?.resume()
        await login.value
        XCTAssertNil(app.user)
        XCTAssertEqual(app.phase, .signedOut)
        XCTAssertNil(try b.load())
        XCTAssertNil(try a.load(), "Stale authentication must not write durable credentials")
    }
}
