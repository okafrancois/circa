import Foundation
import SQLite3

/// Mozilla's eight-byte magic, little-endian decoded size and a raw LZ4 block. Allocation,
/// literals, overlapping matches and the exact decoded length are independently bounded.
enum MozLz4 {
    static let maximumBytes = 32 * 1024 * 1024
    static func decode(_ data: Data) throws -> Data {
        let bytes = Array(data)
        guard bytes.count >= 12, bytes.count <= maximumBytes, Array(bytes.prefix(8)) == Array("mozLz40\0".utf8) else { throw ArcImportError.unsupportedSourceFile }
        let size = (0..<4).reduce(0) { $0 | Int(bytes[8 + $1]) << (8 * $1) }
        guard size > 0, size <= maximumBytes else { throw ArcImportError.unsupportedSourceFile }
        var output = Data(); output.reserveCapacity(size)
        var index = 12
        func length(_ initial: Int) throws -> Int {
            var result = initial
            if initial == 15 {
                while true {
                    guard index < bytes.count else { throw ArcImportError.unreadableSourceDocument }
                    let byte = Int(bytes[index]); index += 1; result += byte
                    guard result <= size else { throw ArcImportError.unsupportedSourceFile }
                    if byte != 255 { break }
                }
            }
            return result
        }
        while index < bytes.count {
            let token = bytes[index]; index += 1
            let literals = try length(Int(token >> 4))
            guard literals <= bytes.count - index, literals <= size - output.count else { throw ArcImportError.unreadableSourceDocument }
            output.append(contentsOf: bytes[index..<(index + literals)]); index += literals
            if index == bytes.count { break }
            guard index + 2 <= bytes.count else { throw ArcImportError.unreadableSourceDocument }
            let offset = Int(bytes[index]) | Int(bytes[index + 1]) << 8; index += 2
            let match = try length(Int(token & 15)) + 4
            guard offset > 0, offset <= output.count, match <= size - output.count else { throw ArcImportError.unreadableSourceDocument }
            for _ in 0..<match { output.append(output[output.count - offset]) }
        }
        guard output.count == size else { throw ArcImportError.unreadableSourceDocument }
        return output
    }
}

enum FirefoxSessionReader {
    // Source-defined load order: clean shutdown, crash recovery, prior crash backup, previous
    // clean shutdown. Modification times never decide which session is current.
    static let files = ["sessionstore.jsonlz4", "sessionstore-backups/recovery.jsonlz4", "sessionstore-backups/recovery.baklz4", "sessionstore-backups/previous.jsonlz4"]
    struct Tab { let url: URL; let title: String?; let pinnedURL: URL? }
    struct Window { let name: String?; let tabs: [Tab] }
    struct Result { var windows: [Window] = []; var counts: [String: Int] = [:]; var capability: BrowserImportCapability = .empty }
    static func json(_ data: Data) throws -> [String: Any] {
        guard data.count <= MozLz4.maximumBytes else { throw ArcImportError.unsupportedSourceFile }
        var depth = 0, string = false, escape = false
        for byte in data {
            if string {
                if escape { escape = false } else if byte == 92 { escape = true } else if byte == 34 { string = false }
            } else if byte == 34 { string = true }
            else if byte == 91 || byte == 123 { depth += 1; guard depth <= 64 else { throw ArcImportError.unsupportedSourceFile } }
            else if byte == 93 || byte == 125 { depth -= 1 }
        }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ArcImportError.unreadableSourceDocument }
        return value
    }
    static func read(root: OrbitSecureDirectory, zen: Bool) throws -> Result {
        var result = Result(), selected: [String: Any]?
        for file in files {
            let components = file.split(separator: "/").map(String.init)
            let folder = components.count == 1 ? root : try? root.directory(components[0], create: false)
            guard let folder, folder.exists(components.last!) else { continue }
            do {
                guard let data = folder.read(components.last!, limit: MozLz4.maximumBytes) else { throw ArcImportError.unreadableSourceDocument }
                let value = try json(MozLz4.decode(data))
                guard let version = value["version"] as? [Any], version.count == 2, version[0] as? String == "sessionrestore",
                      version[1] as? Int == 1, value["windows"] is [[String: Any]] else { throw ArcImportError.unsupportedSourceFile }
                selected = value; result.capability = .supported; break
            } catch { result.counts["invalidSessionFiles", default: 0] += 1; result.capability = .unsupportedVersion }
        }
        var windows = selected?["windows"] as? [[String: Any]] ?? []
        result.counts["closedWindows"] = (selected?["_closedWindows"] as? [Any])?.count ?? 0
        // Current sidebar shape: spaces/tabs/groups/folders at the top level. Only plain,
        // non-container workspaces and tabs are representable; grouping is counted separately.
        if zen, let data = root.read("zen-sessions.jsonlz4", limit: MozLz4.maximumBytes) {
            let sidebar = try json(MozLz4.decode(data))
            if sidebar["spaces"] is [[String: Any]], sidebar["tabs"] is [[String: Any]] {
                windows = [sidebar]; result.capability = .supported
            } else { result.counts["unsupportedZenSidebar", default: 0] += 1 }
        }
        if zen, root.exists("places.sqlite"), windows.contains(where: { $0["spaces"] == nil }) {
            let db = try FirefoxPlacesReader.database(root.url.appendingPathComponent("places.sqlite"))
            if try FirefoxPlacesReader.integer(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='zen_workspaces'") == 1 {
                let row = try db.statement("SELECT uuid,name,container_id FROM zen_workspaces ORDER BY position,created_at,uuid")
                defer { sqlite3_finalize(row) }
                var spaces: [[String: Any]] = [], step = sqlite3_step(row)
                while step == SQLITE_ROW {
                    guard spaces.count < 128 else { throw ArcImportError.unsupportedSourceFile }
                    spaces.append(try ["uuid": AuthenticationSQLite.text(row, 0), "name": AuthenticationSQLite.text(row, 1), "containerTabId": Int(sqlite3_column_int(row, 2))])
                    step = sqlite3_step(row)
                }
                guard step == SQLITE_DONE else { throw ArcImportError.unreadableSourceDocument }
                for index in windows.indices where windows[index]["spaces"] == nil { windows[index]["spaces"] = spaces }
            }
        }
        guard windows.count <= 128 else { throw ArcImportError.unsupportedSourceFile }
        var total = 0
        for window in windows {
            if window["isPrivate"] as? Bool == true { result.counts["privateWindows", default: 0] += 1; continue }
            result.counts["unsupportedSessionCookies", default: 0] += (window["cookies"] as? [Any])?.count ?? 0
            result.counts["closedTabs", default: 0] += (window["_closedTabs"] as? [Any])?.count ?? 0
            var spaces: [(String, String)] = []
            var rejectedSpaces = Set<String>()
            if zen {
                for value in window["spaces"] as? [[String: Any]] ?? [] {
                    guard let id = value["uuid"] as? String, let name = value["name"] as? String,
                          (value["containerTabId"] == nil || value["containerTabId"] as? Int == 0), !spaces.contains(where: { $0.0 == id }) else {
                        if let id = value["uuid"] as? String { rejectedSpaces.insert(id) }
                        result.counts["unsupportedWorkspaces", default: 0] += 1; continue
                    }
                    spaces.append((id, name))
                }
                result.counts["unsupportedZenGroups", default: 0] += (window["groups"] as? [Any])?.count ?? 0
                result.counts["unsupportedZenFolders", default: 0] += (window["folders"] as? [Any])?.count ?? 0
            }
            var grouped: [String: [Tab]] = [:]
            for value in window["tabs"] as? [[String: Any]] ?? [] {
                total += 1; guard total <= 100_000 else { throw ArcImportError.unsupportedSourceFile }
                let workspace = zen ? value["zenWorkspace"] as? String ?? "" : ""
                if value["isPrivate"] as? Bool == true || (value["userContextId"] != nil && value["userContextId"] as? Int != 0) ||
                    value["originAttributes"] != nil || rejectedSpaces.contains(workspace) {
                    result.counts["unsupportedIsolatedTabs", default: 0] += 1; continue
                }
                guard let entries = value["entries"] as? [[String: Any]], entries.count <= 10_000,
                      let index = value["index"] as? Int, index > 0, index <= entries.count,
                      let text = entries[index - 1]["url"] as? String, let url = ChromiumBookmarkReader.safeURL(text) else {
                    result.counts["unsupportedTabs", default: 0] += 1; continue
                }
                if !workspace.isEmpty && !spaces.contains(where: { $0.0 == workspace }) {
                    result.counts["unsupportedWorkspaceReferences", default: 0] += 1; continue
                }
                var pinned: URL? = value["pinned"] as? Bool == true || (zen && value["zenEssential"] as? Bool == true) ? url : nil
                if zen, let initial = value["_zenPinnedInitialState"] as? [String: Any] {
                    guard let entry = initial["entry"] as? [String: Any], let text = entry["url"] as? String, let base = ChromiumBookmarkReader.safeURL(text) else {
                        result.counts["unsupportedPinnedState", default: 0] += 1; continue
                    }
                    pinned = base
                }
                grouped[spaces.contains(where: { $0.0 == workspace }) ? workspace : "", default: []].append(
                    Tab(url: url, title: BrowserOrganizationState.sanitizedPageTitle(entries[index - 1]["title"] as? String), pinnedURL: pinned))
            }
            if let tabs = grouped[""] { result.windows.append(.init(name: nil, tabs: tabs)) }
            guard spaces.count <= 128 else { throw ArcImportError.unsupportedSourceFile }
            for (id, name) in spaces { result.windows.append(.init(name: name, tabs: grouped[id] ?? [])) }
        }
        return result
    }
}
