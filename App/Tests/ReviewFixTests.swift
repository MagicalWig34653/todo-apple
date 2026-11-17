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
    func testDetailTextPatchOnlyContainsEditedFields() {
        let task = TodoTask(id: UUID(), projectID: UUID(), title: "Old", description: "A", version: 1)
        let detail = TaskDetailModel(task: task)
        let patch = detail.textUpdate(title: "New", description: "A")
        XCTAssertEqual(patch.title, "New")
        XCTAssertNil(patch.description)
        XCTAssertNil(detail.textUpdate(title: "Old", description: "A").title)
    }

    func testExpiredSessionPreservesAccountQueueForReauthentication() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewURLProtocol.self]
        let session = URLSession(configuration: config)
        ReviewURLProtocol.handler = { _ in Data("{}".utf8) }
        let app = AppModel(session: session, tokenStoreForServer: { _ in InMemoryTokenStore() })
        let client = APIClient(baseURL: URL(string: "https://a.invalid")!, session: session)
        let store = InMemorySyncStore()
        let engine = try SyncEngine(client: client, store: store)
        _ = try await engine.createProject(name: "Offline work")
        let outboxStore = InMemoryOutboxStore()
        let outbox = PlanningOutbox(store: outboxStore)
        await outbox.setPlanning(taskID: UUID(), PlanningData(priority: 2))
        app.engine = engine; app.outbox = outbox
        await app.handle(APIError.unauthorized(reason: nil))
        let reopened = try SyncEngine(client: client, store: store)
        let snap = await reopened.snapshot()
        XCTAssertEqual(snap.pending, 1)
        XCTAssertEqual(snap.projects.first?.name, "Offline work")
        XCTAssertEqual(try outboxStore.load().count, 1)
        XCTAssertNil(app.engine)
        XCTAssertEqual(app.phase, .signedOut)
    }

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
