import CryptoKit
import Foundation

// MARK: Attachments upload/download (contracts/attachments.yaml)

public enum AttachmentRole: String, Codable, Sendable, CaseIterable {
    case reference, progress, result, voice
}

/// Client-side mirror of the server limits; the server stays authoritative.
public enum AttachmentRules {
    public static let maxSize = 10_485_760
    public static let allowedMediaTypes: Set<String> = ["image/png", "image/jpeg", "image/webp", "application/pdf"]

    /// Media type for a file extension, or nil when the server would reject it.
    public static func mediaType(forPathExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        default: return nil
        }
    }

    /// Detects the media type from magic bytes (the server validates them as well).
    public static func sniffMediaType(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if b.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D]) { return "application/pdf" }
        if b.count >= 12, b[0..<4].elementsEqual([0x52, 0x49, 0x46, 0x46]), b[8..<12].elementsEqual([0x57, 0x45, 0x42, 0x50]) {
            return "image/webp"
        }
        return nil
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Limits of recordings for the channel #brain (ADR 0030); the server checks size, container and duration.
public enum VoiceRules {
    public static let maxBytes = 5 * 1024 * 1024
    public static let maxDuration: TimeInterval = 120
    public static let m4aMediaType = "audio/mp4"
    public static let allowedMediaTypes: Set<String> = ["audio/mp4", "audio/wav"]
}

/// A finished attachment without a task (voice memo); `TaskAttachment` requires a task id.
public struct VoiceAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let filename: String
    public let role: String
    public let mediaType: String
    public let size: Int
    public let checksum: String
    public let status: String
}

public struct AttachmentUploadCapability: Codable, Sendable, Equatable {
    public let attachmentID: UUID
    /// Relative backend path; the token is only valid as Bearer for this one PUT.
    public let uploadURL: String
    public let token: String
    public let expiresAt: Date
}

struct BeginAttachmentBody: Encodable {
    /// Omitted for voice memos of the channel #brain (they belong to the account, not to a task).
    let taskID: UUID?
    let filename: String
    let role: AttachmentRole
    let mediaType: String
    let size: Int
    let checksum: String
}

extension APIClient {
    public func beginAttachment(
        taskID: UUID, filename: String, role: AttachmentRole, mediaType: String, size: Int, checksum: String
    ) async throws -> AttachmentUploadCapability {
        try await send(
            "POST", "v1/attachments/begin",
            body: BeginAttachmentBody(
                taskID: taskID, filename: filename, role: role, mediaType: mediaType, size: size, checksum: checksum))
    }

    /// PUT of the bytes with the upload capability (not the session token). The capability URL must stay on the API host.
    public func putAttachmentData(_ data: Data, capability: AttachmentUploadCapability) async throws {
        guard let url = URL(string: capability.uploadURL, relativeTo: baseURL)?.absoluteURL,
            url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port
        else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpShouldHandleCookies = false
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(capability.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        _ = try await performWithStatus(request)
    }

    public func completeAttachment(_ id: UUID) async throws -> TaskAttachment {
        try await send("POST", "v1/attachments/\(id.uuidString)/complete")
    }

    /// Voice memo without a task (contracts/attachments.yaml 1.2.0): role `voice`, no `taskID`. Only the owner reads it.
    public func beginVoiceAttachment(filename: String, mediaType: String, size: Int, checksum: String) async throws -> AttachmentUploadCapability {
        try await send(
            "POST", "v1/attachments/begin",
            body: BeginAttachmentBody(
                taskID: nil, filename: filename, role: .voice, mediaType: mediaType, size: size, checksum: checksum))
    }

    public func completeVoiceAttachment(_ id: UUID) async throws -> VoiceAttachment {
        try await send("POST", "v1/attachments/\(id.uuidString)/complete")
    }

    /// Whole flow for a recording of the channel #brain: begin (role voice, no task), PUT, complete. Same failure handling
    /// as `uploadAttachment`. The recording is checked against the client-side limits first (the server stays authoritative).
    public func uploadVoiceRecording(filename: String = "voice.m4a", mediaType: String = VoiceRules.m4aMediaType, data: Data) async throws -> VoiceAttachment {
        guard !data.isEmpty, data.count <= VoiceRules.maxBytes else { throw APIError.invalidInput(reason: "voice_too_large") }
        guard VoiceRules.allowedMediaTypes.contains(mediaType) else { throw APIError.invalidInput(reason: "unsupported_audio_type") }
        let capability = try await beginVoiceAttachment(
            filename: filename, mediaType: mediaType, size: data.count, checksum: AttachmentRules.sha256Hex(data))
        do {
            do { try await putAttachmentData(data, capability: capability) }
            catch APIError.server(status: 502, _) { try await putAttachmentData(data, capability: capability) }
            return try await completeVoiceAttachment(capability.attachmentID)
        } catch let error as APIError {
            if case .transport = error, let done = try? await completeVoiceAttachment(capability.attachmentID) { return done }
            try? await abortAttachment(capability.attachmentID)
            throw error
        }
    }

    /// Downloads a voice attachment (original bytes) to `<directory>/<id>.<ext>` for playback; reuses a file already there.
    public func downloadVoiceFile(_ id: UUID, into directory: URL, fileExtension: String = "m4a") async throws -> URL {
        let target = directory.appending(path: "\(id.uuidString.lowercased()).\(fileExtension)")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let data = try await downloadAttachment(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        return target
    }

    /// Aborts a pending upload; completed attachments return a conflict.
    public func abortAttachment(_ id: UUID) async throws {
        try await sendNoContent("DELETE", "v1/attachments/\(id.uuidString)")
    }

    /// Whole upload flow: begin, PUT, complete. After an uncertain PUT result (transport error) `complete` decides;
    /// a 502 is retried once; any other failure aborts the pending upload best-effort and rethrows.
    public func uploadAttachment(
        taskID: UUID, filename: String, role: AttachmentRole = .reference, mediaType: String, data: Data
    ) async throws -> TaskAttachment {
        guard !data.isEmpty, data.count <= AttachmentRules.maxSize else { throw APIError.invalidInput(reason: "invalid_size") }
        guard AttachmentRules.allowedMediaTypes.contains(mediaType) else { throw APIError.invalidInput(reason: "invalid_media_type") }
        let capability = try await beginAttachment(
            taskID: taskID, filename: filename, role: role, mediaType: mediaType, size: data.count,
            checksum: AttachmentRules.sha256Hex(data))
        do {
            do { try await putAttachmentData(data, capability: capability) }
            catch APIError.server(status: 502, _) { try await putAttachmentData(data, capability: capability) }
            return try await completeAttachment(capability.attachmentID)
        } catch let error as APIError {
            if case .transport = error, let done = try? await completeAttachment(capability.attachmentID) { return done }
            try? await abortAttachment(capability.attachmentID)
            throw error
        }
    }

    /// Original bytes (private, not cached by the server).
    public func downloadAttachment(_ id: UUID) async throws -> Data {
        try await rawGet("v1/attachments/\(id.uuidString)/download")
    }

    /// Original image bytes for inline display; PDFs answer 415 (mapped to `.server(status: 415)`).
    public func previewAttachment(_ id: UUID) async throws -> Data {
        try await rawGet("v1/attachments/\(id.uuidString)/preview")
    }

    /// Downloads, verifies size and SHA-256 against the metadata and writes the file (for QuickLook / share).
    public func downloadAttachmentFile(_ attachment: TaskAttachment, into directory: URL) async throws -> URL {
        let data = try await downloadAttachment(attachment.id)
        guard data.count == attachment.size, AttachmentRules.sha256Hex(data) == attachment.checksum else {
            throw APIError.decoding("attachment checksum mismatch")
        }
        let safe = URL(fileURLWithPath: attachment.filename).lastPathComponent
        let folder = directory.appending(path: attachment.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: safe.isEmpty ? attachment.id.uuidString : safe)
        try data.write(to: target, options: .atomic)
        return target
    }

    private func rawGet(_ path: String) async throws -> Data {
        var request = try makeRequest("GET", path, query: [], body: nil, auth: true)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return try await performWithStatus(request).0
    }
}
