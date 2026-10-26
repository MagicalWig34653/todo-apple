import Foundation
import Testing
@testable import TodoRunner

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data?) throws -> (Int, Data))?
    nonisolated(unsafe) static var seen: [(URLRequest, Data?)] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body: Data?
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            body = data
        } else { body = request.httpBody }
        Self.seen.append((request, body))
        do {
            let (status, data) = try Self.handler!(request, body)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct RunnerServerTests {
    let base = URL(string: "https://todo.example/")!
    func server(_ handler: @escaping @Sendable (URLRequest, Data?) throws -> (Int, Data)) -> URLSessionRunnerServer {
        MockURLProtocol.handler = handler; MockURLProtocol.seen = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSessionRunnerServer(baseURL: base, token: "secret-token", session: URLSession(configuration: configuration))
    }
    let runJSON = #"""
    {"id":"11111111-1111-1111-1111-111111111111","generation":2,"leaseUntil":"2026-10-26T12:00:00.123Z",
     "job":{"id":"22222222-2222-2222-2222-222222222222","taskID":"33333333-3333-3333-3333-333333333333","projectID":"44444444-4444-4444-4444-444444444444","bindingID":"55555555-5555-5555-5555-555555555555","requestedBy":"66666666-6666-6666-6666-666666666666","taskRevision":4,"mode":"implement","scope":"s","state":"waiting_for_answer","progress":""},
     "checkpoint":{"contextRevision":4,"sessionReference":"abc","nextStep":"n"}}
    """#

    @Test func pairSendsCodeWithoutAuthorizationAndDecodesToken() async throws {
        _ = server { _, _ in (200, Data(#"{"deviceID":"11111111-1111-1111-1111-111111111111","token":"tok"}"#.utf8)) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockURLProtocol.self]
        let token = try await URLSessionRunnerServer.pair(baseURL: base, code: "ABC123", session: URLSession(configuration: configuration))
        #expect(token.token == "tok")
        let (request, body) = try #require(MockURLProtocol.seen.last)
        #expect(request.url?.path == "/v1/runner/pair" && request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(try JSONSerialization.jsonObject(with: body!) as? [String: String] == ["code": "ABC123"])
    }

    @Test func heartbeatUsesBearerPathAndGenerationAndDecodesDates() async throws {
        let s = server { _, _ in (200, Data(runJSON.utf8)) }
        let run = try await s.heartbeat(runID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, generation: 2)
        #expect(run.generation == 2 && run.job.state == .waitingForAnswer && run.checkpoint?.nextStep == "n")
        #expect(abs(run.leaseUntil.timeIntervalSince1970 - 1793016000.123) < 0.01)
        let (request, body) = try #require(MockURLProtocol.seen.last)
        #expect(request.url?.path == "/v1/runner/runs/11111111-1111-1111-1111-111111111111/heartbeat")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(try JSONSerialization.jsonObject(with: body!) as? [String: Int] == ["generation": 2])
    }

    @Test func datesWithoutFractionalSecondsDecode() async throws {
        let s = server { _, _ in (200, Data(runJSON.replacingOccurrences(of: ".123Z", with: "Z").utf8)) }
        let runs = try await {
            MockURLProtocol.handler = { _, _ in (200, Data("[\(runJSON.replacingOccurrences(of: ".123Z", with: "Z"))]".utf8)) }
            return try await s.runs()
        }()
        #expect(runs.count == 1 && runs[0].leaseUntil.timeIntervalSince1970 == 1793016000)
    }

    @Test func writeEndpointsHaveContractShapes() async throws {
        let s = server { _, _ in (200, Data(runJSON.utf8)) }
        let id = UUID()
        _ = try await s.checkpoint(runID: id, generation: 3, checkpoint: Checkpoint(contextRevision: 4, sessionReference: "sid", nextStep: "next"))
        _ = try await s.question(runID: id, generation: 3, prompt: "P?", options: ["a"])
        _ = try await s.submit(runID: id, generation: 3, result: RunResult(summary: "S", limitations: ["L"]))
        _ = try await s.reconcile(runID: id, generation: 3, observation: .paused)
        _ = try await s.progress(runID: id, generation: 3, text: "50%")
        _ = try await s.claim(jobID: id)
        let bodies = MockURLProtocol.seen.map { ($0.0.url!.lastPathComponent, $0.1.flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSDictionary }) }
        #expect(bodies[0].1 == ["generation": 3, "checkpoint": ["contextRevision": 4, "sessionReference": "sid", "nextStep": "next"]] as NSDictionary)
        #expect(bodies[1].1 == ["generation": 3, "prompt": "P?", "options": ["a"]] as NSDictionary)
        #expect(bodies[2].1 == ["generation": 3, "result": ["summary": "S", "references": [], "checks": [], "limitations": ["L"]]] as NSDictionary)
        #expect(bodies[3].1 == ["generation": 3, "observation": "paused"] as NSDictionary)
        #expect(bodies[4].1 == ["generation": 3, "progress": "50%"] as NSDictionary)
        #expect(bodies[5].0 == "claim" && bodies[5].1 == nil)
    }

    @Test func statusCodesMapToErrors() async throws {
        let cases: [(Int, RunnerServerError)] = [(400, .badRequest("r")), (401, .unauthorized), (404, .notFound),
                                                 (409, .conflict("r")), (410, .gone("r")), (500, .http(500, "r"))]
        for (status, expected) in cases {
            let s = server { _, _ in (status, Data(#"{"error":true,"reason":"r"}"#.utf8)) }
            await #expect(throws: expected) { try await s.heartbeat(runID: UUID(), generation: 1) }
        }
        #expect(RunnerServerError.gone("").isOwnershipLoss && RunnerServerError.conflict("").isOwnershipLoss && !RunnerServerError.unauthorized.isOwnershipLoss)
    }

    @Test func transportAndGarbageResponsesAreErrors() async throws {
        var s = server { _, _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: RunnerServerError.self) { try await s.jobs() }
        s = server { _, _ in (200, Data("not json".utf8)) }
        await #expect(throws: RunnerServerError.invalidResponse) { try await s.jobs() }
    }

    @Test func readEndpointsUseGet() async throws {
        let s = server { request, _ in
            request.url!.path.hasSuffix("/bindings") ? (200, Data(#"[{"id":"11111111-1111-1111-1111-111111111111","projectID":"11111111-1111-1111-1111-111111111111","deviceID":"11111111-1111-1111-1111-111111111111","repositoryKey":"11111111-1111-1111-1111-111111111111","label":"L"}]"#.utf8)) : (200, Data("[]".utf8))
        }
        #expect(try await s.bindings().first?.label == "L")
        #expect(try await s.jobs().isEmpty)
        #expect(MockURLProtocol.seen.allSatisfy { $0.0.httpMethod == "GET" && $0.1 == nil })
    }
}
