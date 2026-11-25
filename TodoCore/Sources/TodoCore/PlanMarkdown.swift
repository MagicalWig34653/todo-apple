import Foundation

/// Splits the Markdown plan of a card (contract pipeline 1.0.0) into the few block kinds the detail shows: headings, bullet and
/// numbered lists, fenced code and paragraphs. Inline formatting (bold, code, links) stays in the text for the view's Markdown
/// parser. Nothing is dropped: whatever is not recognised becomes a paragraph.
public enum PlanBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case bullet(text: String, indent: Int)
    case numbered(number: String, text: String)
    case code(String)
    case paragraph(String)
}

public enum PlanMarkdown {
    public static func blocks(_ markdown: String) -> [PlanBlock] {
        var blocks: [PlanBlock] = []
        var paragraph: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }

        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = code { blocks.append(.code(open.joined(separator: "\n"))); code = nil }
                else { flushParagraph(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flushParagraph(); continue }
            if let (level, text) = heading(line) { flushParagraph(); blocks.append(.heading(level: level, text: text)); continue }
            if let text = bulletText(line) { flushParagraph(); blocks.append(.bullet(text: text, indent: indent(of: raw))); continue }
            if let (number, text) = numberedText(line) { flushParagraph(); blocks.append(.numbered(number: number, text: text)); continue }
            paragraph.append(line)
        }
        flushParagraph()
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        return blocks
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func bulletText(_ line: String) -> String? {
        guard let first = line.first, "-*+".contains(first), line.dropFirst().first == " " else { return nil }
        let text = line.dropFirst().trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func numberedText(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, ".)".contains(mark), rest.dropFirst().first == " " else { return nil }
        let text = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (String(digits), text)
    }

    /// Two spaces or one tab per level.
    private static func indent(of raw: String) -> Int {
        var width = 0
        for ch in raw { if ch == " " { width += 1 } else if ch == "\t" { width += 2 } else { break } }
        return width / 2
    }
}
