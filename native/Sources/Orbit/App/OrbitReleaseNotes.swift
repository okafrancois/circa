import Foundation

/// Route the running release, rather than a newer release the user has not installed.
enum OrbitReleaseNotes {
    static func runningVersionURL(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> URL? {
        guard let version = info["CFBundleShortVersionString"] as? String,
              version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { return nil }
        guard let repository = info["OrbitRepository"] as? String, !repository.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repository)/releases/tag/v" + version)
    }
}
