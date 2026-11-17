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
    private struct FailingOutboxStore: OutboxStore {
        func load() throws -> [OutboxOp] { [] }
        func save(_ ops: [OutboxOp]) throws { throw CocoaError(.fileWriteOutOfSpace) }
    }

    func testPlanningSaveReportsPersistenceFailure() async {
        let app = AppModel()
        app.outbox = PlanningOutbox(store: FailingOutboxStore())
        let saved = await app.savePlanning(taskID: UUID(), PlanningData(priority: 3))
        XCTAssertFalse(saved)
        XCTAssertEqual(app.noticeKey, "error.localSave")
        XCTAssertEqual(app.legacyOutboxSnapshot.pending, 0)
    }

    func testBrainConfirmedDeliveryRemovesAudioAndManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.m4a")
        try Data([1, 2, 3]).write(to: source)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewURLProtocol.self]
        let app = AppModel(session: URLSession(configuration: config), tokenStoreForServer: { _ in InMemoryTokenStore() })
        app.user = User(id: UUID(), displayName: "A", isAdmin: false, username: nil)
        let brain = BrainModel(pendingRoot: root)
        let id = UUID()
        let item = BrainOutgoing(id: id, kind: .voice(duration: 3), state: .sending, fileURL: source, attachmentID: UUID())
        XCTAssertTrue(brain.enqueue(item, app))
        let durableURL = try XCTUnwrap(brain.outgoing.first?.fileURL)
        ReviewURLProtocol.handler = { _ in
            Data("{\"id\":\"\(UUID())\",\"kind\":\"voice_in\",\"author\":\"person\",\"clientUUID\":\"\(id)\",\"createdAt\":\"2026-11-17T12:00:00Z\"}".utf8)
        }
        await brain.retry(item, app)
        XCTAssertTrue(brain.outgoing.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
        let reopened = BrainModel(pendingRoot: root)
        reopened.restorePending(app)
        XCTAssertTrue(reopened.outgoing.isEmpty)
    }

    func testBrainPendingMessagesSurviveReopeningAndCleanUpAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewURLProtocol.self]
        let app = AppModel(session: URLSession(configuration: config), tokenStoreForServer: { _ in InMemoryTokenStore() })
        app.serverURL = "https://a.invalid"
        let account = User(id: UUID(), displayName: "A", isAdmin: false, username: nil)
        app.user = account
        ReviewURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let brain = BrainModel(pendingRoot: root)
        brain.draft = "Keep this message"
        await brain.sendText(app)
        let textID = try XCTUnwrap(brain.outgoing.first?.id)
        let source = root.appendingPathComponent("recording.m4a")
        try Data([1, 2, 3]).write(to: source)
        let voiceID = UUID()
        XCTAssertTrue(brain.enqueue(BrainOutgoing(id: voiceID, kind: .voice(duration: 3), state: .sending, fileURL: source), app))
        let reopened = BrainModel(pendingRoot: root)
        reopened.restorePending(app)
        XCTAssertEqual(reopened.outgoing.map(\.id), [textID, voiceID])
        let recording = try XCTUnwrap(reopened.outgoing.last)
        let durableURL = try XCTUnwrap(recording.fileURL)
        XCTAssertEqual(try Data(contentsOf: durableURL), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        app.user = User(id: UUID(), displayName: "B", isAdmin: false, username: nil)
        let otherAccount = BrainModel(pendingRoot: root)
        otherAccount.restorePending(app)
        XCTAssertTrue(otherAccount.outgoing.isEmpty)
        app.user = account; app.serverURL = "https://b.invalid"
        let otherServer = BrainModel(pendingRoot: root)
        otherServer.restorePending(app)
        XCTAssertTrue(otherServer.outgoing.isEmpty)
        app.serverURL = "https://a.invalid"
        reopened.discard(recording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
        let final = BrainModel(pendingRoot: root)
        final.restorePending(app)
        XCTAssertEqual(final.outgoing.map(\.id), [textID])
    }

    func testEditedChatAfterLostResponseUsesNewIdempotencyKey() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewURLProtocol.self]
        let app = AppModel(session: URLSession(configuration: config), tokenStoreForServer: { _ in InMemoryTokenStore() })
        let chat = ConversationModel(taskID: UUID(), thread: .task)
        var keys: [String] = []
        ReviewURLProtocol.handler = { request in
            keys.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
            throw URLError(.networkConnectionLost)
        }
        chat.draft = "Original"
        await chat.send(app)
        await chat.send(app)
        chat.draft = "Edited"
        await chat.send(app)
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(keys[0], keys[1])
        XCTAssertNotEqual(keys[1], keys[2])
        XCTAssertEqual(chat.pendingSends.map(\.body), ["Original", "Edited"])
        chat.draft = "Original"
        await chat.send(app)
        XCTAssertEqual(keys[3], keys[0])
    }

    func testChatSuccessKeepsTextTypedWhileSending() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewURLProtocol.self]
        let app = AppModel(session: URLSession(configuration: config), tokenStoreForServer: { _ in InMemoryTokenStore() })
        let chat = ConversationModel(taskID: UUID(), thread: .task)
        chat.draft = "First"
        let started = expectation(description: "post started")
        var response: CheckedContinuation<Void, Never>?
        ReviewURLProtocol.handler = { _ in
            await withCheckedContinuation { response = $0; started.fulfill() }
            return Data("{\"id\":\"\(UUID())\",\"taskID\":\"\(chat.taskID)\",\"authorID\":\"\(UUID())\",\"body\":\"First\",\"version\":1}".utf8)
        }
        let sending = Task { await chat.send(app) }
        await fulfillment(of: [started], timeout: 2)
        chat.draft = "Next message"
        response?.resume()
        await sending.value
        XCTAssertEqual(chat.items.count, 1)
        XCTAssertEqual(chat.draft, "Next message")
    }

    func testInitialDetailLoadPreservesTypedFieldsAndDraftVersion() {
        let task = TodoTask(id: UUID(), projectID: UUID(), title: "Old", description: "A", version: 1)
        let detail = TaskDetailModel(task: task)
        detail.task = TodoTask(id: task.id, projectID: task.projectID, title: "Server", description: "B", version: 2)
        let merged = detail.initialText(title: "Typed", description: "A", initialTitle: "Old", initialDescription: "A")
        XCTAssertEqual(merged.title, "Typed")
        XCTAssertEqual(merged.description, "B")
        XCTAssertEqual(detail.textBase.version, 1)
        XCTAssertNil(detail.textUpdate(title: merged.title, description: merged.description).description)
        let untouched = TaskDetailModel(task: task)
        untouched.task = detail.task
        let fresh = untouched.initialText(title: "Old", description: "A", initialTitle: "Old", initialDescription: "A")
        XCTAssertEqual(fresh.title, "Server")
        XCTAssertEqual(untouched.textBase.version, 2)
    }

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
        try await outbox.setPlanning(taskID: UUID(), PlanningData(priority: 2))
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
