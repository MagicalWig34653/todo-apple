import Foundation
import CryptoKit
@testable import TodoRunner

/// Human-side REST client plus a virtual passkey for the live end-to-end tests against a real backend.
/// Nothing here is a fake of the server: it only plays the role of the person using the app.
/// Needs a fresh backend whose bootstrap token is still open (RUNNER_LIVE_BASE_URL, RUNNER_LIVE_BOOTSTRAP_TOKEN).
struct LiveBackend: Sendable {
    let baseURL: URL
    var session: String?

    static var configured: Bool { ProcessInfo.processInfo.environment["RUNNER_LIVE_BASE_URL"] != nil }

    static func fromEnvironment() -> URL {
        URL(string: ProcessInfo.processInfo.environment["RUNNER_LIVE_BASE_URL"] ?? "http://127.0.0.1:28711")!
    }

    struct HTTPFailure: Error, CustomStringConvertible {
        var status: Int; var body: String
        var description: String { "HTTP \(status): \(body)" }
    }

    @discardableResult
    func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let session { request.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        guard (200..<300).contains(status) else { throw HTTPFailure(status: status, body: String(decoding: data, as: UTF8.self)) }
        if data.isEmpty { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Registers a user with the bootstrap or an invitation token and a virtual ES256 passkey; returns a client with a session.
    static func register(baseURL: URL, token: String, displayName: String) async throws -> LiveBackend {
        let origin = ProcessInfo.processInfo.environment["RUNNER_LIVE_RP_ORIGIN"] ?? "http://localhost:25173"
        let anonymous = LiveBackend(baseURL: baseURL)
        let begin = try await anonymous.call("POST", "/v1/auth/register/begin", ["token": token, "displayName": displayName])
        let options = begin["options"] as! [String: Any]
        let challenge = options["challenge"] as! String
        let rpID = (options["rp"] as! [String: Any])["id"] as! String
        let key = P256.Signing.PrivateKey()
        let credentialID = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let raw = [UInt8](key.publicKey.x963Representation)
        let cose: [UInt8] = [0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20] + raw[1..<33] + [0x22, 0x58, 0x20] + raw[33..<65]
        var authData = [UInt8](SHA256.hash(data: Data(rpID.utf8)))
        authData += [0x45, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 16)
        authData += [UInt8(credentialID.count >> 8), UInt8(credentialID.count & 0xff)] + [UInt8](credentialID) + cose
        var cbor: [UInt8] = [0xA3, 0x63] + Array("fmt".utf8) + [0x64] + Array("none".utf8) + [0x67] + Array("attStmt".utf8)
        cbor += [0xA0, 0x68] + Array("authData".utf8) + [0x59, UInt8(authData.count >> 8), UInt8(authData.count & 0xff)] + authData
        let clientData = Data(#"{"type":"webauthn.create","challenge":"\#(challenge)","origin":"\#(origin)","crossOrigin":false}"#.utf8)
        let id = credentialID.b64url
        let finish = try await anonymous.call("POST", "/v1/auth/register/finish", [
            "challengeID": begin["challengeID"] as! String,
            "credential": ["id": id, "rawId": id, "type": "public-key",
                           "response": ["clientDataJSON": clientData.b64url, "attestationObject": Data(cbor).b64url]],
        ])
        var client = anonymous
        client.session = finish["token"] as? String
        return client
    }
}

extension Data {
    var b64url: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One end-to-end scenario world: account, project, task, paired device, binding, approved folder.
struct LiveWorld {
    let human: LiveBackend
    let projectID: String
    let deviceToken: DeviceToken
    let bindingID: String
    let repositoryKey: UUID
    let server: URLSessionRunnerServer
    let fixture: Fixture
    let runnerHome: URL

    static func make(fixture f: Fixture, admin: LiveBackend) async throws -> LiveWorld {
        let project = try await admin.call("POST", "/v1/projects", ["name": "Runner E2E \(UUID().uuidString.prefix(6))"])
        let projectID = project["id"] as! String
        let pairing = try await admin.call("POST", "/v1/agents/devices", ["label": "Live test Mac"])
        let device = try await URLSessionRunnerServer.pair(baseURL: admin.baseURL, code: pairing["code"] as! String)
        let key = try f.allowlist.approve(folder: f.repo)
        let binding = try await admin.call("POST", "/v1/agents/bindings", [
            "projectID": projectID, "deviceID": device.deviceID.uuidString.lowercased(),
            "repositoryKey": key.uuidString.lowercased(), "label": "scratch"])
        return LiveWorld(human: admin, projectID: projectID, deviceToken: device, bindingID: binding["id"] as! String,
                         repositoryKey: key, server: URLSessionRunnerServer(baseURL: admin.baseURL, token: device.token),
                         fixture: f, runnerHome: f.state)
    }

    /// Creates a task and releases a job for it; returns (taskID, jobID).
    func release(title: String, description: String = "", mode: JobMode, scope: String) async throws -> (task: String, job: String) {
        let task = try await human.call("POST", "/v1/tasks", ["projectID": projectID, "title": title, "description": description])
        let jobID = UUID().uuidString.lowercased()
        try await human.call("POST", "/v1/agents/jobs", [
            "id": jobID, "taskID": task["id"] as! String, "bindingID": bindingID,
            "taskRevision": task["version"] as! Int, "mode": mode.rawValue, "scope": scope])
        return (task["id"] as! String, jobID)
    }

    func jobDetail(_ id: String) async throws -> [String: Any] { try await human.call("GET", "/v1/agents/jobs/\(id)") }
    func jobState(_ id: String) async throws -> String { ((try await jobDetail(id))["job"] as! [String: Any])["state"] as! String }
}
