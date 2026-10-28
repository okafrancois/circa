import Foundation

/// LaunchServices supplies file URLs for internet shortcuts. Read only that explicitly
/// opened file, with a bounded payload; ordinary HTML documents remain file navigations.
enum ExternalURLResolver {
    static func resolve(_ url: URL) -> URL? {
        guard url.isFileURL else {
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host, !host.isEmpty else { return nil }
            return url
        }
        guard url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else { return nil }
        let kind = url.pathExtension.lowercased()
        guard kind == "webloc" || kind == "url" else {
            return ["html", "htm", "xhtml"].contains(kind) ? url : nil
        }
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536 else { return nil }
        let destination: String?
        if kind == "webloc" {
            let value = try? PropertyListSerialization.propertyList(from: data, format: nil)
            destination = (value as? [String: Any])?["URL"] as? String
        } else {
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            var inShortcut = false
            var found: String?
            for line in text.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") { inShortcut = trimmed.lowercased() == "[internetshortcut]" }
                if inShortcut, trimmed.lowercased().hasPrefix("url=") {
                    found = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            destination = found
        }
        guard let destination, let resolved = URL(string: destination),
              let scheme = resolved.scheme?.lowercased(), ["http", "https"].contains(scheme),
              resolved.host != nil else { return nil }
        return resolved
    }
}
