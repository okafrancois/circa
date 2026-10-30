import Foundation

/// A freshness hint only. Sparkle still selects compatible updates, verifies signatures,
/// downloads archives and installs them. Nested delta versions must never become candidates.
enum OrbitUpdateFeed {
    static func latestVersion(data: Data) throws -> String {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { throw URLError(.cannotParseResponse) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let currentOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        guard let latest = reader.items.filter({ item in
            item.channel.isEmpty && !item.version.isEmpty
                && (item.minimum.isEmpty || currentOS.compare(item.minimum, options: .numeric) != .orderedAscending)
                && (item.maximum.isEmpty || currentOS.compare(item.maximum, options: .numeric) != .orderedDescending)
        }).map(\.version).max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) else {
            throw URLError(.cannotParseResponse)
        }
        return latest
    }

    private struct Item {
        var version = "", minimum = "", maximum = "", channel = ""
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
                default: break
                }
            }
            if path == ["rss", "channel", "item"] { items.append(item) }
            path.removeLast()
            text = ""
        }
    }
}
