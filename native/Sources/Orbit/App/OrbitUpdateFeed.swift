import CryptoKit
import Foundation

/// A freshness hint only. Sparkle still selects compatible updates, verifies signatures,
/// downloads archives and installs them. Nested delta versions must never become candidates.
enum OrbitUpdateFeed {
    /// Feed checks carry no cookies, credentials or cache: nothing the app stored for other
    /// requests reaches the update host, and nothing the update host sets is kept.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return configuration
    }

    static let session = URLSession(configuration: sessionConfiguration())

    /// Returns the signed feed bytes when the embedded Sparkle feed signature matches `publicKey`.
    /// The trailer is the one written by sign_update and generate_appcast; nothing may follow it.
    static func verifiedContent(_ data: Data, publicKey: String) throws -> Data {
        guard let keyData = Data(base64Encoded: publicKey), keyData.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let start = data.range(of: Data("<!-- sparkle-signatures:\n".utf8), options: .backwards)?.lowerBound,
              let trailer = String(data: data[start...], encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        let lines = trailer.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard lines.count == 4, lines[0] == "<!-- sparkle-signatures:", lines[3] == "-->",
              lines[1].hasPrefix("edSignature: "), lines[2].hasPrefix("length: "),
              let signature = Data(base64Encoded: String(lines[1].dropFirst("edSignature: ".count))),
              signature.count == 64,
              Int(lines[2].dropFirst("length: ".count)) == start - data.startIndex else {
            throw URLError(.cannotParseResponse)
        }
        let signed = data[data.startIndex..<start]
        guard key.isValidSignature(signature, for: signed) else { throw URLError(.secureConnectionFailed) }
        return Data(signed)
    }

    /// Sparkle's phased rollout as seen by this installation. Sparkle stores a random identifier
    /// under `SUUpdateGroupIdentifier` on the first scheduled check and assigns one of seven groups;
    /// group N becomes eligible N rollout intervals after the item's publication date.
    struct Phasing {
        static let groupCount: UInt64 = 7
        static let identifierKey = "SUUpdateGroupIdentifier"
        var group: UInt64
        var now = Date()
        /// The prepared update stays eligible: a user-initiated check legitimately bypasses phasing.
        var pendingVersion: String?
        var hostVersion = ""

        init(group: UInt64, now: Date = Date(), pendingVersion: String? = nil, hostVersion: String = "") {
            self.group = group % Self.groupCount
            self.now = now
            self.pendingVersion = pendingVersion
            self.hostVersion = hostVersion
        }

        /// Nil until Sparkle has assigned this installation a group; no phasing applies then.
        init?(defaults: UserDefaults, pendingVersion: String?, hostVersion: String) {
            guard let identifier = defaults.object(forKey: Self.identifierKey) as? NSNumber else { return nil }
            self.init(group: identifier.uint64Value, pendingVersion: pendingVersion, hostVersion: hostVersion)
        }

        fileprivate func admits(_ item: Item) -> Bool {
            if item.version == pendingVersion { return true }
            // Critical updates ignore phasing, like Sparkle's own background check.
            if let critical = item.criticalBelow, critical.isEmpty || hostVersion.isEmpty
                || hostVersion.compare(critical, options: .numeric) == .orderedAscending { return true }
            guard let interval = TimeInterval(item.phasedInterval), let published = Self.date(item.publicationDate) else { return true }
            return now.timeIntervalSince(published) >= interval * TimeInterval(group)
        }

        private static func date(_ text: String) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: text) { return date }
            }
            return nil
        }
    }

    /// The bundle's own policy: when it requires signed feeds, the hint reads only verified bytes.
    static func latestVersion(data: Data, info: [String: Any], allowedChannels: Set<String> = [],
                              phasing: Phasing? = nil) throws -> String {
        guard info["SURequireSignedFeed"] as? Bool == true else {
            return try latestVersion(data: data, allowedChannels: allowedChannels, phasing: phasing)
        }
        guard let key = info["SUPublicEDKey"] as? String else { throw URLError(.cannotParseResponse) }
        return try latestVersion(data: verifiedContent(data, publicKey: key), allowedChannels: allowedChannels, phasing: phasing)
    }

    static func latestVersion(data: Data, allowedChannels: Set<String> = [], phasing: Phasing? = nil) throws -> String {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { throw URLError(.cannotParseResponse) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let currentOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        guard let latest = reader.items.filter({ item in
            (item.channel.isEmpty || allowedChannels.contains(item.channel)) && !item.version.isEmpty
                && (item.minimum.isEmpty || currentOS.compare(item.minimum, options: .numeric) != .orderedAscending)
                && (item.maximum.isEmpty || currentOS.compare(item.maximum, options: .numeric) != .orderedDescending)
                && (phasing?.admits(item) ?? true)
        }).map(\.version).max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) else {
            throw URLError(.cannotParseResponse)
        }
        return latest
    }

    fileprivate struct Item {
        var version = "", minimum = "", maximum = "", channel = ""
        var publicationDate = "", phasedInterval = ""
        /// Nil when not critical; empty when critical for every installed version.
        var criticalBelow: String?
    }
    private final class Reader: NSObject, XMLParserDelegate {
        var items: [Item] = []
        private var path: [String] = []
        private var item = Item()
        private var text = ""
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            path.append(elementName)
            text = ""
            if path == ["rss", "channel", "item"] { item = Item() }
            if path == ["rss", "channel", "item", "enclosure"], item.version.isEmpty {
                item.version = attributeDict["sparkle:version"] ?? ""
            }
            if path == ["rss", "channel", "item", "sparkle:criticalUpdate"] {
                item.criticalBelow = attributeDict["sparkle:version"] ?? ""
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if path.count == 4 && path.prefix(3) == ["rss", "channel", "item"] {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                switch elementName {
                case "sparkle:version": item.version = value
                case "sparkle:minimumSystemVersion": item.minimum = value
                case "sparkle:maximumSystemVersion": item.maximum = value
                case "sparkle:channel": item.channel = value
                case "pubDate": item.publicationDate = value
                case "sparkle:phasedRolloutInterval": item.phasedInterval = value
                default: break
                }
            }
            if path == ["rss", "channel", "item"] { items.append(item) }
            path.removeLast()
            text = ""
        }
    }
}
