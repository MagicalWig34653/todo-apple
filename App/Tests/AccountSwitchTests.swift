import XCTest
import TodoCore
import UserNotifications
@testable import TodoApp

/// Card 346B7A6F: sign out, sign in with a second account (also on another server). Nothing of the old account may stay,
/// and an answer that arrives late must be thrown away. The app model runs for real; only the network and the system's
/// notification calls are replaced.
@MainActor
final class AccountSwitchTests: XCTestCase {
    private var server: FakeServer!
    private var tokens: [String: InMemoryTokenStore] = [:]
    private var app: AppModel!
    private var push: SpyPushSystem!

    override func setUp() async throws {
        server = FakeServer()
        AccountSwitchProtocol.server = server
        push = SpyPushSystem()
        PushCoordinator.shared.system = push
        PushCoordinator.shared.pendingLink = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountSwitchProtocol.self]
        // Fresh accounts per test: the stores on disk and in UserDefaults are keyed by server and account.
        tokens = ["a.invalid": InMemoryTokenStore(), "b.invalid": InMemoryTokenStore()]
        let stores = tokens
        app = AppModel(session: URLSession(configuration: config), tokenStoreForServer: { stores[$0.host!]! })
        app.serverURL = "https://a.invalid"
        PushCoordinator.shared.model = app
    }

    override func tearDown() async throws {
        server.releaseAll()
        await app.logout()
        PushCoordinator.shared.model = nil
        PushCoordinator.shared.pendingLink = nil
        PushCoordinator.shared.system = SystemPush()
    }

    private func signIn(_ name: String) async {
        await app.loginWithPassword(username: name, password: "pw")
        XCTAssertEqual(app.phase, .signedIn)
        XCTAssertEqual(app.user?.displayName, name)
    }

    private func switchAccount(to name: String) async {
        await app.logout()
        await signIn(name)
    }

    // MARK: Nothing of the old account stays

    func testSignOutLeavesNothingOfTheOldAccountBehind() async throws {
        await signIn("anna")
        let task = TodoTask(id: UUID(), projectID: UUID(), title: "Annas Aufgabe")
        app.path = [task]
        app.detailDrafts[task.id] = .init(subtask: "Annas Entwurf", label: "", message: "Annas Nachricht")
        app.confirmationFocus = UUID()
        app.noticeKey = "notice.conflict"
        app.agendaLoaded = true
        app.commandSummary = CommandSummary(openQuestions: 3)
        app.colorScheme = .dark
        await app.systemStatus.load(app)
        XCTAssertNotNil(app.systemStatus.response)

        await app.logout()

        XCTAssertNil(app.user)
        XCTAssertTrue(app.projects.isEmpty && app.tasks.isEmpty && app.today.isEmpty && app.upcoming.isEmpty)
        XCTAssertNil(app.commandSummary, "counters")
        XCTAssertTrue(app.path.isEmpty, "the open task of the old account would reopen for the next one")
        XCTAssertTrue(app.detailDrafts.isEmpty, "unsent input of the old account")
        XCTAssertNil(app.confirmationFocus)
        XCTAssertNil(app.noticeKey)
        XCTAssertFalse(app.agendaLoaded, "the next account must see loading rows, not the old 'empty' state")
        XCTAssertEqual(app.colorScheme, .system, "appearance is an account setting")
        XCTAssertNil(app.systemStatus.response, "Lage-Ampel of the old account")
        XCTAssertNil(try tokens["a.invalid"]!.load())
    }

    func testSessionExpiryClearsTheScreenStateButKeepsAppearance() async throws {
        await signIn("anna")
        app.path = [TodoTask(id: UUID(), projectID: UUID(), title: "Annas Aufgabe")]
        app.colorScheme = .dark
        await app.handle(APIError.unauthorized(reason: nil))
        XCTAssertEqual(app.phase, .signedOut)
        XCTAssertTrue(app.path.isEmpty)
        XCTAssertEqual(app.errorKey, "error.sessionExpired")
        XCTAssertEqual(app.colorScheme, .dark)
        // Another account signs in afterwards: the appearance of the old one does not carry over.
        await signIn("bert")
        XCTAssertEqual(app.colorScheme, .system)
    }

    func testSignOutRemovesAttachmentPreviews() async throws {
        await signIn("anna")
        let folder = FileManager.default.temporaryDirectory.appending(path: "attachment-preview", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "annas-anhang.pdf")
        try Data("x".utf8).write(to: file)
        await app.logout()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSettingsOfTheOldAccountDoNotStayInTheSettingsHub() async throws {
        await signIn("anna")
        let hub = SettingsHubModel()
        await hub.load(app)
        hub.pairing = RunnerPairing(deviceID: UUID(), code: "ANNA-CODE", expiresAt: Date())
        hub.preferences = AccountPreferences().withColorScheme(.dark)
        await switchAccount(to: "bert")
        await hub.load(app)
        XCTAssertNil(hub.pairing, "the Mac settings window lives across accounts")
        XCTAssertNil(hub.preferences)
    }

    // MARK: Push and notification links

    func testSignOutRemovesTheNotificationsAndEndsTheSystemRegistration() async throws {
        await signIn("anna")
        push.reset()
        await app.logout()
        XCTAssertEqual(push.removedAll, 1, "delivered notifications and 'Später' copies show the old account's tasks")
        XCTAssertEqual(push.unregistered, 1, "the server cannot be reached for sure; the device has to stop on its own")
        XCTAssertEqual(push.badges.last, 0)
    }

    func testSignOutDropsATappedNotificationLink() async throws {
        await signIn("anna")
        PushCoordinator.shared.pendingLink = .task(taskID: UUID(), projectID: UUID())
        await app.logout()
        XCTAssertNil(PushCoordinator.shared.pendingLink)
    }

    func testLinkTappedAfterSessionExpiryDoesNotOpenForAnotherAccount() async throws {
        await signIn("anna")
        await app.handle(APIError.unauthorized(reason: nil))
        PushCoordinator.shared.open(.forYou(requestID: UUID()))
        push.reset()
        await signIn("bert")
        XCTAssertNil(PushCoordinator.shared.pendingLink)
        XCTAssertNil(app.confirmationFocus, "Anna's notification must not steer Bert's app")
        XCTAssertEqual(push.removedAll, 1)
    }

    func testLinkTappedAfterSessionExpiryOpensForTheSameAccount() async throws {
        await signIn("anna")
        await app.handle(APIError.unauthorized(reason: nil))
        let request = UUID()
        PushCoordinator.shared.open(.forYou(requestID: request))
        push.reset()
        await signIn("anna")
        XCTAssertEqual(app.confirmationFocus, request)
        XCTAssertEqual(push.removedAll, 0)
    }

    func testLatePushRegistrationOfTheOldAccountLeavesNoErrorForTheNextOne() async throws {
        push.status = .authorized
        await signIn("anna")
        let held = server.hold("POST /v1/push/devices", for: "anna")
        PushCoordinator.shared.didRegister(deviceToken: Data(repeating: 0xab, count: 32))
        await fulfillment(of: [held.arrived], timeout: 5)
        push.status = .denied  // Bert's sign-in must not register (and so clear the error) on its own.
        await switchAccount(to: "bert")
        held.release(500, "{}")
        await settle()
        XCTAssertNil(PushCoordinator.shared.model?.errorKey)
        XCTAssertNil(PushCoordinator.shared.registrationErrorKey)
    }

    // MARK: Requests that are still running

    func testLateUnauthorizedAnswerOfTheOldAccountDoesNotSignOutTheNewOne() async throws {
        await signIn("anna")
        let held = server.hold("GET /v1/teams", for: "anna")
        let running = Task { await app.reloadTeams() }
        await fulfillment(of: [held.arrived], timeout: 5)
        await switchAccount(to: "bert")
        held.release(401, #"{"reason":"unauthorized"}"#)
        await running.value
        XCTAssertEqual(app.phase, .signedIn, "Anna's expired session signed Bert out")
        XCTAssertEqual(app.user?.displayName, "bert")
        XCTAssertEqual(try tokens["a.invalid"]!.load(), "token-bert")
        XCTAssertNil(app.errorKey)
        XCTAssertNil(app.noticeKey)
    }

    func testLateSuccessOfTheOldAccountIsDiscarded() async throws {
        server.hasSyncFeed = false  // REST fallback (older server): writes append straight to the lists.
        await signIn("anna")
        app.selection = .project(UUID())
        let project = try XCTUnwrap(app.selectedProjectID)
        let held = server.hold("POST /v1/tasks", for: "anna")
        let running = Task { await app.addTask(title: "Annas Aufgabe") }
        await fulfillment(of: [held.arrived], timeout: 5)
        await switchAccount(to: "bert")
        held.release(200, #"{"id":"\#(UUID())","projectID":"\#(project)","title":"Annas Aufgabe","description":"","status":"open","version":1}"#)
        await running.value
        XCTAssertFalse(app.tasks.contains { $0.title == "Annas Aufgabe" }, "Anna's task shows up in Bert's list")
        XCTAssertNil(app.noticeKey, "no alert about a request Bert never made")
    }

    func testLateAnswerOfTheOldServerIsDiscardedAfterAServerSwitch() async throws {
        server.hasSyncFeed = false
        await signIn("anna")
        app.selection = .project(UUID())
        let project = try XCTUnwrap(app.selectedProjectID)
        let held = server.hold("POST /v1/tasks", for: "anna")
        let running = Task { await app.addTask(title: "Vom alten Server") }
        await fulfillment(of: [held.arrived], timeout: 5)
        await app.logout()
        app.serverURL = "https://b.invalid"
        await signIn("bert")
        held.release(200, #"{"id":"\#(UUID())","projectID":"\#(project)","title":"Vom alten Server","description":"","status":"open","version":1}"#)
        await running.value
        XCTAssertFalse(app.tasks.contains { $0.title == "Vom alten Server" })
        XCTAssertNil(try tokens["a.invalid"]!.load())
        XCTAssertEqual(try tokens["b.invalid"]!.load(), "token-bert")
    }

    func testClientOfAnEndedSessionNeverSendsWithTheNewAccountsToken() async throws {
        await signIn("anna")
        let old = try XCTUnwrap(app.client)  // held by a retry loop or a multi-step action
        await switchAccount(to: "bert")
        server.clearRequests()
        do { _ = try await old.teams(); XCTFail("the old session's client still works") } catch {}
        XCTAssertFalse(server.requests.contains { $0 == "GET /v1/teams bert" }, "sent with the new account's token")
    }

    func testNothingStartedWhileSigningOutReachesTheNextAccount() async throws {
        push.status = .authorized
        await signIn("anna")
        await PushCoordinator.shared.refreshAuthorization()
        let signingOut = server.hold("POST /v1/auth/logout", for: "anna")
        let teams = server.hold("GET /v1/teams", for: "anna")
        let logout = Task { await app.logout() }
        await fulfillment(of: [signingOut.arrived], timeout: 5)
        // The old screens are still visible during the sign-out and may ask for fresh data.
        let counters = Task { await app.refreshCommandSummary() }
        let running = Task { await app.reloadTeams() }
        await settle()
        signingOut.release(204, "")
        await logout.value
        await counters.value
        await settle()
        XCTAssertEqual(push.badges.last, 0, "the badge shows the old account's open questions again")
        await signIn("bert")
        teams.release(401, #"{"reason":"unauthorized"}"#)
        await running.value
        XCTAssertEqual(app.phase, .signedIn)
        XCTAssertEqual(app.user?.displayName, "bert")
    }

    func testLateFailedPushSettingOfTheOldAccountIsNotRestored() async throws {
        push.status = .authorized
        await signIn("anna")
        await PushCoordinator.shared.sync(client: app.client, userID: app.user?.id)
        XCTAssertNotNil(PushCoordinator.shared.prefs)
        let held = server.hold("POST /v1/me/push-prefs", for: "anna")
        let client = app.client
        let running = Task { await PushCoordinator.shared.setShowContent(true, client: client) }
        await fulfillment(of: [held.arrived], timeout: 5)
        push.status = .denied
        await app.logout()
        held.release(500, "{}")
        await running.value
        XCTAssertNil(PushCoordinator.shared.prefs, "the old account's notification settings are back")
        XCTAssertNil(PushCoordinator.shared.prefsErrorKey)
    }

    func testLateFailedFavoriteOfTheOldAccountDoesNotUndoTheNewOnesFavorite() async throws {
        let shared = UUID()
        server.sharedProject = shared  // both accounts see it; only Bert has it as a favorite
        await signIn("anna")
        let project = try XCTUnwrap(app.projects.first { $0.id == shared })
        let held = server.hold("PUT /v1/me/favorites/\(shared.uuidString.lowercased())", for: "anna")
        let running = Task { await app.toggleFavorite(project) }
        await fulfillment(of: [held.arrived], timeout: 5)
        await switchAccount(to: "bert")
        XCTAssertEqual(app.favoriteProjects.map(\.id), [shared])
        held.release(500, "{}")
        await running.value
        XCTAssertEqual(app.favoriteProjects.map(\.id), [shared], "Anna's rollback changed Bert's favorites")
        XCTAssertNil(app.noticeKey)
    }

    func testLateAnswerToAMarkDoneFromANotificationDoesNotBringUpTheTaskForTheNextAccount() async throws {
        await signIn("anna")
        let held = server.hold("GET /v1/tasks", for: "anna")
        let running = Task { await app.markDoneFromPush(taskID: UUID(), projectID: UUID()) }
        await fulfillment(of: [held.arrived], timeout: 5)
        await switchAccount(to: "bert")
        held.release(200, "[]")
        let done = await running.value
        XCTAssertTrue(done, "'false' makes the delegate open Anna's task in Bert's app")
    }

    func testSaveOfAClosingTaskAfterSignOutDoesNotReportAnExpiredSession() async throws {
        server.hasSyncFeed = false
        await signIn("anna")
        let task = TodoTask(id: UUID(), projectID: UUID(), title: "Annas Aufgabe")
        await app.logout()
        server.unauthorized = true
        // The detail view saves its text when it disappears, which can be after the sign-out.
        _ = await app.updateTask(task, TaskUpdate(title: "noch getippt"))
        XCTAssertNil(app.errorKey)
        XCTAssertEqual(app.phase, .signedOut)
    }

    func testSessionExpiryEndsTheSystemRegistrationButKeepsTheNotifications() async throws {
        await signIn("anna")
        push.reset()
        await app.handle(APIError.unauthorized(reason: nil))
        XCTAssertEqual(push.unregistered, 1, "the server still holds the push device of the expired session")
        XCTAssertEqual(push.removedAll, 0, "kept for the same account signing in again")
    }

    func testLateListMetadataOfTheOldAccountIsNotWrittenIntoTheNewAccountsCache() async throws {
        await signIn("anna")
        let annasCache = try XCTUnwrap(app.metaCacheURL)
        try Data(#"{"planning":[],"labels":[{"id":"\#(UUID())","name":"Annas Label","version":1}],"labelsByTask":[]}"#.utf8).write(to: annasCache)
        let meta = TaskMeta()
        let held = server.hold("GET /v1/planning/up-next", for: "anna")
        let running = Task { await meta.refresh(app) }
        await fulfillment(of: [held.arrived], timeout: 5)
        await switchAccount(to: "bert")
        let bertsCache = try XCTUnwrap(app.metaCacheURL)
        XCTAssertNotEqual(annasCache, bertsCache)
        held.release(200, "[]")
        await running.value
        let written = (try? String(contentsOf: bertsCache, encoding: .utf8)) ?? ""
        XCTAssertFalse(written.contains("Annas Label"), "Anna's labels were saved as Bert's offline cache")
        XCTAssertFalse(FileManager.default.fileExists(atPath: annasCache.path), "the removed cache of the old account was written again")
    }

    func testLateGroupAssignmentOfTheOldAccountLeavesNoNotice() async throws {
        server.hasSyncFeed = false
        server.createdProject = UUID()
        await signIn("anna")
        let held = server.hold("PUT /v1/projects/\(server.createdProject.uuidString)/groups", for: "anna")
        let running = Task { await app.addProject(name: "Annas Projekt", parentID: nil, groupIDs: [UUID()]) }
        await fulfillment(of: [held.arrived], timeout: 5)
        await switchAccount(to: "bert")
        held.release(500, "{}")
        await running.value
        XCTAssertNil(app.noticeKey)
        XCTAssertTrue(app.projects.isEmpty)
    }

    func testLatePlanningReadOfTheOldAccountLeavesNoNotice() async throws {
        await signIn("anna")
        let task = TodoTask(id: UUID(), projectID: UUID(), title: "Annas Aufgabe")
        let held = server.hold("GET /v1/planning/tasks/\(task.id.uuidString)", for: "anna")
        let running = Task { await TaskMeta().setPriority(task, to: 2, app) }
        await fulfillment(of: [held.arrived], timeout: 5)
        await switchAccount(to: "bert")
        held.release(500, "{}")
        await running.value
        XCTAssertNil(app.noticeKey)
    }

    func testChangeCancelledBySignOutLeavesNoNotice() async throws {
        await signIn("anna")
        _ = await app.queueChange { _ in throw CancellationError() }
        XCTAssertNil(app.noticeKey)
    }

    func testLateSettingsAnswerOfTheOldAccountIsDiscarded() async throws {
        server.darkPreferencesFor = "anna"
        await signIn("anna")
        app.colorScheme = .system
        let hub = SettingsHubModel()
        let held = server.hold("GET /v1/me/passkeys", for: "anna")
        let running = Task { await hub.load(app) }
        await fulfillment(of: [held.arrived], timeout: 5)
        await settle()
        await switchAccount(to: "bert")
        held.release(404, "{}")
        await running.value
        XCTAssertEqual(app.colorScheme, .system, "Anna's appearance was applied to Bert")
        XCTAssertNil(hub.preferences)
    }

    func testExpiredSessionAtLaunchEndsTheSystemRegistration() async throws {
        try tokens["a.invalid"]!.save("token-anna")
        server.unauthorized = true
        await app.start()
        XCTAssertEqual(app.phase, .signedOut)
        XCTAssertNil(try tokens["a.invalid"]!.load())
        XCTAssertEqual(push.unregistered, 1)
        XCTAssertEqual(push.removedAll, 0)
    }

    func testNotificationTappedForAStoredSessionOpensAtLaunch() async throws {
        // A launch with a stored session is no account switch, whatever was signed in on this device before.
        UserDefaults.standard.set("https://other.invalid:443|\(UUID())", forKey: "session.lastAccount")
        try tokens["a.invalid"]!.save("token-anna")
        let request = UUID()
        PushCoordinator.shared.pendingLink = .forYou(requestID: request)
        await app.start()
        XCTAssertEqual(app.phase, .signedIn)
        XCTAssertEqual(app.confirmationFocus, request)
        XCTAssertEqual(push.removedAll, 0)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(400)) }
}

@MainActor
final class SpyPushSystem: PushSystem {
    var status: UNAuthorizationStatus = .denied
    var badges: [Int] = []
    var registered = 0, unregistered = 0, removedAll = 0
    func reset() { badges = []; registered = 0; unregistered = 0; removedAll = 0 }
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func setBadge(_ count: Int) async { badges.append(count) }
    func register() { registered += 1 }
    func unregister() { unregistered += 1 }
    func removeAllNotifications() { removedAll += 1 }
}

/// Two accounts behind a URLProtocol. `hold` keeps one request of one account open until the test releases it.
final class FakeServer: @unchecked Sendable {
    final class Held: @unchecked Sendable {
        let arrived = XCTestExpectation(description: "request arrived")
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(Int, String), Never>?
        private var result: (Int, String)?
        func release(_ status: Int, _ body: String) {
            lock.lock(); defer { lock.unlock() }
            if let continuation { continuation.resume(returning: (status, body)); self.continuation = nil }
            else if result == nil { result = (status, body) }
        }
        func wait() async -> (Int, String) {
            await withCheckedContinuation { c in
                lock.lock(); defer { lock.unlock() }
                if let result { c.resume(returning: result) } else { continuation = c }
                arrived.fulfill()
            }
        }
    }

    private let lock = NSLock()
    private var holds: [String: Held] = [:]
    private var all: [Held] = []
    private var log: [String] = []
    private var ids: [String: UUID] = ["anna": UUID(), "bert": UUID()]
    var hasSyncFeed = true
    var unauthorized = false
    var sharedProject: UUID?
    var createdProject = UUID()
    var darkPreferencesFor: String?

    var requests: [String] { lock.withLock { log } }
    func clearRequests() { lock.withLock { log = [] } }
    func releaseAll() { lock.withLock { all }.forEach { $0.release(404, "{}") } }

    func hold(_ route: String, for account: String) -> Held {
        let held = Held()
        lock.withLock { holds["\(route) \(account)"] = held; all.append(held) }
        return held
    }

    func answer(_ request: URLRequest, body: Data) async -> (Int, String) {
        let account = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer token-", with: "") ?? "-"
        let route = "\(request.httpMethod!) \(request.url!.path)"
        let held: Held? = lock.withLock {
            log.append("\(route) \(account)")
            return holds.removeValue(forKey: "\(route) \(account)")
        }
        if let held { return await held.wait() }
        let now = ISO8601DateFormatter().string(from: Date())
        if unauthorized { return (401, #"{"reason":"unauthorized"}"#) }
        if route == "GET /v1/sync/changes", let sharedProject {
            let favorite = account == "bert" ? #","isFavorite":true,"favoritePosition":0"# : #","isFavorite":false"#
            return (200, #"{"changes":[{"seq":1,"entityType":"project","entityID":"\#(sharedProject)","kind":"upsert","project":{"id":"\#(sharedProject)","name":"Geteilt","version":1\#(favorite)}}],"cursor":"c1","hasMore":false}"#)
        }
        if route == "POST /v1/projects" { return (200, #"{"id":"\#(createdProject)","name":"Neu","version":1}"#) }
        if route == "GET /v1/me/preferences", account == darkPreferencesFor {
            return (200, #"{"version":1,"appearance":{"colorScheme":"dark","accent":"blue","glow":"subtle"},"revision":1}"#)
        }
        switch route {
        case "GET /v1/capabilities": return (200, #"{"password":true,"passkey":true,"bootstrapOpen":false}"#)
        case "POST /v1/auth/password/login":
            let name = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["username"] as? String ?? "?"
            let id = lock.withLock { ids[name]! }
            return (200, #"{"token":"token-\#(name)","expiresAt":"2027-01-01T00:00:00Z","user":{"id":"\#(id)","displayName":"\#(name)","isAdmin":false}}"#)
        case "GET /v1/me":
            let id = lock.withLock { ids[account] ?? UUID() }
            return (200, #"{"id":"\#(id)","displayName":"\#(account)","isAdmin":false}"#)
        case "POST /v1/auth/logout": return (204, "")
        case "GET /v1/sync/changes" where hasSyncFeed: return (200, #"{"changes":[],"cursor":"c1","hasMore":false}"#)
        case "GET /v1/projects", "GET /v1/tasks", "GET /v1/teams", "GET /v1/team-invitations": return (200, "[]")
        case "GET /v1/system-status": return (200, #"{"items":[{"source":"\#(account)","reportedAt":"\#(now)","status":{}}],"now":"\#(now)"}"#)
        case "GET /v1/command-center": return (200, #"{"scope":"account","view":"kanban","summary":{"running":0,"question":3,"review":0,"ready":0,"blocked":0,"done":0,"backlog":0,"openQuestions":3,"pendingReviews":0,"features":0,"activeAgents":0},"lanes":[],"updates":[],"builds":[],"generatedAt":"\#(now)"}"#)
        case "GET /v1/push/prefs", "GET /v1/me/push-prefs": return (200, #"{"categories":{"reminders":true,"agent_questions":true,"agent_reviews":true,"assignments":false,"comments":false},"showContent":false,"badge":true,"dailyBriefHour":6}"#)
        default: return (404, "{}")
        }
    }
}

final class AccountSwitchProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server: FakeServer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(contentsOf: buffer[0..<n])
            }
        }
        let server = Self.server!, request = self.request
        Task {
            let (status, text) = await server.answer(request, body: body)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
