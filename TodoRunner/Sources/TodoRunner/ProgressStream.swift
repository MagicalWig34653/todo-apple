import Foundation

/// One observable step of the agent run, extracted from a Claude Code stream-json line.
public struct ProgressEvent: Sendable, Equatable {
    public var tool: String
    /// File base name for edits only. Full paths never leave the device.
    public var file: String?
    public init(tool: String, file: String? = nil) { self.tool = tool; self.file = file }
}

/// Incremental parser for the `--output-format stream-json` stdout file. Keeps a byte offset so
/// every line is read once, tolerates a partial last line and ignores everything that is not an
/// assistant tool call (hooks, rate limits, tool results, text).
public struct StreamTail: Sendable {
    public private(set) var offset: UInt64 = 0
    public init() {}

    public mutating func read(from url: URL) -> [ProgressEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return [] }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        // Only consume complete lines; the writer may be in the middle of one.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
        let complete = data[data.startIndex...lastNewline]
        offset += UInt64(complete.count)
        return Self.events(in: complete)
    }

    static func events(in data: Data) -> [ProgressEvent] {
        var events: [ProgressEvent] = []
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String, name != "StructuredOutput" else { continue }
                var file: String?
                if let input = block["input"] as? [String: Any],
                   ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(name),
                   let path = (input["file_path"] ?? input["notebook_path"]) as? String {
                    file = URL(fileURLWithPath: path).lastPathComponent
                }
                events.append(ProgressEvent(tool: name, file: file))
            }
        }
        return events
    }
}

/// Collects tool events and renders one short German sentence, so the board shows
/// a handful of readable updates instead of one message per tool call.
public struct ProgressAggregator: Sendable, Equatable {
    private var reads = 0, searches = 0, changes = 0, commands = 0, others = 0
    private var files: [String] = []

    public init() {}
    public var isEmpty: Bool { reads + searches + changes + commands + others == 0 }

    public mutating func add(_ events: [ProgressEvent]) {
        for event in events {
            switch event.tool {
            case "Read": reads += 1
            case "Glob", "Grep", "LS": searches += 1
            case "Edit", "Write", "MultiEdit", "NotebookEdit":
                changes += 1
                if let file = event.file, !files.contains(file) { files.append(file) }
            case "Bash": commands += 1
            default: others += 1
            }
        }
    }

    /// Text for the progress endpoint (the server accepts non-empty text); capped well below its limit.
    public func render() -> String {
        var parts: [String] = []
        if reads > 0 { parts.append(reads == 1 ? "1 Datei gelesen" : "\(reads) Dateien gelesen") }
        if searches > 0 { parts.append(searches == 1 ? "1 Suche" : "\(searches) Suchen") }
        if changes > 0 {
            let names = files.prefix(3).joined(separator: ", ") + (files.count > 3 ? " u. a." : "")
            parts.append((changes == 1 ? "1 Änderung" : "\(changes) Änderungen") + (names.isEmpty ? "" : " (\(names))"))
        }
        if commands > 0 { parts.append(commands == 1 ? "1 Befehl" : "\(commands) Befehle") }
        if others > 0 { parts.append(others == 1 ? "1 weiterer Schritt" : "\(others) weitere Schritte") }
        return String(("Agent arbeitet: " + parts.joined(separator: ", ")).prefix(500))
    }
}
