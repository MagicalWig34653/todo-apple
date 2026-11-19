import Foundation

// Review with variants (card 1D9C8B0C, contract command-center 1.8.0 in the main repository).
// A review may offer 2 to 4 named variants; one tap accepts the review with exactly that variant. Everything here is additive and
// tolerant: a server or review without `variants` is a plain review.

/// One offered variant. `attachmentID` points to an attachment of the task (shown through the authenticated preview route);
/// without it the variant is a text-only card.
public struct ReviewVariant: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let description: String?
    public let attachmentID: UUID?

    public init(id: String, label: String, description: String? = nil, attachmentID: UUID? = nil) {
        self.id = id; self.label = label; self.description = description; self.attachmentID = attachmentID
    }

    /// One-letter ids are shown upper case ("b" -> "B"), exactly like the server's chat line "Variante B gewählt: Label";
    /// longer slugs stay as written.
    public var name: String { id.count == 1 ? id.uppercased() : id }

    public enum Preview: Sendable, Equatable { case image, fallback, none }

    /// What the card shows for the picture. Only a variant with an attachment gets a picture slot (no empty area, no "no image"
    /// placeholder); an attachment whose preview does not load (for example a PDF, 415) becomes a small fallback with the label.
    public func previewState(loadFailed: Bool) -> Preview {
        guard attachmentID != nil else { return .none }
        return loadFailed ? .fallback : .image
    }
}

extension ReviewVariant: Codable {
    private enum CodingKeys: String, CodingKey { case id, label, description, attachmentID }

    /// Throws for an entry without usable `id` or `label` (the list decoder then drops it); an unusable attachment id or
    /// description is ignored.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id).trimmingCharacters(in: .whitespacesAndNewlines)
        let label = try c.decode(String.self, forKey: .label).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !label.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "variant without id or label"))
        }
        self.id = id; self.label = label
        let description = (try? c.decodeIfPresent(String.self, forKey: .description))?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = (description?.isEmpty ?? true) ? nil : description
        self.attachmentID = (try? c.decodeIfPresent(String.self, forKey: .attachmentID)).flatMap { UUID(uuidString: $0) }
    }
}

/// Decodes the `variants` list leniently: malformed entries are dropped and fewer than two valid ones mean "no choice"
/// (an empty list), so an odd value from a newer or older server never breaks the review itself.
enum LenientVariants {
    private struct Slot: Decodable {
        let value: ReviewVariant?
        init(from decoder: any Decoder) { value = try? ReviewVariant(from: decoder) }
    }

    static func decode<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) -> [ReviewVariant] {
        guard let slots = try? container.decodeIfPresent([Slot].self, forKey: key) else { return [] }
        let valid = slots.compactMap(\.value)
        return valid.count >= 2 ? valid : []
    }
}

/// What the choice helpers read from a review (`Review`, and `ReviewBrief` which is always pending).
public protocol ReviewVariantSource {
    var state: String { get }
    var variants: [ReviewVariant] { get }
    var chosenVariantID: String? { get }
}

public extension ReviewVariantSource {
    /// Pending and offering variants: "Annehmen" is replaced by the choice.
    var needsChoice: Bool { state == "pending" && !variants.isEmpty }

    var chosenVariant: ReviewVariant? {
        guard let id = chosenVariantID else { return nil }
        return variants.first { $0.id == id }
    }

    /// The variants that were not chosen (all of them while nothing is chosen).
    var otherVariants: [ReviewVariant] { variants.filter { $0.id != chosenVariantID } }

    /// "Variante B gewählt: Radarkarte" (same wording as the server's chat line), nil without a known choice.
    var chosenText: String? { chosenVariant.map { ReviewVariantText.chosen(name: $0.name, label: $0.label) } }
}

public enum ReviewVariantText {
    /// Same wording as the chat entry the server writes on acceptance.
    public static func chosen(name: String, label: String) -> String { "Variante \(name) gewählt: \(label)" }
}

/// Server rejections of a decision with a variant (HTTP 422).
public enum ReviewVariantError: Sendable, Equatable {
    /// Accepting a review with variants without a `variantID`.
    case variantRequired
    /// The `variantID` is not one of the offered variants.
    case unknownVariant
    /// A `variantID` on a review without variants or together with `request_changes`.
    case unexpectedVariant

    public init?(_ error: any Error) {
        guard case .invalidInput(let reason)? = error as? APIError else { return nil }
        switch reason {
        case "variant_required": self = .variantRequired
        case "unknown_variant": self = .unknownVariant
        case "unexpected_variant": self = .unexpectedVariant
        default: return nil
        }
    }
}

/// Keyboard navigation over the "Wählen" buttons of one review: arrow right/down = next, left/up = previous, Home/End = first/last.
/// Stops at the ends (no wrapping), so a stray Enter never lands on a surprising variant.
public enum VariantNavigation: Sendable, Equatable {
    case next, previous, first, last

    /// The index to focus, or nil without any variant. An out-of-range start is clamped.
    public func index(from current: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let last = count - 1
        let at = min(max(current, 0), last)
        switch self {
        case .next: return min(at + 1, last)
        case .previous: return max(at - 1, 0)
        case .first: return 0
        case .last: return last
        }
    }
}

/// The server lets a person take back a review decision for this long (`WorkflowLimits.reviewUndoWindow`, 5 * 60 s in the main
/// repository). The single place on the Apple side: texts and the countdown derive from it, and `ReviewVariantsTests` compares it
/// with the backend source when the main repository is reachable.
public enum ReviewUndo {
    public static let windowMinutes = 5
    public static let window: TimeInterval = TimeInterval(windowMinutes) * 60

    /// Seconds left until `until`; 0 when passed or unknown.
    public static func remaining(until: Date?, now: Date = Date()) -> TimeInterval {
        guard let until else { return 0 }
        return max(0, until.timeIntervalSince(now))
    }

    /// `m:ss` for the light countdown next to the undo button (rounds up, like the PWA).
    public static func format(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.up))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
