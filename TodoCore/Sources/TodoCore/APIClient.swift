import Foundation

public struct HealthResponse: Codable, Sendable, Equatable {
    public let status: String
    /// Informational push state of newer servers (`enabled` = APNs delivery configured); nil on older servers.
    public let push: PushHealth?
}

public struct PushHealth: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let environment: String?
}

/// API client for `/v1` of the Todo backend (contract: `contracts/` in the main repository).
///
/// The session bearer token lives in a `TokenStore` (Keychain in the apps). Cookies are deliberately not
/// used so the server's cookie CSRF checks never apply to native clients.
public struct APIClient: Sendable {
    public let baseURL: URL
    let session: URLSession
    let tokenStore: any TokenStore

    public init(baseURL: URL, session: URLSession = .shared, tokenStore: any TokenStore = InMemoryTokenStore()) {
        self.baseURL = baseURL
        self.session = session
        self.tokenStore = tokenStore
    }

    // MARK: Health and capabilities

    public func ready() async throws -> HealthResponse {
        try await send("GET", "health/ready", auth: false)
    }

    public func capabilities() async throws -> Capabilities {
        try await send("GET", "v1/capabilities", auth: false)
    }

    // MARK: Session

    /// True if a token is stored (it may still be expired; `me()` verifies).
    public func hasStoredSession() -> Bool { ((try? tokenStore.load()) ?? nil) != nil }

    public func me() async throws -> User {
        try await send("GET", "v1/me")
    }

    /// Ends the session server-side (best effort) and always removes the local token.
    public func logout() async throws {
        defer { try? tokenStore.clear() }
        do { try await sendNoContent("POST", "v1/auth/logout") }
        catch APIError.unauthorized { /* already invalid */ }
    }

    /// Secondary login. Throws `APIError.passwordLoginDisabled` without a request if the server does not offer it.
    public func passwordLogin(username: String, password: String) async throws -> User {
        guard try await capabilities().password else { throw APIError.passwordLoginDisabled }
        let response: SessionResponse = try await send(
            "POST", "v1/auth/password/login", body: PasswordLoginBody(username: username, password: password), auth: false)
        return try store(response)
    }

    /// Registers a new account with a bootstrap token (first admin) or an invitation token, creating the first passkey.
    public func registerWithPasskey(
        token: String, displayName: String, passkeyName: String? = nil, authenticator: any PasskeyAuthenticator
    ) async throws -> User {
        let begin: RegisterBeginResponse = try await send(
            "POST", "v1/auth/register/begin", body: RegisterBeginBody(token: token, displayName: displayName), auth: false)
        guard let challenge = Data(base64URLEncoded: begin.options.challenge),
            let userID = Data(base64URLEncoded: begin.options.user.id)
        else { throw APIError.decoding("invalid registration options") }
        let result = try await authenticator.register(
            challenge: challenge, relyingPartyID: begin.options.rp.id, userID: userID, userName: begin.options.user.name)
        let id = result.credentialID.base64URLEncoded
        let body = RegisterFinishBody(
            challengeID: begin.challengeID,
            credential: .init(
                id: id, rawId: id,
                response: .init(
                    clientDataJSON: result.clientDataJSON.base64URLEncoded,
                    attestationObject: result.attestationObject.base64URLEncoded)),
            passkeyName: passkeyName)
        let response: SessionResponse = try await send("POST", "v1/auth/register/finish", body: body, auth: false)
        return try store(response)
    }

    public func loginWithPasskey(authenticator: any PasskeyAuthenticator) async throws -> User {
        let begin: LoginBeginResponse = try await send("POST", "v1/auth/login/begin", auth: false)
        guard let challenge = Data(base64URLEncoded: begin.options.challenge) else {
            throw APIError.decoding("invalid login options")
        }
        let result = try await authenticator.authenticate(challenge: challenge, relyingPartyID: begin.options.rpId)
        let id = result.credentialID.base64URLEncoded
        let body = LoginFinishBody(
            challengeID: begin.challengeID,
            credential: .init(
                id: id, rawId: id,
                response: .init(
                    clientDataJSON: result.clientDataJSON.base64URLEncoded,
                    authenticatorData: result.authenticatorData.base64URLEncoded,
                    signature: result.signature.base64URLEncoded,
                    userHandle: result.userHandle?.base64URLEncoded)))
        let response: SessionResponse = try await send("POST", "v1/auth/login/finish", body: body, auth: false)
        return try store(response)
    }

    /// Admin only: creates a one-time invitation token (valid 7 days).
    public func createInvitation() async throws -> InvitationResponse {
        try await send("POST", "v1/invitations", body: EmptyBody())
    }

    private func store(_ response: SessionResponse) throws -> User {
        do { try tokenStore.save(response.token) } catch { throw APIError.transport("could not store session token") }
        return response.user
    }

    // MARK: Projects

    public func projects() async throws -> [Project] {
        try await send("GET", "v1/projects")
    }

    public func createProject(name: String, parentID: UUID? = nil, description: String? = nil, color: String? = nil) async throws -> Project {
        try await send("POST", "v1/projects", body: CreateProjectBody(name: name, parentID: parentID, description: description, color: color))
    }

    /// Throws `APIError.versionConflict` if `version` is stale.
    public func updateProject(_ id: UUID, version: Int, _ update: ProjectUpdate) async throws -> Project {
        try await send(
            "PATCH", "v1/projects/\(id.uuidString)",
            body: UpdateProjectBody(
                version: version, name: update.name, parentID: update.parentID, moveToRoot: update.moveToRoot,
                description: update.description, color: update.color))
    }

    public func deleteProject(_ id: UUID) async throws {
        try await sendNoContent("DELETE", "v1/projects/\(id.uuidString)")
    }

    // MARK: Tasks

    public func tasks(projectID: UUID? = nil) async throws -> [TodoTask] {
        let query = projectID.map { [URLQueryItem(name: "projectID", value: $0.uuidString)] } ?? []
        return try await send("GET", "v1/tasks", query: query)
    }

    public func createTask(projectID: UUID, title: String, description: String? = nil) async throws -> TodoTask {
        try await send("POST", "v1/tasks", body: CreateTaskBody(projectID: projectID, title: title, description: description))
    }

    /// Throws `APIError.versionConflict` if `version` is stale.
    public func updateTask(_ id: UUID, version: Int, _ update: TaskUpdate) async throws -> TodoTask {
        try await send(
            "PATCH", "v1/tasks/\(id.uuidString)",
            body: UpdateTaskBody(
                version: version, title: update.title, description: update.description,
                status: update.status?.rawValue, projectID: update.projectID))
    }

    public func deleteTask(_ id: UUID) async throws {
        try await sendNoContent("DELETE", "v1/tasks/\(id.uuidString)")
    }

    // MARK: Transport

    private struct EmptyBody: Encodable {}
    private struct ErrorBody: Decodable { let reason: String? }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = plain.date(from: raw) ?? fractional.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(raw)"))
        }
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func makeRequest(
        _ method: String, _ path: String, query: [URLQueryItem], body: (any Encodable)?, auth: Bool,
        headers: [String: String] = [:]
    ) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(AnyEncodable(body))
        } else if method == "POST" || method == "PUT" {
            // The server requires JSON for unsafe methods.
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if auth, let token = try? tokenStore.load() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Like `send` but also returns the HTTP status (for 200 vs 201 on sync mutations).
    func sendWithStatus<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws -> (T, Int) {
        let (data, status) = try await performWithStatus(makeRequest(method, path, query: [], body: body, auth: true))
        do { return (try Self.decoder.decode(T.self, from: data), status) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        try await performWithStatus(request).0
    }

    func performWithStatus(_ request: URLRequest) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw APIError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let reason = (try? Self.decoder.decode(ErrorBody.self, from: data))?.reason
            throw APIError.from(status: http.statusCode, reason: reason)
        }
        return (data, http.statusCode)
    }

    func send<T: Decodable>(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: (any Encodable)? = nil, auth: Bool = true,
        headers: [String: String] = [:]
    ) async throws -> T {
        let data = try await perform(makeRequest(method, path, query: query, body: body, auth: auth, headers: headers))
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    func sendNoContent(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws {
        _ = try await perform(makeRequest(method, path, query: [], body: body, auth: true))
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
}
