import Foundation

/// Meeting destinations share the same exclusions in external routing and Peek.
public enum BrowserMeetingLink {
    public static func matches(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return false }
        let path = url.path.lowercased()
        if host == "meet.google.com" { return true }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            return ["/j/", "/my/", "/wc/", "/s/"].contains { path.hasPrefix($0) }
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" { return true }
        return host == "app.around.co" || (host == "around.co" && path.hasPrefix("/r/"))
    }
}
