import Foundation
import CryptoKit

/// Durable, account/server-scoped requests. Every update rereads the manifest, so an older screen cannot
/// overwrite requests added by a newly opened screen while its network response was outstanding.
struct BrainPendingStore {
    let directory: URL
    private var manifest: URL { directory.appendingPathComponent("pending.json") }

    init(root: URL, account: UUID, server: String) {
        let identity = server + "\n" + account.uuidString
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = root.appendingPathComponent(key, isDirectory: true)
    }

    func load() throws -> [BrainOutgoing] {
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        return try JSONDecoder().decode([BrainOutgoing].self, from: Data(contentsOf: manifest))
    }

    func upsert(_ item: BrainOutgoing) throws -> [BrainOutgoing] {
        var items = try load()
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item }
        else { items.append(item) }
        try save(items)
        return items
    }

    func remove(_ id: UUID) throws -> [BrainOutgoing] {
        let items = try load().filter { $0.id != id }
        try save(items)
        return items
    }

    private func save(_ items: [BrainOutgoing]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(items).write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }

    func keepRecording(_ source: URL, id: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent(id.uuidString + ".m4a")
        if source != target { try Data(contentsOf: source).write(to: target, options: .atomic) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }

    /// Also completes cleanup interrupted between committing the manifest and deleting an audio file.
    func cleanUnreferencedRecordings() throws {
        let referenced = Set(try load().compactMap(\.fileURL))
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.pathExtension == "m4a" && !referenced.contains(file) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
