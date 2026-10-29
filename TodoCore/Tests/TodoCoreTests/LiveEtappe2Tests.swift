import CryptoKit
import Foundation
import XCTest

@testable import TodoCore

/// Software passkey (ES256, "none" attestation) implementing the client's `PasskeyAuthenticator` seam, so the
/// real registration/login ceremony runs against the backend without hardware.
final class VirtualPasskey: PasskeyAuthenticator, @unchecked Sendable {
    private let key = P256.Signing.PrivateKey()
    private var credentialID = Data()
    private var counter: UInt32 = 0
    private let origin: String

    init(origin: String) { self.origin = origin }

    private func clientData(type: String, challenge: Data) -> Data {
        Data(#"{"type":"\#(type)","challenge":"\#(challenge.base64URLEncoded)","origin":"\#(origin)","crossOrigin":false}"#.utf8)
    }

    private func counterBytes() -> [UInt8] { [UInt8(counter >> 24), UInt8((counter >> 16) & 0xff), UInt8((counter >> 8) & 0xff), UInt8(counter & 0xff)] }

    func register(challenge: Data, relyingPartyID: String, userID: Data, userName: String) async throws -> PasskeyRegistrationResult {
        credentialID = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        counter = 0
        let raw = [UInt8](key.publicKey.x963Representation)
        let cose: [UInt8] = [0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20] + raw[1..<33] + [0x22, 0x58, 0x20] + raw[33..<65]
        var authData = [UInt8](SHA256.hash(data: Data(relyingPartyID.utf8)))
        authData += [0x45] + counterBytes() + [UInt8](repeating: 0, count: 16)
        authData += [UInt8(credentialID.count >> 8), UInt8(credentialID.count & 0xff)] + [UInt8](credentialID) + cose
        var cbor: [UInt8] = [0xA3, 0x63] + Array("fmt".utf8) + [0x64] + Array("none".utf8) + [0x67] + Array("attStmt".utf8)
        cbor += [0xA0, 0x68] + Array("authData".utf8) + [0x59, UInt8(authData.count >> 8), UInt8(authData.count & 0xff)] + authData
        return PasskeyRegistrationResult(
            credentialID: credentialID, clientDataJSON: clientData(type: "webauthn.create", challenge: challenge),
            attestationObject: Data(cbor))
    }

    func authenticate(challenge: Data, relyingPartyID: String) async throws -> PasskeyAssertionResult {
        counter += 1
        let authData = [UInt8](SHA256.hash(data: Data(relyingPartyID.utf8))) + [0x05] + counterBytes()
        let cd = clientData(type: "webauthn.get", challenge: challenge)
        let message = Data(authData) + Data(SHA256.hash(data: cd))
        let signature = try key.signature(for: message).derRepresentation
        return PasskeyAssertionResult(
            credentialID: credentialID, clientDataJSON: cd, authenticatorData: Data(authData), signature: signature, userHandle: nil)
    }
}

/// Opt-in end-to-end run of the Etappe 2 client against a real backend with a fresh database:
/// `TEST_RUNNER_TODO_LIVE_BASE_URL=http://127.0.0.1:28381 xcodebuild test ...`
/// Needs the dev bootstrap token (`TODO_LIVE_BOOTSTRAP_TOKEN`, default `dev-bootstrap-only`) to still be open.
/// Origin used for the virtual passkey: `TODO_LIVE_RP_ORIGIN` (default `http://localhost:25173`).
final class LiveEtappe2Tests: XCTestCase {
    struct Fixture {
        let admin: APIClient
        let adminStore: InMemoryTokenStore
        let adminUser: User
        let bob: APIClient
        let bobUser: User
        let suffix: String
    }

    actor Cache {
        static let shared = Cache()
        var fixture: Fixture?
        func get(_ make: () async throws -> Fixture) async throws -> Fixture {
            if let fixture { return fixture }
            let f = try await make()
            fixture = f
            return f
        }
    }

    func fixture() async throws -> Fixture {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["TODO_LIVE_BASE_URL"], let url = URL(string: raw) else { throw XCTSkip("TODO_LIVE_BASE_URL not set") }
        let origin = env["TODO_LIVE_RP_ORIGIN"] ?? "http://localhost:25173"
        let token = env["TODO_LIVE_BOOTSTRAP_TOKEN"] ?? "dev-bootstrap-only"
        return try await Cache.shared.get {
            let suffix = String(UUID().uuidString.prefix(6)).lowercased()
            let adminStore = InMemoryTokenStore()
            let admin = APIClient(baseURL: url, tokenStore: adminStore)
            let caps = try await admin.capabilities()
            guard caps.bootstrapOpen else { throw XCTSkip("bootstrap already used; start a fresh backend database") }
            let adminUser = try await admin.registerWithPasskey(
                token: token, displayName: "Alice \(suffix)", authenticator: VirtualPasskey(origin: origin))
            XCTAssertTrue(adminUser.isAdmin)
            let invite = try await admin.createInvitation()
            let bob = APIClient(baseURL: url)
            let bobUser = try await bob.registerWithPasskey(
                token: invite.token, displayName: "Bob \(suffix)", authenticator: VirtualPasskey(origin: origin))
            XCTAssertFalse(bobUser.isAdmin)
            return Fixture(admin: admin, adminStore: adminStore, adminUser: adminUser, bob: bob, bobUser: bobUser, suffix: suffix)
        }
    }

    func testPasskeyRegistrationLoginAndMe() async throws {
        let f = try await fixture()
        let me = try await f.admin.me()
        XCTAssertEqual(me.id, f.adminUser.id)
        // Real login ceremony: register a third user, then log in from a new client with the same virtual passkey.
        let origin = ProcessInfo.processInfo.environment["TODO_LIVE_RP_ORIGIN"] ?? "http://localhost:25173"
        let key = VirtualPasskey(origin: origin)
        let invite = try await f.admin.createInvitation()
        let carol = APIClient(baseURL: f.admin.baseURL)
        let carolUser = try await carol.registerWithPasskey(token: invite.token, displayName: "Carol \(f.suffix)", authenticator: key)
        let relogin = APIClient(baseURL: f.admin.baseURL)
        let again = try await relogin.loginWithPasskey(authenticator: key)
        XCTAssertEqual(again.id, carolUser.id)
        let me2 = try await relogin.me()
        XCTAssertEqual(me2.id, carolUser.id)
        try await relogin.logout()
        do { _ = try await relogin.me(); XCTFail("session survived logout") } catch {}
        // Fresh passkey login with a second virtual authenticator must fail (unknown credential), a valid one is covered by register.
        let other = APIClient(baseURL: f.admin.baseURL)
        do {
            _ = try await other.loginWithPasskey(authenticator: VirtualPasskey(origin: "http://localhost:25173"))
            XCTFail("unknown credential accepted")
        } catch {}
    }

    func testPlanning() async throws {
        let f = try await fixture()
        let p = try await f.admin.createProject(name: "Plan \(f.suffix)")
        let t = try await f.admin.createTask(projectID: p.id, title: "Heute faellig")
        let now = Date()
        let due = now.addingTimeInterval(60)  // today, in the local calendar day unless run at 23:59
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!.addingTimeInterval(3600)
        let data = PlanningData(
            dueAt: due, plannedAt: now, priority: 3,
            recurrence: RecurrenceRule(frequency: .weekly, interval: 2, timeZone: TimeZone.current.identifier),
            reminders: [now.addingTimeInterval(30)])
        let saved = try await f.admin.setPlanning(taskID: t.id, data)
        XCTAssertEqual(saved.planning.priority, 3)
        XCTAssertEqual(saved.planning.recurrence?.frequency, .weekly)
        XCTAssertEqual(saved.planning.recurrence?.interval, 2)
        XCTAssertEqual(saved.planning.reminders.count, 1)
        XCTAssertEqual(try XCTUnwrap(saved.planning.dueAt).timeIntervalSince1970, due.timeIntervalSince1970, accuracy: 1)
        let t2 = try await f.admin.createTask(projectID: p.id, title: "Morgen")
        _ = try await f.admin.setPlanning(taskID: t2.id, PlanningData(dueAt: tomorrow, priority: 1))

        let today = try await f.admin.today()
        XCTAssertTrue(today.contains { $0.id == t.id }, "today misses task")
        XCTAssertFalse(today.contains { $0.id == t2.id })
        let upcoming = try await f.admin.upcoming()
        XCTAssertTrue(upcoming.contains { $0.id == t2.id }, "upcoming misses task")
        let next = try await f.admin.upNext()
        XCTAssertTrue(next.contains { $0.id == t.id })
        if let a = next.firstIndex(where: { $0.id == t.id }), let b = next.firstIndex(where: { $0.id == t2.id }) {
            XCTAssertLessThan(a, b, "higher priority first")
        }

        // PUT replaces: clearing dates via null.
        let cleared = try await f.admin.setPlanning(taskID: t.id, PlanningData(priority: 0))
        XCTAssertNil(cleared.planning.dueAt)
        XCTAssertNil(cleared.planning.recurrence)
        XCTAssertTrue(cleared.planning.reminders.isEmpty)
        let reread = try await f.admin.planning(taskID: t.id)
        XCTAssertNil(reread.planning.dueAt)
        let todayAfter = try await f.admin.today()
        XCTAssertFalse(todayAfter.contains { $0.id == t.id })
    }

    func testLabelsAndSearch() async throws {
        let f = try await fixture()
        let p = try await f.admin.createProject(name: "Suche \(f.suffix)")
        let word = "Zebrafink\(f.suffix)"
        let t = try await f.admin.createTask(projectID: p.id, title: "Aufgabe \(word)", description: "Beschreibung")
        let t2 = try await f.admin.createTask(projectID: p.id, title: "Andere Aufgabe")
        let label = try await f.admin.createLabel(name: "wichtig-\(f.suffix)")
        let renamed = try await f.admin.renameLabel(label.id, version: label.version, name: "dringend-\(f.suffix)")
        XCTAssertEqual(renamed.name, "dringend-\(f.suffix)")
        XCTAssertGreaterThan(renamed.version, label.version)
        let all = try await f.admin.labels()
        XCTAssertTrue(all.items.contains { $0.id == label.id })
        try await f.admin.addLabel(label.id, toTask: t.id)
        let onTask = try await f.admin.labels(taskID: t.id)
        XCTAssertEqual(onTask.items.map(\.id), [label.id])

        let byText = try await f.admin.search(word)
        XCTAssertTrue(byText.items.contains { $0.kind == .task && $0.id == t.id }, "text search")
        XCTAssertFalse(byText.items.contains { $0.id == t2.id })
        let byLabel = try await f.admin.search(labelID: label.id)
        XCTAssertEqual(byLabel.items.map(\.id), [t.id])
        let byProject = try await f.admin.search(projectID: p.id, limit: 1)
        XCTAssertEqual(byProject.items.count, 1)
        XCTAssertNotNil(byProject.nextCursor, "paging cursor")
        let page2 = try await f.admin.search(projectID: p.id, limit: 1, cursor: byProject.nextCursor)
        XCTAssertEqual(page2.items.count, 1)
        XCTAssertNotEqual(page2.items.first?.id, byProject.items.first?.id)
        let byProjectName = try await f.admin.search("Suche \(f.suffix)")
        XCTAssertTrue(byProjectName.items.contains { $0.kind == .project && $0.id == p.id })
        let open = try await f.admin.search(projectID: p.id, status: .open)
        XCTAssertEqual(open.items.count, 2)
        let done = try await f.admin.search(projectID: p.id, status: .done)
        XCTAssertTrue(done.items.isEmpty)

        try await f.admin.removeLabel(label.id, fromTask: t.id)
        let after = try await f.admin.labels(taskID: t.id)
        XCTAssertTrue(after.items.isEmpty)
        try await f.admin.deleteLabel(label.id)
        let gone = try await f.admin.labels()
        XCTAssertFalse(gone.items.contains { $0.id == label.id })
    }

    func testCommentsAndActivity() async throws {
        let f = try await fixture()
        let p = try await f.admin.createProject(name: "Kommentare \(f.suffix)")
        let t = try await f.admin.createTask(projectID: p.id, title: "Mit Kommentar")
        let key = UUID()
        let c = try await f.admin.addComment(taskID: t.id, body: "Erster", idempotencyKey: key)
        let again = try await f.admin.addComment(taskID: t.id, body: "Erster", idempotencyKey: key)
        XCTAssertEqual(c.id, again.id, "idempotent retry")
        XCTAssertEqual(c.authorID, f.adminUser.id)
        let edited = try await f.admin.updateComment(taskID: t.id, id: c.id, version: c.version, body: "Geaendert")
        XCTAssertEqual(edited.body, "Geaendert")
        do {
            _ = try await f.admin.updateComment(taskID: t.id, id: c.id, version: c.version, body: "alt")
            XCTFail("stale version accepted")
        } catch { XCTAssertEqual(error as? APIError, .versionConflict) }
        let list = try await f.admin.comments(taskID: t.id)
        XCTAssertEqual(list.map(\.body), ["Geaendert"])
        let act = try await f.admin.activity(taskID: t.id, limit: 1)
        XCTAssertEqual(act.items.count, 1)
        let actAll = try await f.admin.activity(taskID: t.id)
        XCTAssertGreaterThanOrEqual(actAll.items.count, 2)
        XCTAssertTrue(actAll.items.allSatisfy { $0.actorName != nil })
        try await f.admin.deleteComment(taskID: t.id, id: c.id, version: edited.version)
        let empty = try await f.admin.comments(taskID: t.id)
        XCTAssertTrue(empty.isEmpty)
        let atts = try await f.admin.attachments(taskID: t.id)
        XCTAssertTrue(atts.isEmpty)
    }

    func testUserSearchTeamsAndShares() async throws {
        let f = try await fixture()
        // No global directory: a freshly registered user without any relationship is not found.
        let origin = ProcessInfo.processInfo.environment["TODO_LIVE_RP_ORIGIN"] ?? "http://localhost:25173"
        let stranger = try await APIClient(baseURL: f.admin.baseURL).registerWithPasskey(
            token: try await f.admin.createInvitation().token, displayName: "Dora \(f.suffix)", authenticator: VirtualPasskey(origin: origin))
        let none = try await f.admin.searchUsers("Dora \(f.suffix)")
        XCTAssertTrue(none.isEmpty)
        XCTAssertNotEqual(stranger.id, f.bobUser.id)
        do { _ = try await f.admin.searchUsers("B"); XCTFail("1-char query accepted") } catch {}

        let p = try await f.admin.createProject(name: "Geteilt \(f.suffix)")
        let child = try await f.admin.createProject(name: "Kind", parentID: p.id)
        let t = try await f.admin.createTask(projectID: child.id, title: "Sichtbar fuer Team")
        // Not visible to Bob yet.
        let before = try await f.bob.projects()
        XCTAssertFalse(before.contains { $0.id == p.id })

        let team = try await f.admin.createTeam(name: "Team \(f.suffix)")
        XCTAssertEqual(team.founderID, f.adminUser.id)
        let invited = try await f.admin.inviteMember(teamID: team.id, userID: f.bobUser.id)
        XCTAssertFalse(invited.accepted)
        let found = try await f.admin.searchUsers("bob \(f.suffix)")  // case-insensitive, now related via invitation
        XCTAssertEqual(found.map(\.id), [f.bobUser.id])
        let pending = try await f.bob.teamInvitations()
        XCTAssertTrue(pending.contains { $0.teamID == team.id })
        try await f.bob.acceptTeamInvitation(teamID: team.id)
        let members = try await f.admin.members(teamID: team.id)
        XCTAssertEqual(members.filter(\.accepted).count, 2)
        let bobTeams = try await f.bob.teams()
        XCTAssertTrue(bobTeams.contains { $0.id == team.id })

        let grant = try await f.admin.setGrant(projectID: p.id, principalType: .team, principalID: team.id, role: .comment)
        XCTAssertEqual(grant.role, .comment)
        let grantList = try await f.admin.grants(projectID: p.id)
        XCTAssertEqual(grantList.count, 1)
        let after = try await f.bob.projects()
        XCTAssertTrue(after.contains { $0.id == p.id }, "team grant visible")
        XCTAssertTrue(after.contains { $0.id == child.id }, "inherited by sub-project")
        let vis = try await f.bob.visibility(projectID: child.id)
        XCTAssertEqual(vis.role, .comment)
        XCTAssertTrue(vis.inherits)
        XCTAssertFalse(vis.canDelete)
        // comment role: may comment, may not edit.
        _ = try await f.bob.addComment(taskID: t.id, body: "von Bob")
        let bobTask = try await f.bob.tasks(projectID: child.id).first { $0.id == t.id }
        do {
            _ = try await f.bob.updateTask(t.id, version: try XCTUnwrap(bobTask).version, TaskUpdate(title: "x"))
            XCTFail("comment role could edit")
        } catch { XCTAssertTrue(error is APIError) }
        let upgraded = try await f.admin.setGrant(projectID: p.id, principalType: .person, principalID: f.bobUser.id, role: .edit)
        XCTAssertEqual(upgraded.role, .edit)
        let edited = try await f.bob.updateTask(t.id, version: try XCTUnwrap(bobTask).version, TaskUpdate(title: "von Bob editiert"))
        XCTAssertEqual(edited.title, "von Bob editiert")

        let stop = try await f.admin.setInheritance(projectID: child.id, version: child.version, inherits: false)
        XCTAssertFalse(stop.inherits)
        let viewAfterStop = try await f.bob.projects()
        XCTAssertFalse(viewAfterStop.contains { $0.id == child.id }, "inheritance off hides child")

        try await f.admin.removeGrant(projectID: p.id, grantID: upgraded.id)
        try await f.admin.removeGrant(projectID: p.id, grantID: grant.id)
        let final = try await f.bob.projects()
        XCTAssertFalse(final.contains { $0.id == p.id })
        try await f.admin.removeMember(teamID: team.id, userID: f.bobUser.id)
        let left = try await f.bob.teams()
        XCTAssertFalse(left.contains { $0.id == team.id })
    }

    func testSyncChangesAndMutations() async throws {
        let f = try await fixture()
        let start = try await f.admin.syncAll()
        var cursor = start.cursor

        let pid = UUID()
        let created = try await f.admin.applyMutation(SyncMutation(type: .projectCreate, id: pid, name: "Sync \(f.suffix)"))
        XCTAssertTrue(created.created)
        let tid = UUID()
        let mid = UUID()
        let taskCreate = SyncMutation(mutationID: mid, type: .taskCreate, id: tid, projectID: pid, title: "Offline erfasst")
        let t1 = try await f.admin.applyMutation(taskCreate)
        XCTAssertTrue(t1.created)
        let replay = try await f.admin.applyMutation(taskCreate)
        // Replay returns the stored status and body (201 again, header Idempotent-Replay), not a second entity.
        XCTAssertEqual(replay.task, t1.task)
        XCTAssertEqual(replay.cursor, t1.cursor)
        do {
            _ = try await f.admin.applyMutation(SyncMutation(mutationID: mid, type: .taskCreate, id: UUID(), projectID: pid, title: "anderer Inhalt"))
            XCTFail("mutation id reuse accepted")
        } catch { XCTAssertEqual(error as? APIError, .conflict(reason: "mutation_id_reused")) }

        let upd = try await f.admin.applyMutation(
            SyncMutation(type: .taskUpdate, id: tid, version: try XCTUnwrap(t1.task).version, title: "Umbenannt", status: "done"))
        XCTAssertEqual(upd.task?.title, "Umbenannt")
        XCTAssertTrue(upd.task?.isDone == true)
        do {
            _ = try await f.admin.applyMutation(SyncMutation(type: .taskUpdate, id: tid, version: try XCTUnwrap(t1.task).version, title: "stale"))
            XCTFail("stale accepted")
        } catch { XCTAssertEqual(error as? APIError, .versionConflict) }

        let delta = try await f.admin.syncAll(from: cursor)
        cursor = delta.cursor
        XCTAssertTrue(delta.changes.contains { $0.entityType == .project && $0.entityID == pid && $0.kind == .upsert })
        let taskChange = delta.changes.last { $0.entityType == .task && $0.entityID == tid }
        XCTAssertEqual(taskChange?.task?.title, "Umbenannt")
        XCTAssertEqual(taskChange?.kind, .upsert)
        XCTAssertEqual(delta.changes.map(\.seq), delta.changes.map(\.seq).sorted())

        let del = try await f.admin.applyMutation(SyncMutation(type: .taskDelete, id: tid, version: upd.task?.version))
        XCTAssertTrue(del.deleted)
        let after = try await f.admin.syncAll(from: cursor)
        XCTAssertTrue(after.changes.contains { $0.entityID == tid && $0.kind == .delete })
        let empty = try await f.admin.syncChanges(cursor: after.cursor)
        XCTAssertTrue(empty.changes.isEmpty)
        XCTAssertFalse(empty.hasMore)

        // Paging: small page size must still drain everything.
        let paged = try await f.admin.syncAll(from: "c0", pageSize: 2)
        let full = try await f.admin.syncAll()
        XCTAssertEqual(paged.changes.map(\.seq), full.changes.map(\.seq))

        do { _ = try await f.admin.syncChanges(cursor: "garbage"); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .invalidInput(reason: "invalid_cursor")) }
        do { _ = try await f.admin.syncChanges(cursor: "c999999999"); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .conflict(reason: "cursor_ahead")) }

        // Bob does not see admin's private project in his feed.
        let bobFeed = try await f.bob.syncAll()
        XCTAssertFalse(bobFeed.changes.contains { $0.entityID == pid })
    }

    /// Seeds demo data for the user "Alice" and writes `{"token":...}` to `TODO_LIVE_SEED_OUT` (used to launch the app
    /// in the simulator without passkey hardware, see docs/STATUS.md). Skipped unless that variable is set.
    func testSeedDemoData() async throws {
        guard let out = ProcessInfo.processInfo.environment["TODO_LIVE_SEED_OUT"] else { throw XCTSkip("TODO_LIVE_SEED_OUT not set") }
        let f = try await fixture()
        let a = f.admin
        let cal = Calendar.current
        let now = Date()
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
        let nextWeek = cal.date(byAdding: .day, value: 6, to: now)!
        let haus = try await a.createProject(name: "Umzug")
        let kueche = try await a.createProject(name: "Kueche", parentID: haus.id)
        let arbeit = try await a.createProject(name: "Website-Relaunch")
        let blocker = try await a.createLabel(name: "dringend")
        _ = try await a.createLabel(name: "zuhause")
        let t1 = try await a.createTask(projectID: kueche.id, title: "Angebote fuer Arbeitsplatte einholen", description: "Mindestens drei Anbieter vergleichen.")
        let t2 = try await a.createTask(projectID: haus.id, title: "Umzugswagen reservieren")
        let t3 = try await a.createTask(projectID: arbeit.id, title: "Design-Review vorbereiten")
        let t4 = try await a.createTask(projectID: arbeit.id, title: "Texte fuer Startseite freigeben")
        _ = try await a.setPlanning(taskID: t1.id, PlanningData(dueAt: now.addingTimeInterval(120), plannedAt: now, priority: 3, reminders: [now.addingTimeInterval(60)]))
        _ = try await a.setPlanning(taskID: t2.id, PlanningData(dueAt: now.addingTimeInterval(300), priority: 2, recurrence: RecurrenceRule(frequency: .weekly)))
        _ = try await a.setPlanning(taskID: t3.id, PlanningData(dueAt: tomorrow, priority: 1))
        _ = try await a.setPlanning(taskID: t4.id, PlanningData(dueAt: nextWeek))
        try await a.addLabel(blocker.id, toTask: t1.id)
        _ = try await a.addComment(taskID: t1.id, body: "Anbieter A hat 1.890 Euro genannt.")
        _ = try await a.addComment(taskID: t1.id, body: "Anbieter B meldet sich bis Freitag.")
        // More variety for UI screenshots: overdue, later this week, priorities, labels, a finished task, an inbox-like project.
        let eingang = try await a.createProject(name: "Eingang")
        let sport = try await a.createProject(name: "Sport")
        let privat = try await a.createLabel(name: "privat")
        let e1 = try await a.createTask(projectID: eingang.id, title: "Zahnarzttermin vereinbaren", description: "Montags nach 14 Uhr.")
        let e2 = try await a.createTask(projectID: eingang.id, title: "Geburtstagsgeschenk fuer Mia besorgen")
        let e3 = try await a.createTask(projectID: sport.id, title: "Laufschuhe zurueckschicken")
        let e4 = try await a.createTask(projectID: arbeit.id, title: "Rechnung Hosting pruefen")
        let e5 = try await a.createTask(projectID: kueche.id, title: "Fliesen aussuchen")
        let e6 = try await a.createTask(projectID: sport.id, title: "Yoga-Kurs buchen")
        let day = { (n: Int, hour: Int) -> Date in cal.date(bySettingHour: hour, minute: 0, second: 0, of: cal.date(byAdding: .day, value: n, to: now)!)! }
        _ = try await a.setPlanning(taskID: e1.id, PlanningData(dueAt: day(-2, 10), priority: 3))
        _ = try await a.setPlanning(taskID: e3.id, PlanningData(dueAt: day(-1, 9), priority: 0))
        _ = try await a.setPlanning(taskID: e4.id, PlanningData(dueAt: day(2, 14), priority: 2))
        _ = try await a.setPlanning(taskID: e5.id, PlanningData(dueAt: day(3, 11), priority: 1))
        _ = try await a.setPlanning(taskID: e6.id, PlanningData(dueAt: day(1, 18), priority: 0))
        _ = try await a.setPlanning(taskID: e2.id, PlanningData(dueAt: day(0, 20), priority: 1))
        try await a.addLabel(privat.id, toTask: e2.id)
        try await a.addLabel(privat.id, toTask: e3.id)
        try await a.addLabel(blocker.id, toTask: e1.id)
        let done = try await a.createTask(projectID: eingang.id, title: "Paket abholen")
        _ = try await a.updateTask(done.id, version: done.version, TaskUpdate(status: .done))
        let team = try await a.createTeam(name: "Haushalt")
        _ = try await a.inviteMember(teamID: team.id, userID: f.bobUser.id)
        try await f.bob.acceptTeamInvitation(teamID: team.id)
        _ = try await a.setGrant(projectID: haus.id, principalType: .team, principalID: team.id, role: .edit)
        let token = try XCTUnwrap(try f.adminStore.load())
        try JSONSerialization.data(withJSONObject: ["token": token, "displayName": f.adminUser.displayName]).write(to: URL(fileURLWithPath: out))
    }
}
