import Foundation

public enum ServerIdentity {
    /// Bearers belong to a scheme/host/effective-port tuple, never to an editable URL string.
    public static func origin(_ url: URL) -> String {
        let scheme = (url.scheme ?? "").lowercased()
        let host = (url.host ?? "").lowercased()
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}
