import Foundation

public enum LabelNameError: Error, Equatable, Sendable {
    case empty
    case tooLong
}

/// Label name rule of contracts/discovery.yaml (`LabelCreate.name`: trimmed before the check, 1...200 characters).
/// Duplicate names are allowed by the server, so they are not checked here.
public enum LabelName {
    public static let maxLength = 200

    /// The trimmed name, or the reason the server would refuse it. The length counts Unicode scalars like JSON Schema `maxLength`.
    public static func normalized(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw LabelNameError.empty }
        if name.unicodeScalars.count > maxLength { throw LabelNameError.tooLong }
        return name
    }
}
