import Foundation
import XCTest

@testable import TodoCore

/// Opt-in seed of `scripts/ui-tests-accounts.sh` (card 346B7A6F): two accounts with passwords on server A and a third one
/// on server B, each with data nobody else may ever see. Needs fresh databases and `PASSWORD_LOGIN_ENABLED=true`.
final class LiveAccountSwitchSeed: XCTestCase {
    private struct Account: Encodable { let username: String; let password: String; let userID: UUID; let token: String }

    func testSeedAccounts() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["TODO_LIVE_ACCOUNTS_OUT"], let a = env["TODO_LIVE_BASE_URL"].flatMap(URL.init(string:)),
              let b = env["TODO_LIVE_SECOND_URL"].flatMap(URL.init(string:)),
              let originA = env["TODO_LIVE_RP_ORIGIN"], let originB = env["TODO_LIVE_SECOND_RP_ORIGIN"]
        else { throw XCTSkip("TODO_LIVE_ACCOUNTS_OUT / _BASE_URL / _SECOND_URL not set") }
        let password = "local-test-password-1"

        func register(_ url: URL, _ origin: String, _ token: String, _ name: String, project: String, tasks: [String]) async throws -> (APIClient, Account) {
            let store = InMemoryTokenStore()
            let client = APIClient(baseURL: url, tokenStore: store)
            let user = try await client.registerWithPasskey(token: token, displayName: name, authenticator: VirtualPasskey(origin: origin))
            let username = name.lowercased()
            try await client.sendNoContent("POST", "v1/me/password", body: PasswordLoginBody(username: username, password: password))
            let p = try await client.createProject(name: project)
            for title in tasks {
                let t = try await client.createTask(projectID: p.id, title: title)
                _ = try await client.setPlanning(taskID: t.id, PlanningData(dueAt: Date().addingTimeInterval(600)))
            }
            return (client, Account(username: username, password: password, userID: user.id, token: try XCTUnwrap(store.load())))
        }

        let (admin, anna) = try await register(a, originA, "dev-bootstrap-only", "Anna", project: "Annas Garten",
                                               tasks: ["Annas Rosen schneiden", "Annas Beet jaeten", "Annas Zaun streichen"])
        let invite = try await admin.createInvitation()
        let (_, bert) = try await register(a, originA, invite.token, "Bert", project: "Berts Werkstatt", tasks: ["Berts Regal bauen"])
        let (_, carla) = try await register(b, originB, "dev-bootstrap-only", "Carla", project: "Carlas Kueche",
                                            tasks: ["Carlas Brot backen", "Carlas Messer schleifen"])
        try JSONEncoder().encode(["anna": anna, "bert": bert, "carla": carla]).write(to: URL(fileURLWithPath: out))
    }
}
