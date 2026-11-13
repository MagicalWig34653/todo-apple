import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// DTOs mirror contracts/voice.yaml (main repository), section /v1/runner/voice.

public struct VoiceAudioInfo: Codable, Sendable, Equatable {
    public var mediaType: String
    public var size: Int
    public var checksum: String
    public init(mediaType: String, size: Int, checksum: String) { self.mediaType = mediaType; self.size = size; self.checksum = checksum }
}

public struct VoiceJob: Codable, Sendable, Equatable {
    public var id: UUID
    public var state: String
    public var generation: Int
    public var messageID: UUID
    public var attachmentID: UUID
    public var leaseUntil: Date?
    public var audio: VoiceAudioInfo?
    public init(id: UUID = UUID(), state: String = "claimed", generation: Int = 1, messageID: UUID = UUID(), attachmentID: UUID = UUID(),
                leaseUntil: Date? = nil, audio: VoiceAudioInfo? = nil) {
        self.id = id; self.state = state; self.generation = generation; self.messageID = messageID; self.attachmentID = attachmentID
        self.leaseUntil = leaseUntil; self.audio = audio
    }
}

/// `/v1/runner/voice/*` with the device token. Every call after the claim carries the generation.
public protocol VoiceServer: Sendable {
    /// Reports the capabilities; returns the effective ones (reported minus the ones the owner switched off).
    func heartbeat(capabilities: [String]) async throws -> [String]
    /// The oldest claimable job, or nil (204).
    func claimNext() async throws -> VoiceJob?
    func heartbeat(jobID: UUID, generation: Int) async throws -> VoiceJob
    func downloadAudio(jobID: UUID, generation: Int) async throws -> Data
    func uploadReplyAudio(jobID: UUID, generation: Int, audio: Data, mediaType: String) async throws
    func result(jobID: UUID, generation: Int, transcript: String?, replyText: String?, errorCode: String?) async throws
}

public struct URLSessionVoiceServer: VoiceServer {
    public let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL; self.token = token; self.session = session
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:], timeout: TimeInterval = 30) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func json(_ method: String, _ path: String, _ body: some Encodable) throws -> URLRequest {
        var request = request(method, path)
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private struct Failure: Decodable { var reason: String? }

    private func perform(_ request: URLRequest, upload: Data? = nil) async throws -> (Data, Int) {
        let data: Data, response: URLResponse
        do {
            if let upload { (data, response) = try await session.upload(for: request, from: upload) }
            else { (data, response) = try await session.data(for: request) }
        } catch { throw RunnerServerError.transport(String(describing: error)) }
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
        return (data, http.statusCode)
    }

    private func decode<R: Decodable>(_ data: Data) throws -> R {
        do { return try URLSessionRunnerServer.makeDecoder().decode(R.self, from: data) } catch { throw RunnerServerError.invalidResponse }
    }

    public func heartbeat(capabilities: [String]) async throws -> [String] {
        struct Body: Encodable { var capabilities: [String] }
        struct Reply: Decodable { var capabilities: [String] }
        let (data, _) = try await perform(json("POST", "/v1/runner/voice/heartbeat", Body(capabilities: capabilities)))
        let reply: Reply = try decode(data)
        return reply.capabilities
    }

    public func claimNext() async throws -> VoiceJob? {
        var request = request("POST", "/v1/runner/voice/claim")
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await perform(request)
        return status == 204 ? nil : try decode(data)
    }

    public func heartbeat(jobID: UUID, generation: Int) async throws -> VoiceJob {
        struct Body: Encodable { var generation: Int }
        let (data, _) = try await perform(json("POST", "/v1/runner/voice/jobs/\(jobID.uuidString.lowercased())/heartbeat", Body(generation: generation)))
        return try decode(data)
    }

    public func downloadAudio(jobID: UUID, generation: Int) async throws -> Data {
        let (data, _) = try await perform(request("GET", "/v1/runner/voice/jobs/\(jobID.uuidString.lowercased())/audio",
                                                  query: ["generation": String(generation)], timeout: 120))
        return data
    }

    public func uploadReplyAudio(jobID: UUID, generation: Int, audio: Data, mediaType: String) async throws {
        var request = request("PUT", "/v1/runner/voice/jobs/\(jobID.uuidString.lowercased())/reply-audio",
                              query: ["generation": String(generation)], timeout: 120)
        request.setValue(mediaType, forHTTPHeaderField: "Content-Type")
        _ = try await perform(request, upload: audio)
    }

    public func result(jobID: UUID, generation: Int, transcript: String?, replyText: String?, errorCode: String?) async throws {
        struct Body: Encodable { var generation: Int; var transcript: String?; var replyText: String?; var errorCode: String? }
        _ = try await perform(json("POST", "/v1/runner/voice/jobs/\(jobID.uuidString.lowercased())/result",
                                   Body(generation: generation, transcript: transcript, replyText: replyText, errorCode: errorCode)))
    }
}
