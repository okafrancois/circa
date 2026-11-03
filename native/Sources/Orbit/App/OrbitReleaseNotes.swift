import Foundation

/// Public notes are anchored to the relevant semantic version, never an arbitrary feed URL.
enum OrbitReleaseNotes {
    static let changelogURL = URL(string: "https://circabrowser.com/changelog")!

    static func versionURL(_ version: String) -> URL? {
        guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: changelogURL.absoluteString + "#v" + version)
    }

    static func runningVersionURL(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> URL? {
        guard let version = info["CFBundleShortVersionString"] as? String else { return nil }
        return versionURL(version)
    }
}
