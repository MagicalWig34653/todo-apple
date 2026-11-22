import Foundation

/// Audit timestamps ("erstellt", "gestellt", "entschieden", ...) show the exact moment in Berlin time, whatever the device
/// zone or locale is. Same shape as the PWA tooltip: `22.11.2026, 10:18:17 GMT+1`. The relative text next to it comes from the
/// system formatter.
public enum AuditTime {
    public static let zone = TimeZone(identifier: "Europe/Berlin") ?? .gmt

    public static func exact(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.dateFormat = "dd.MM.yyyy, HH:mm:ss"
        let hours = zone.secondsFromGMT(for: date) / 3600
        return "\(f.string(from: date)) GMT\(hours >= 0 ? "+" : "-")\(abs(hours))"
    }
}
