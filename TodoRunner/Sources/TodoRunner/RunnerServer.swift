import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RunnerServerError: Error, Equatable, Sendable {
    case badRequest(String)
    case unauthorized
    case notFound
    /// 409: stale generation, wrong state or claim conflict.
    case conflict(String)
    /// 410: lease lost, run finished or local stop required.
    case gone(String)
    case http(Int, String)
    case transport(String)
    case invalidResponse

    /// The caller no longer owns the run; it must stop publishing for it.
    public var isOwnershipLoss: Bool {
        switch self { case .conflict, .gone: true; default: false }
    }
}

/// The authenticated REST runner API (contracts/agents.yaml). Every write
/// carries the generation the runner believes it owns; no method takes a path.
public protocol RunnerServer: Sendable {
    func bindings() async throws -> [Binding]
    func jobs() async throws -> [Job]
    func detail(jobID: UUID) async throws -> JobDetail
    func claim(jobID: UUID) async throws -> Run
    func runs() async throws -> [Run]
    func heartbeat(runID: UUID, generation: Int) async throws -> Run
    func progress(runID: UUID, generation: Int, text: String) async throws -> Run
    func checkpoint(runID: UUID, generation: Int, checkpoint: Checkpoint) async throws -> Run
    func question(runID: UUID, generation: Int, prompt: String, options: [String]) async throws -> Run
    func resume(runID: UUID, generation: Int) async throws -> Run
    func submit(runID: UUID, generation: Int, result: RunResult) async throws -> Run
    func stop(runID: UUID, generation: Int) async throws -> Run
    func fail(runID: UUID, generation: Int) async throws -> Run
    func reconcile(runID: UUID, generation: Int, observation: ReconcileObservation) async throws -> Run
}

public struct URLSessionRunnerServer: RunnerServer {
    public let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL; self.token = token; self.session = session
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid date \(text)"))
        }
        return decoder
    }

    /// Exchanges the one-time pairing code for a device token (no authentication).
    public static func pair(baseURL: URL, code: String, session: URLSession = .shared) async throws -> DeviceToken {
        try await perform(session: session, baseURL: baseURL, token: nil, method: "POST",
                          path: "/v1/runner/pair", body: ["code": code])
    }

    private struct Failure: Decodable { var reason: String? }
    private struct Empty: Encodable {}
    private struct Gen: Encodable { var generation: Int }

    private func send<R: Decodable>(_ method: String, _ path: String) async throws -> R {
        try await Self.perform(session: session, baseURL: baseURL, token: token, method: method, path: path, body: Optional<Empty>.none)
    }

    private func send<R: Decodable>(_ method: String, _ path: String, body: some Encodable) async throws -> R {
        try await Self.perform(session: session, baseURL: baseURL, token: token, method: method, path: path, body: body)
    }

    private static func perform<R: Decodable>(session: URLSession, baseURL: URL, token: String?, method: String,
                                              path: String, body: (some Encodable)?) async throws -> R {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw RunnerServerError.transport(String(describing: error)) }
        guard let http = response as? HTTPURLResponse else { throw RunnerServerError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let reason = (try? JSONDecoder().decode(Failure.self, from: data))?.reason ?? ""
            switch http.statusCode {
            case 400: throw RunnerServerError.badRequest(reason)
            case 401: throw RunnerServerError.unauthorized
            case 404: throw RunnerServerError.notFound
            case 409: throw RunnerServerError.conflict(reason)
            case 410: throw RunnerServerError.gone(reason)
            default: throw RunnerServerError.http(http.statusCode, reason)
            }
        }
        do { return try makeDecoder().decode(R.self, from: data) }
        catch { throw RunnerServerError.invalidResponse }
    }

    private func write<B: Encodable>(_ runID: UUID, _ action: String, _ body: B) async throws -> Run {
        try await send("POST", "/v1/runner/runs/\(runID.uuidString.lowercased())/\(action)", body: body)
    }

    public func bindings() async throws -> [Binding] { try await send("GET", "/v1/runner/bindings") }
    public func jobs() async throws -> [Job] { try await send("GET", "/v1/runner/jobs") }
    public func detail(jobID: UUID) async throws -> JobDetail {
        try await send("GET", "/v1/runner/jobs/\(jobID.uuidString.lowercased())")
    }
    public func claim(jobID: UUID) async throws -> Run {
        try await send("POST", "/v1/runner/jobs/\(jobID.uuidString.lowercased())/claim")
    }
    public func runs() async throws -> [Run] { try await send("GET", "/v1/runner/runs") }
    public func heartbeat(runID: UUID, generation: Int) async throws -> Run {
        try await write(runID, "heartbeat", Gen(generation: generation))
    }
    public func progress(runID: UUID, generation: Int, text: String) async throws -> Run {
        struct Body: Encodable { var generation: Int; var progress: String }
        return try await write(runID, "progress", Body(generation: generation, progress: text))
    }
    public func checkpoint(runID: UUID, generation: Int, checkpoint: Checkpoint) async throws -> Run {
        struct Body: Encodable { var generation: Int; var checkpoint: Checkpoint }
        return try await write(runID, "checkpoint", Body(generation: generation, checkpoint: checkpoint))
    }
    public func question(runID: UUID, generation: Int, prompt: String, options: [String]) async throws -> Run {
        struct Body: Encodable { var generation: Int; var prompt: String; var options: [String] }
        return try await write(runID, "question", Body(generation: generation, prompt: prompt, options: options))
    }
    public func resume(runID: UUID, generation: Int) async throws -> Run {
        try await write(runID, "resume", Gen(generation: generation))
    }
    public func submit(runID: UUID, generation: Int, result: RunResult) async throws -> Run {
        struct Body: Encodable { var generation: Int; var result: RunResult }
        return try await write(runID, "submit", Body(generation: generation, result: result))
    }
    public func stop(runID: UUID, generation: Int) async throws -> Run {
        try await write(runID, "stop", Gen(generation: generation))
    }
    public func fail(runID: UUID, generation: Int) async throws -> Run {
        try await write(runID, "fail", Gen(generation: generation))
    }
    public func reconcile(runID: UUID, generation: Int, observation: ReconcileObservation) async throws -> Run {
        struct Body: Encodable { var generation: Int; var observation: ReconcileObservation }
        return try await write(runID, "reconcile", Body(generation: generation, observation: observation))
    }
}
