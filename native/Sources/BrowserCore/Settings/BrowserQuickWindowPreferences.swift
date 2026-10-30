import Foundation

/// URL identity for external opens. Paths, queries and fragments remain significant.
public enum BrowserQuickWindowURL {
    public static func key(_ url: URL) -> String {
        guard var parts = URLComponents(url: url.standardized, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return url.absoluteString
        }
        parts.scheme = scheme
        parts.host = parts.host?.lowercased()
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.string ?? url.absoluteString
    }

    public static func domain(_ url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }
}

public extension BrowserSettingsStore {
    func setQuickWindowArchiveThreshold(_ threshold: BrowserAutoArchiveThreshold) throws {
        var next = document
        next.quickWindowArchiveThreshold = threshold
        try publish(next)
    }

    func rememberQuickWindowProfile(for url: URL, profileID: ProfileID) throws {
        guard let domain = BrowserQuickWindowURL.domain(url) else { return }
        var next = document
        next.quickWindowProfilesByDomain[domain] = profileID
        try publish(next)
    }
}
