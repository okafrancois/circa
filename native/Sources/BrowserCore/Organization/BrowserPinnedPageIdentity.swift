import Foundation

/// Page identity for a pin. Queries and path case remain significant; anchors do not.
public enum BrowserPinnedPageIdentity {
    public static func matches(_ original: URL, _ current: URL) -> Bool {
        normalized(original) == normalized(current)
    }

    private static func normalized(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "http" && parts.port == 80) || (parts.scheme == "https" && parts.port == 443) {
            parts.port = nil
        }
        parts.fragment = nil
        if parts.host != nil {
            if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
            if parts.percentEncodedPath.count > 1 && parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        }
        return parts.string ?? url.absoluteString
    }
}
