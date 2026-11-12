import Foundation

// MARK: Acceptance criteria (contracts/collaboration.yaml, /v1/tasks/{taskID}/acceptance-criteria)

private struct CriterionCreateBody: Encodable { let text: String }

/// Partial update; `completed` sets the target state explicitly (no blind toggle on a retry).
private struct CriterionUpdateBody: Encodable {
    let version: Int
    let text: String?
    let completed: Bool?
    enum CodingKeys: String, CodingKey { case version, text, completed }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(completed, forKey: .completed)
    }
}

private struct CriterionVersionBody: Encodable { let version: Int }

extension Array where Element == TaskCriterion {
    /// The list with `criterion` in place of the entry with the same id (appended when unknown).
    public func replacing(_ criterion: TaskCriterion) -> [TaskCriterion] {
        guard let i = firstIndex(where: { $0.id == criterion.id }) else { return self + [criterion] }
        var copy = self
        copy[i] = criterion
        return copy
    }
}

extension APIClient {
    private func criteriaPath(_ taskID: UUID) -> String { "v1/tasks/\(taskID.uuidString)/acceptance-criteria" }

    public func criteria(taskID: UUID) async throws -> [TaskCriterion] {
        try await send("GET", criteriaPath(taskID))
    }

    /// Blank text is rejected before anything is sent (`invalidInput(text_required)`).
    public func createCriterion(taskID: UUID, text: String, idempotencyKey: UUID = UUID()) async throws -> TaskCriterion {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw APIError.invalidInput(reason: "text_required") }
        return try await send(
            "POST", criteriaPath(taskID), body: CriterionCreateBody(text: t),
            headers: ["Idempotency-Key": idempotencyKey.uuidString])
    }

    /// Changes the text and/or the completed state. A stale `version` throws the conflict error.
    public func updateCriterion(taskID: UUID, id: UUID, version: Int, text: String? = nil, completed: Bool? = nil) async throws -> TaskCriterion {
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t, t.isEmpty { throw APIError.invalidInput(reason: "text_required") }
        return try await send(
            "PATCH", "\(criteriaPath(taskID))/\(id.uuidString)", body: CriterionUpdateBody(version: version, text: t, completed: completed))
    }

    public func deleteCriterion(taskID: UUID, id: UUID, version: Int) async throws {
        try await sendNoContent("DELETE", "\(criteriaPath(taskID))/\(id.uuidString)", body: CriterionVersionBody(version: version))
    }
}
