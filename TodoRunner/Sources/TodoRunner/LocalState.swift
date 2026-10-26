import Foundation
import Darwin

public struct LocalRun: Codable, Sendable {
    public var job: RunnerJob
    public var sessionID: UUID
    public var folder: URL
    public var process: ProcessReference?
    public var phase: RunPhase
    public var checkpoint: String
    public var pendingEvent: RunnerEvent?
}

/// A single writer lock also protects against two runner executables starting together.
/// Keep this object alive for the entire runner lifetime.
public final class LocalStateStore: @unchecked Sendable {
    public let directory: URL
    private let lockFD: Int32
    public init(directory: URL = LocalStateStore.defaultDirectory) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        lockFD = Darwin.open(directory.appendingPathComponent("runner.lock").path,
                             O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw RunnerError.alreadyOpen }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD); throw RunnerError.alreadyOpen
        }
    }
    deinit { flock(lockFD, LOCK_UN); close(lockFD) }
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TodoRunner", isDirectory: true)
    }
    public func load() throws -> [LocalRun] {
        let file = directory.appendingPathComponent("runs.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([LocalRun].self, from: Data(contentsOf: file))
    }
    public func save(_ runs: [LocalRun]) throws {
        try Self.write(runs, to: directory.appendingPathComponent("runs.json"))
    }
    static func write<T: Encodable>(_ value: T, to file: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// Exact canonical folder mappings. No inherited parent-directory approvals.
public struct FolderApprovals: Sendable {
    public let file: URL
    public init(file: URL) { self.file = file }
    public func bindings() throws -> [String: URL] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
        return try values.mapValues { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            // A changed symlink must not silently redirect an existing approval.
            guard url.path == path else { throw RunnerError.unapprovedFolder }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { throw RunnerError.unapprovedFolder }
            return url
        }
    }
    public func approve(projectID: String, folder: URL) throws {
        let canonical = folder.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard !projectID.isEmpty,
              FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw RunnerError.unapprovedFolder }
        var values = try bindings().mapValues(\.path)
        values[projectID] = canonical.path
        try LocalStateStore.write(values, to: file)
    }
}
