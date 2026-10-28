import CryptoKit
import Foundation

/// Pure parser of Arc's `StorableSidebar.json`, `StorableArchiveItems.json` and the profile names
/// of `User Data/Local State`. Opens no file, loads no page, touches no credential. Defensive:
/// unknown fields are ignored, malformed records, missing/repeated references and cycles are
/// bounded and counted, and nothing ambiguous is reported as imported.
/// Port of the Electron reconstruction (`app/arc-sidebar.cjs`, `docs/arc-import-format.md`), with
/// two deliberate differences: items reachable from no root are counted, not recovered into a
/// neutral profile (Arc does not display them), and split groups are flattened (no native split
/// model on main yet).
public enum ArcSidebarParser {
    /// `StorableSidebar.json` versions whose structure was observed. Others are parsed best-effort.
    public static let observedFormatVersions: Set<Int> = [1]
    public static let maximumThemeBytes = 64 * 1024
    static let maximumDepth = 400
    static let maximumURLBytes = 4096

    /// - Parameter legacyProfileDirectories: explicit mapping of opaque legacy profile ids to their
    ///   Chromium directory. No mapping is ever inferred from names.
    public static func parse(sidebar: ArcJSON, archive: ArcJSON?, localState: ArcJSON?,
                             legacyProfileDirectories: [String: String] = [:]) throws -> ArcSidebarGraph {
        let root = sidebar["sidebar"] ?? sidebar
        guard let containers = root["containers"]?.array else { throw ArcImportError.unrecognizedSidebarFormat }
        var builder = Builder(localState: localState, legacy: legacyProfileDirectories)
        for container in containers where container.isObject && !container.has("global") {
            builder.parseContainer(container)
        }
        if let archive { builder.parseArchive(archive) }
        let version = sidebar["version"]?.number.map { Int($0) }
        return ArcSidebarGraph(formatVersion: version, formatRecognized: true,
                               profiles: builder.profiles(), spaces: builder.spaces,
                               favorites: builder.favorites, archive: builder.archive,
                               diagnostics: builder.diagnostics)
    }

    static func isProfileDirectory(_ name: String) -> Bool {
        name == "Default" || name.wholeMatch(of: /Profile [0-9]{1,4}/) != nil
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// HTTP(S) without credentials, or `about:blank`. Imported text is never turned into a search.
    static func webURL(_ text: String) -> URL? {
        guard text.utf8.count <= maximumURLBytes else { return nil }
        if text == "about:blank" { return URL(string: text) }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private struct Builder {
        var diagnostics = ArcSidebarDiagnostics()
        var spaces: [ArcImportedSpace] = []
        var favorites: [ArcImportedFavorites] = []
        var archive: [ArcImportedArchiveRecord] = []
        private var spaceIDs: Set<String> = []
        private var profileOrder: [ArcProfileKey] = []
        private var unresolved: Set<String> = []
        private let names: [String: String]
        private let legacy: [String: String]

        init(localState: ArcJSON?, legacy: [String: String]) {
            var names: [String: String] = [:]
            for (directory, info) in localState?["profile"]?["info_cache"]?.object ?? [:]
            where ArcSidebarParser.isProfileDirectory(directory) {
                if let name = info["name"]?.string { names[directory] = name }
            }
            self.names = names
            self.legacy = legacy.filter { ArcSidebarParser.isProfileDirectory($0.value) }
        }

        func profiles() -> [ArcImportedProfile] {
            profileOrder.map { ArcImportedProfile(key: $0, displayName: $0.directory.flatMap { names[$0] }) }
        }

        private mutating func note(_ key: ArcProfileKey) {
            if !profileOrder.contains(key) { profileOrder.append(key) }
        }

        /// `{default:{}}` → `Default`; `{custom:{_0:{directoryBasename:}}}` → that directory (observed).
        mutating func profileKey(for reference: ArcJSON?) -> ArcProfileKey {
            guard let reference, reference != .null else { return .unresolved("unknown") }
            if reference.has("default") { return .directory("Default") }
            let custom = (reference["custom"] ?? reference).unwrapped
            for candidate in [custom.string, custom["directoryBasename"]?.string, custom["directory"]?.string] {
                if let candidate, ArcSidebarParser.isProfileDirectory(candidate) { return .directory(candidate) }
            }
            if let id = custom.rawIdentifier, let directory = legacy[id] { return .directory(directory) }
            return .unresolved(ArcSidebarParser.digest(reference.canonical))
        }

        // MARK: Values

        mutating func timestamp(_ value: ArcJSON?) -> Date? {
            guard let value, value != .null else { diagnostics.missingTimestamps += 1; return nil }
            var seconds: Double?
            if let number = value.number { seconds = number }
            else if let text = value.string {
                if let number = Double(text), text.wholeMatch(of: /-?[0-9]+(\.[0-9]+)?/) != nil { seconds = number }
                else if let date = ISO8601DateFormatter().date(from: text) { return date }
                else {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let date = formatter.date(from: text) { return date }
                }
            }
            // Arc numbers are seconds since 1 January 2001 (observed); a Unix epoch is never guessed.
            guard let seconds, seconds.isFinite, abs(seconds) < 8.64e12 else {
                diagnostics.invalidTimestamps += 1
                return nil
            }
            return Date(timeIntervalSinceReferenceDate: seconds)
        }

        static func hex(_ value: ArcJSON?) -> String? {
            guard let value else { return nil }
            if let text = value.string, text.wholeMatch(of: /#[0-9A-Fa-f]{6}/) != nil { return text.lowercased() }
            let components = [value["red"] ?? value["r"], value["green"] ?? value["g"], value["blue"] ?? value["b"]]
                .map { $0?.number }
            guard components.allSatisfy({ ($0 ?? -1) >= 0 && ($0 ?? 2) <= 1 }) else { return nil }
            return "#" + components.map { String(format: "%02x", Int(($0! * 255).rounded())) }.joined()
        }

        mutating func appearance(_ record: ArcJSON) -> ArcSpaceAppearance {
            let custom = record["customInfo"]
            var result = ArcSpaceAppearance()
            if let theme = custom?["windowTheme"], theme.isObject {
                let canonical = theme.canonical
                if canonical.utf8.count <= ArcSidebarParser.maximumThemeBytes { result.theme = canonical }
                else { diagnostics.oversizedThemes += 1 }
                let palette = theme["primaryColorPalette"]
                result.colorHex = Self.hex(palette?["tintedLight"]) ?? Self.hex(palette?["midTone"])
            }
            result.colorHex = result.colorHex ?? Self.hex(record["color"])
            let iconType = custom?["iconType"]
            result.icon = iconType?["emoji_v2"]?.string ?? iconType?["icon"]?.string ?? iconType?["symbol"]?.string
            return result
        }

        mutating func tab(_ raw: ArcJSON, key: String) -> ArcImportedTab? {
            guard let data = raw["data"]?["tab"], data.isObject else { return nil }
            let value = data["savedURL"] ?? data["url"]
            guard let text = value?.string else {
                if value == nil || value == .null || value == .string("") { diagnostics.missingURLs += 1 }
                else { diagnostics.invalidURLs += 1 }
                return nil
            }
            guard let url = ArcSidebarParser.webURL(text) else { diagnostics.invalidURLs += 1; return nil }
            return ArcImportedTab(sourceID: key, savedURL: url, savedTitle: data["savedTitle"]?.string,
                                  customTitle: raw["title"]?.string, createdAt: timestamp(raw["createdAt"]),
                                  lastActiveAt: timestamp(data["timeLastActiveAt"]))
        }

        // MARK: Sidebar tree

        mutating func parseContainer(_ container: ArcJSON) {
            var walker = TreeWalker()
            for entry in ArcRecordCollection.records(container["items"], malformed: { diagnostics.malformedRecords += 1 }) {
                guard let id = entry.key ?? entry.record["id"]?.string, entry.record.isObject else {
                    diagnostics.malformedRecords += 1
                    continue
                }
                guard walker.items[id] == nil else { diagnostics.duplicateItems += 1; continue }
                walker.items[id] = entry.record
                walker.order.append(id)
                if let parent = entry.record["parentID"]?.string { walker.parentChildren[parent, default: []].append(id) }
            }

            // Favorites first, then Spaces, in source order (same precedence as the Electron parser).
            for (reference, root) in ArcRecordCollection.pairs(container["topAppsContainerIDs"],
                                                               malformed: { diagnostics.malformedRecords += 1 }) {
                guard let rootID = root.rawIdentifier else { diagnostics.malformedRecords += 1; continue }
                let profile = profileKey(for: reference)
                let nodes = walker.visit(rootID, depth: 0, builder: &self)
                favorites.append(ArcImportedFavorites(profile: profile, tabs: flattened(nodes)))
            }

            for entry in ArcRecordCollection.records(container["spaces"], malformed: { diagnostics.malformedRecords += 1 }) {
                guard let id = entry.key ?? entry.record["id"]?.string, entry.record.isObject else {
                    diagnostics.malformedRecords += 1
                    continue
                }
                guard spaceIDs.insert(id).inserted else { diagnostics.duplicateSpaces += 1; continue }
                let record = entry.record
                let profile = profileKey(for: record["profile"])
                note(profile)
                if case let .unresolved(key) = profile, unresolved.insert(key).inserted { diagnostics.unresolvedProfiles += 1 }
                var roots: [String: String] = [:]
                // `newContainerIDs` encodes keys as Swift enums and wins over `containerIDs` (observed).
                for (tag, root) in ArcRecordCollection.pairs(record["containerIDs"], malformed: { diagnostics.malformedRecords += 1 })
                    + ArcRecordCollection.pairs(record["newContainerIDs"], malformed: { diagnostics.malformedRecords += 1 }) {
                    let kind = tag.string ?? (tag.has("pinned") ? "pinned" : tag.has("unpinned") ? "unpinned" : nil)
                    if let kind, kind == "pinned" || kind == "unpinned", let rootID = root.rawIdentifier { roots[kind] = rootID }
                }
                let pinned = roots["pinned"].map { walker.visit($0, depth: 0, builder: &self) } ?? []
                let today = roots["unpinned"].map { flattened(walker.visit($0, depth: 0, builder: &self)) } ?? []
                spaces.append(ArcImportedSpace(sourceID: id, profile: profile,
                    title: record["title"]?.string ?? record["name"]?.string, appearance: appearance(record),
                    pinned: pinned, today: today))
            }
            for id in walker.order where !walker.visited.contains(id) {
                if walker.items[id]?["data"]?.has("itemContainer") != true { diagnostics.disconnectedItems += 1 }
            }
            for favorite in favorites { note(favorite.profile) }
        }

        mutating func flattened(_ nodes: [ArcImportedNode]) -> [ArcImportedTab] {
            var result: [ArcImportedTab] = []
            var stack = Array(nodes.reversed())
            while let node = stack.popLast() {
                switch node {
                case let .tab(tab): result.append(tab)
                case let .folder(folder):
                    diagnostics.flattenedFolders += 1
                    stack.append(contentsOf: folder.children.reversed())
                }
            }
            return result
        }

        // MARK: Archive

        mutating func parseArchive(_ document: ArcJSON) {
            let source = document["items"] ?? document["archive"]?["items"] ?? (document.array != nil ? document : nil)
            var keys: Set<String> = []
            for entry in ArcRecordCollection.records(source, malformed: { diagnostics.malformedRecords += 1 }) {
                let record = entry.record
                guard record.isObject, let item = record["sidebarItem"], item.isObject else {
                    diagnostics.malformedRecords += 1
                    continue
                }
                let key = entry.key ?? record["id"]?.string ?? "fallback:" + ArcSidebarParser.digest(
                    ArcJSON.array([item["id"] ?? .null, record["archivedAt"] ?? .null, record["source"] ?? .null,
                                   item["data"] ?? .null]).canonical)
                guard keys.insert(key).inserted else { diagnostics.duplicateArchives += 1; continue }
                guard item["data"]?.has("tab") == true else { diagnostics.unsupportedItems += 1; continue }
                let origin = record["source"]
                let spaceID = origin?["space"]?.rawIdentifier
                var profile: ArcProfileKey?
                if spaceID == nil {
                    let reference = origin?["profile"] ?? origin?["littleArc"]?["profile"] ?? record["profile"]
                    if let reference, reference != .null { profile = profileKey(for: reference) }
                    else { diagnostics.unattributedArchives += 1 }
                }
                let archivedAt = timestamp(record["archivedAt"])
                guard let tab = tab(item, key: key) else { continue }
                var reason = record["reason"]?.string
                if reason == nil, let keys = record["reason"]?.object?.keys, keys.count == 1 { reason = keys.first }
                archive.append(ArcImportedArchiveRecord(key: key, tab: tab, archivedAt: archivedAt, reason: reason,
                                                        spaceSourceID: spaceID, profile: profile))
            }
        }
    }

    /// Order comes only from `childrenIds` (observed); `parentID` links recover omitted children.
    private struct TreeWalker {
        var items: [String: ArcJSON] = [:]
        var order: [String] = []
        var parentChildren: [String: [String]] = [:]
        var visited: Set<String> = []
        var visiting: Set<String> = []

        func childIDs(_ id: String, _ raw: ArcJSON, builder: inout Builder) -> [String] {
            var children = (raw["childrenIds"]?.array ?? []).compactMap(\.string)
            var listed = Set(children)
            for child in parentChildren[id] ?? [] where listed.insert(child).inserted {
                children.append(child)
                builder.diagnostics.recoveredParentReferences += 1
            }
            return children
        }

        mutating func visit(_ id: String, depth: Int, builder: inout Builder) -> [ArcImportedNode] {
            guard depth <= ArcSidebarParser.maximumDepth else { builder.diagnostics.depthLimit += 1; return [] }
            guard !visiting.contains(id) else { builder.diagnostics.cycles += 1; return [] }
            guard !visited.contains(id) else { builder.diagnostics.repeatedReferences += 1; return [] }
            guard let raw = items[id] else { builder.diagnostics.missingReferences += 1; return [] }
            visiting.insert(id)
            visited.insert(id)
            defer { visiting.remove(id) }
            let data = raw["data"]
            var children: [ArcImportedNode] = []
            for child in childIDs(id, raw, builder: &builder) {
                children += visit(child, depth: depth + 1, builder: &builder)
            }
            if data?.has("tab") == true {
                return (builder.tab(raw, key: id).map { [ArcImportedNode.tab($0)] } ?? []) + children
            }
            if let list = data?["list"] {
                let collapsed = list["isCollapsed"]?.bool ?? raw["isCollapsed"]?.bool ?? false
                return [.folder(ArcImportedFolder(sourceID: id, title: raw["title"]?.string, isCollapsed: collapsed,
                                                  createdAt: builder.timestamp(raw["createdAt"]), children: children))]
            }
            if data?.has("splitView") == true {
                builder.diagnostics.flattenedSplits += 1
                return children
            }
            if data?.has("itemContainer") != true { builder.diagnostics.unsupportedItems += 1 }
            return children
        }
    }
}
