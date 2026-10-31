import Foundation
import Darwin

public enum RunPhase: String, Codable, Sendable {
    /// Server claim persisted, nothing spawned yet (safe to launch).
    case claimed
    /// Spawn intent persisted; if found after a crash without a process, the outcome is unknown.
    case launching
    case running
    /// Question published; no local process. Heartbeats continue.
    case waitingForAnswer
    /// Resume intent persisted (server resume sent or about to be, process not yet running).
    case resuming
    /// Outcome unknown; folder stays reserved until the operator confirms with `release`.
    case needsReconciliation
    /// Ownership lost: nothing may be published; waiting to confirm local stop to the server.
    case leaseLost
    /// Terminal. The folder is free again.
    case closed

    public var reservesFolder: Bool { self != .closed }
}

/// Durable outbox step, sent in order and only while the lease is valid locally.
public enum OutboxStep: Codable, Sendable, Equatable {
    case checkpoint(Checkpoint)
    case question(prompt: String, options: [String])
    case submit(RunResult)
    case fail
    case stop
}

public struct LocalRun: Codable, Sendable, Equatable {
    public var runID: UUID
    public var job: Job
    public var repositoryKey: UUID
    public var folder: String
    public var sessionID: UUID
    public var generation: Int
    public var leaseUntil: Date
    public var phase: RunPhase
    public var process: ProcessReference?
    public var outbox: [OutboxStep] = []
    /// Phase entered once the outbox is empty.
    public var afterOutbox: RunPhase?
    public var stopRequested = false
    public var contextRevision: Int
    public var deliveredQuestions: [UUID] = []
    public var resumePrompt: String?
    public var note: String
}

/// Atomic JSON state guarded by a single-writer lock held for the runner lifetime.
public final class LocalStateStore: @unchecked Sendable {
    public let directory: URL
    private let lockFD: Int32

    public init(directory: URL = LocalStateStore.defaultDirectory) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        lockFD = Darwin.open(directory.appendingPathComponent("runner.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw RunnerError.alreadyOpen }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); throw RunnerError.alreadyOpen }
    }
    deinit { flock(lockFD, LOCK_UN); close(lockFD) }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TodoRunner", isDirectory: true)
    }

    private var runsFile: URL { directory.appendingPathComponent("runs.json") }

    public func load() throws -> [LocalRun] { try Self.readRuns(in: directory) }

    /// Lock-free read for `status`/`doctor` while a runner is active (writes are atomic renames).
    public static func readRuns(in directory: URL) throws -> [LocalRun] {
        let file = directory.appendingPathComponent("runs.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([LocalRun].self, from: Data(contentsOf: file))
    }

    public func save(_ runs: [LocalRun]) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try Self.write(try encoder.encode(runs), to: runsFile)
    }

    /// Atomic replace (temp file + rename), owner-only permissions.
    static func write(_ data: Data, to file: URL) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary); throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// Server URL and device token. The URL and device ID live in config.json (0600); the token lives
/// in the SecretStore (Keychain) and is never part of any Codable representation of this type.
public struct RunnerConfig: Sendable, Equatable {
    public var baseURL: URL
    public var deviceID: UUID
    public var token: String
    public init(baseURL: URL, deviceID: UUID, token: String) {
        self.baseURL = baseURL; self.deviceID = deviceID; self.token = token
    }

    private struct Stored: Codable {
        var baseURL: URL
        var deviceID: UUID
        /// Only present in files written before the Keychain move; migrated on first load.
        var token: String?
    }

    static func account(_ deviceID: UUID) -> String { "device-token-\(deviceID.uuidString.lowercased())" }
    private static func file(_ directory: URL) -> URL { directory.appendingPathComponent("config.json") }

    public static func exists(in directory: URL) -> Bool { FileManager.default.fileExists(atPath: file(directory).path) }

    public static func load(from directory: URL, secrets: any SecretStore) throws -> RunnerConfig {
        let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file(directory)))
        if let legacy = stored.token {
            // Move a plaintext token into the secret store, then rewrite the file without it.
            try secrets.write(legacy, account: account(stored.deviceID))
            try RunnerConfig(baseURL: stored.baseURL, deviceID: stored.deviceID, token: legacy).save(to: directory, secrets: secrets)
            return RunnerConfig(baseURL: stored.baseURL, deviceID: stored.deviceID, token: legacy)
        }
        guard let token = try secrets.read(account: account(stored.deviceID)) else { throw RunnerError.missingToken }
        return RunnerConfig(baseURL: stored.baseURL, deviceID: stored.deviceID, token: token)
    }

    public func save(to directory: URL, secrets: any SecretStore) throws {
        try secrets.write(token, account: Self.account(deviceID))
        try LocalStateStore.write(try JSONEncoder().encode(Stored(baseURL: baseURL, deviceID: deviceID, token: nil)),
                                  to: Self.file(directory))
    }
}

/// Local folder allowlist: repository UUID (as used in the server binding) to one exact canonical folder.
/// Paths never leave the device; no parent-directory inheritance.
public struct FolderAllowlist: Sendable {
    public let file: URL
    public init(file: URL) { self.file = file }

    static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    private func raw() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    }

    /// The approved folder, only if it still resolves to exactly the approved path and is a directory.
    public func folder(for repositoryKey: UUID) throws -> URL? {
        guard let path = try raw()[repositoryKey.uuidString.lowercased()] else { return nil }
        let url = Self.canonical(URL(fileURLWithPath: path))
        var isDirectory: ObjCBool = false
        guard url.path == path, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw RunnerError.unapprovedFolder }
        return url
    }

    public func entries() throws -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: try raw().compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    /// Approves a folder; returns the repository key (new unless given). One key per folder.
    @discardableResult
    public func approve(folder: URL, repositoryKey: UUID? = nil) throws -> UUID {
        let canonical = Self.canonical(folder)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RunnerError.unapprovedFolder
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var values = try raw()
        if let existing = values.first(where: { $0.value == canonical.path }) {
            guard let key = UUID(uuidString: existing.key), repositoryKey == nil || repositoryKey == key else {
                throw RunnerError.invalidConfiguration
            }
            return key
        }
        let key = repositoryKey ?? UUID()
        values[key.uuidString.lowercased()] = canonical.path
        try LocalStateStore.write(try JSONEncoder().encode(values), to: file)
        return key
    }
}
