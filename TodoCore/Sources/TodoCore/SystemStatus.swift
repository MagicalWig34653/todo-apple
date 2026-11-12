import Foundation

// MARK: Lage-Ampel (contracts/system-status.yaml in the main repository)
// The watcher on the user's Mac reports Claude quota, Codex and disk; the app only reads. Reading is tolerant: unknown
// or malformed fields drop out instead of failing the whole response.

public enum Ampel: String, Sendable, Equatable {
    case gruen, gelb, rot
}

public struct CodexStatus: Sendable, Equatable {
    public let usedPct: Double
    public let allowedPct: Double?
    public let targetPct: Double?
    public let release: Bool?

    /// Over budget (used more than allowed so far) or not released by the watcher.
    public var isWarning: Bool { (allowedPct.map { usedPct > $0 } ?? false) || release == false }
}

/// The watcher's status document, reduced to the fields the app shows.
public struct SystemStatusDocument: Decodable, Sendable, Equatable {
    public let claudeAmpel: Ampel?
    public let claudeAccounts: [Int]
    public let claudeFreeForBrain: Double?
    public let codex: CodexStatus?
    public let diskAmpel: Ampel?
    public let diskFreeGB: Double?

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(claudeAmpel: Ampel? = nil, claudeAccounts: [Int] = [], claudeFreeForBrain: Double? = nil, codex: CodexStatus? = nil, diskAmpel: Ampel? = nil, diskFreeGB: Double? = nil) {
        self.claudeAmpel = claudeAmpel; self.claudeAccounts = claudeAccounts; self.claudeFreeForBrain = claudeFreeForBrain
        self.codex = codex; self.diskAmpel = diskAmpel; self.diskFreeGB = diskFreeGB
    }

    public init(from decoder: any Decoder) throws {
        guard let root = try? decoder.container(keyedBy: Key.self) else { self.init(); return }
        func key(_ name: String) -> Key { Key(stringValue: name)! }
        func number(_ c: KeyedDecodingContainer<Key>, _ name: String) -> Double? { try? c.decodeIfPresent(Double.self, forKey: key(name)) }
        func ampel(_ name: String) -> Ampel? { (try? root.decodeIfPresent(String.self, forKey: key(name))).flatMap { Ampel(rawValue: $0) } }
        var codex: CodexStatus?
        if let c = try? root.nestedContainer(keyedBy: Key.self, forKey: key("codex")), let used = number(c, "verbraucht_pct") {
            codex = CodexStatus(usedPct: used, allowedPct: number(c, "erlaubt_bis_jetzt_pct"), targetPct: number(c, "ziel_pct"),
                                release: try? c.decodeIfPresent(Bool.self, forKey: key("freigabe")))
        }
        // Per element, so one bad entry does not drop the list.
        var accounts: [Int] = []
        if var list = try? root.nestedUnkeyedContainer(forKey: key("claude_nutzbare_konten")) {
            while !list.isAtEnd {
                if let n = try? list.decode(Double.self) { accounts.append(Int(n)) } else { _ = try? list.decode(Discard.self) }
            }
        }
        self.init(claudeAmpel: ampel("claude_ampel"), claudeAccounts: accounts, claudeFreeForBrain: number(root, "claude_frei_fuer_brain"),
                  codex: codex, diskAmpel: ampel("platte_ampel"), diskFreeGB: number(root, "platte_frei_gb"))
    }

    private struct Discard: Decodable { init(from decoder: any Decoder) throws {} }

    public var hasClaude: Bool { claudeAmpel != nil || !claudeAccounts.isEmpty || claudeFreeForBrain != nil }
    public var hasDisk: Bool { diskAmpel != nil || diskFreeGB != nil }
    public var isEmpty: Bool { !hasClaude && codex == nil && !hasDisk }
}

public struct SystemStatusItem: Decodable, Sendable, Equatable, Identifiable {
    public let source: String
    public let label: String?
    public let reportedAt: Date
    public let status: SystemStatusDocument
    public var id: String { source }

    public init(source: String, label: String? = nil, reportedAt: Date, status: SystemStatusDocument) {
        self.source = source; self.label = label; self.reportedAt = reportedAt; self.status = status
    }

    /// A report older than this many minutes counts as stale and is shown grey.
    public static let staleAfterMinutes = 30

    /// Age in whole minutes: server clock minus report time, advanced by the time that passed locally since the answer
    /// arrived. Never negative.
    public func ageMinutes(serverNow: Date, fetchedAt: Date, now: Date) -> Int {
        let seconds = serverNow.timeIntervalSince(reportedAt) + max(0, now.timeIntervalSince(fetchedAt))
        return seconds.isFinite ? max(0, Int((seconds / 60).rounded(.down))) : 0
    }

    public static func isStale(ageMinutes: Int) -> Bool { ageMinutes > staleAfterMinutes }
}

public struct SystemStatusResponse: Decodable, Sendable, Equatable {
    public let items: [SystemStatusItem]
    public let now: Date

    public init(items: [SystemStatusItem], now: Date) { self.items = items; self.now = now }
}

extension APIClient {
    /// The watcher's latest reports. Throws `APIError.notFound` on servers without the endpoint.
    public func systemStatus() async throws -> SystemStatusResponse {
        try await send("GET", "v1/system-status")
    }
}
