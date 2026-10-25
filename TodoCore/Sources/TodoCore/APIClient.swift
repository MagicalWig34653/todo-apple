import Foundation

public struct HealthResponse: Codable, Sendable, Equatable {
    public let status: String
}

/// Minimal API client; shares the contract in the main repo (`contracts/openapi.yaml`).
public struct APIClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func ready() async throws -> HealthResponse {
        let (data, response) = try await session.data(from: baseURL.appending(path: "health/ready"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }
}
