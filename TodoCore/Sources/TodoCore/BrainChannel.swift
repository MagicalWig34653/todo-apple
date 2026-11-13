import Foundation

// MARK: Channel #brain (contracts/voice.yaml, ADR 0030)
//
// One channel per account, owner only. Messages: `text`, `voice_in` (the person's recording), `voice_out` (the brain's
// spoken answer) and `status` (system line such as "Brain gerade nur per Text erreichbar."). The server lists newest first.

public struct BrainMessageKind: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }

    public static let text = BrainMessageKind(rawValue: "text")
    public static let voiceIn = BrainMessageKind(rawValue: "voice_in")
    public static let voiceOut = BrainMessageKind(rawValue: "voice_out")
    public static let status = BrainMessageKind(rawValue: "status")
}

public enum BrainAuthor: String, Codable, Sendable { case person, agent }

public struct BrainMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: BrainMessageKind
    /// Unknown future authors decode as `agent` (not the person), so they never show up as "mine".
    public let author: BrainAuthor
    /// Message text, or the transcript of a recording (empty until the runner has transcribed it).
    public let text: String?
    /// Audio attachment (role voice); download through `APIClient.downloadAttachment`.
    public let attachmentID: UUID?
    public let clientUUID: UUID?
    public let createdAt: Date

    public init(id: UUID, kind: BrainMessageKind, author: BrainAuthor, text: String? = nil, attachmentID: UUID? = nil,
                clientUUID: UUID? = nil, createdAt: Date) {
        self.id = id; self.kind = kind; self.author = author; self.text = text; self.attachmentID = attachmentID
        self.clientUUID = clientUUID; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, kind, author, text, attachmentID, clientUUID, createdAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(BrainMessageKind.self, forKey: .kind)
        author = (try? c.decode(BrainAuthor.self, forKey: .author)) ?? .agent
        text = try c.decodeIfPresent(String.self, forKey: .text)
        attachmentID = try c.decodeIfPresent(UUID.self, forKey: .attachmentID)
        clientUUID = try c.decodeIfPresent(UUID.self, forKey: .clientUUID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    public var hasAudio: Bool { attachmentID != nil }
    public var trimmedText: String { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isMine: Bool { author == .person }
}

public struct BrainMessagePage: Codable, Sendable, Equatable {
    public let items: [BrainMessage]
    public let nextCursor: String?
}

/// Thread state of the channel: messages merged from pages (newest first), deduplicated by id.
public struct BrainThread: Sendable, Equatable {
    public private(set) var messages: [BrainMessage] = []
    /// Cursor for the next older page; nil on the last page.
    public private(set) var olderCursor: String?
    public private(set) var loaded = false

    public init() {}

    /// Chronological order for display (oldest first).
    public var chronological: [BrainMessage] { messages.reversed() }
    public var newest: Date? { messages.first?.createdAt }

    /// First page (or a refetch from the top): newer messages are merged into what is shown. The older cursor is kept
    /// once known so a refetch does not throw away pages loaded earlier.
    public mutating func merge(firstPage page: BrainMessagePage) {
        let hadOlder = loaded
        insert(page.items)
        if !hadOlder { olderCursor = page.nextCursor }
        loaded = true
    }

    /// Messages newer than `newest` (the `since` query): merged without touching the older cursor.
    public mutating func merge(newer page: BrainMessagePage) { insert(page.items) }

    public mutating func append(olderPage page: BrainMessagePage) {
        insert(page.items)
        olderCursor = page.nextCursor
    }

    public mutating func add(_ message: BrainMessage) { insert([message]) }

    private mutating func insert(_ items: [BrainMessage]) {
        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for item in items { byID[item.id] = item }
        // Newest first. The server sends `createdAt` with second precision (contract: milliseconds), and the status line
        // of an unreachable brain is written in the same second as the recording it answers: within one second the
        // brain's message counts as the newer one (a person needs longer than a second for the next message).
        messages = byID.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            if $0.author != $1.author { return $0.author == .agent }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    /// A recording the brain has not answered yet: a `voice_in` of the person with no later message of the brain.
    /// The runner fills the transcript and posts the answer (or a status line on failure/expiry) as agent messages,
    /// so "no later agent message" is the processing state the app shows.
    public var processingIDs: Set<UUID> {
        let firstAgent = messages.firstIndex { $0.author == .agent } ?? messages.endIndex
        return Set(messages[..<firstAgent].filter { $0.kind == .voiceIn }.map(\.id))
    }
}

struct PostBrainMessageBody: Encodable {
    let kind: String
    let text: String?
    let attachmentID: UUID?
    let clientUUID: UUID
}

/// Result of posting: `created` is false when the server returned the original of an idempotent repeat (200).
public struct BrainPostResult: Sendable, Equatable {
    public let message: BrainMessage
    public let created: Bool
}

public enum BrainRules {
    public static let maxTextLength = 4000
}

extension APIClient {
    /// `GET /v1/channels/brain/messages`: newest first. `cursor` = `nextCursor` of the previous page (older messages),
    /// `since` = only messages after that time.
    public func brainMessages(limit: Int = 50, cursor: String? = nil, since: Date? = nil) async throws -> BrainMessagePage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let since { query.append(URLQueryItem(name: "since", value: Self.sinceString(since))) }
        return try await send("GET", "v1/channels/brain/messages", query: query)
    }

    /// A text message of the person. The same `clientUUID` on a retry returns the original message.
    public func postBrainText(_ text: String, clientUUID: UUID = UUID()) async throws -> BrainPostResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= BrainRules.maxTextLength else { throw APIError.invalidInput(reason: "invalid_text") }
        return try await post(PostBrainMessageBody(kind: "text", text: trimmed, attachmentID: nil, clientUUID: clientUUID))
    }

    /// A recording of the person: `attachmentID` is a finished voice attachment (`uploadVoiceRecording`).
    public func postBrainVoice(attachmentID: UUID, clientUUID: UUID = UUID()) async throws -> BrainPostResult {
        try await post(PostBrainMessageBody(kind: "voice_in", text: nil, attachmentID: attachmentID, clientUUID: clientUUID))
    }

    private func post(_ body: PostBrainMessageBody) async throws -> BrainPostResult {
        let (message, status): (BrainMessage, Int) = try await sendWithStatus("POST", "v1/channels/brain/messages", body: body)
        return BrainPostResult(message: message, created: status == 201)
    }

    /// ISO 8601 with milliseconds in UTC, as the server rounds `createdAt` to milliseconds.
    private static func sinceString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
