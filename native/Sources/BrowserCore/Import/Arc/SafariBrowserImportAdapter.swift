import Foundation
import SQLite3
import Darwin
import CryptoKit

/// Official export only. No installed application, protected directory or source Keychain access.
/// A caller assigns shared bookmarks/passwords to exactly one selected profile in a multi-profile
/// export, using includeSharedData=false for the others. Placement text comes from localized UI.
public struct SafariBrowserImportAdapter: BrowserImportSourceAdapter {
    public let descriptor = BrowserImportDescriptor(id: "safari", name: "Safari", bundleID: "com.apple.Safari", supportPath: "")
    public let registration: BrowserImportRegistration
    public let profile: BrowserImportSourceProfile
    public let placement: ChromiumImportPlacement
    public let includeSharedData: Bool
    public init(installationID: UUID, profile: BrowserImportSourceProfile, placement: ChromiumImportPlacement, includeSharedData: Bool) {
        registration = .init(sourceID: "safari", installationID: installationID)
        self.profile = profile; self.placement = placement; self.includeSharedData = includeSharedData
    }
    struct Inventory: Codable {
        var histories: [String: String] = [:]
        var counts: [String: Int] = [:]
        var aggregateVisits: [String: Int] = [:]
        var bookmarks = false, passwords = false
    }
    public func discoverProfiles(metadata: Data) throws -> [BrowserImportSourceProfile] {
        guard metadata.count <= 1_048_576 else { throw ArcImportError.unsupportedSourceFile }
        let inventory = try JSONDecoder().decode(Inventory.self, from: metadata)
        return inventory.histories.keys.sorted().map { .init(directory: $0, name: $0) }
    }
    public static func inventoryData(snapshot: ArcSourceSnapshot) throws -> Data {
        guard let data = try OrbitSecureDirectory.open(snapshot.directory, create: false).read("Inventory.json", limit: 1_048_576) else { throw ArcImportError.unreadableSourceDocument }
        return data
    }
    public func snapshot(source: URL, parent: URL, probe: any ArcRunningProbe, diskSpace: any OrbitDiskSpaceProbe) throws -> ArcSourceSnapshot {
        guard source.pathExtension.lowercased() == "zip" else { throw ArcImportError.unsupportedSourceFile }
        let copy = try ArcSourceSnapshot.captureManifest(source: source.deletingLastPathComponent(),
            plan: [(source.lastPathComponent, Int64(SafariExportArchive.maximumBytes), true)], historyDirectories: [], historyPrefix: "",
            parent: parent, probe: BrowserImportRunningProbe(running: { false }), diskSpace: diskSpace)
        do {
            let root = try OrbitSecureDirectory.open(copy.directory, create: false)
            try OrbitDiskSpace.require(Int64(SafariExportArchive.maximumBytes), at: parent, probe: diskSpace)
            var inventory = Inventory(), histories: [String: URL] = [:], recognized = 0
            try SafariExportArchive.read(copy.directory.appendingPathComponent(source.lastPathComponent), entry: { name, read in
                let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                if ext == "html" {
                    guard !inventory.bookmarks else { throw ArcImportError.unsupportedSourceFile }
                    let output = FileHandle(fileDescriptor: try root.openFile("Bookmarks.html", flags: O_WRONLY | O_CREAT | O_EXCL), closeOnDealloc: true)
                    while true { let chunk = try read(); if chunk.isEmpty { break }; try output.write(contentsOf: chunk) }
                    try output.close()
                    _ = try SafariBookmarkReader.nodes(root.url.appendingPathComponent("Bookmarks.html"), identity: .init(namespace: "validation"), importedAt: Date())
                    inventory.bookmarks = true; recognized += 1
                } else if ext == "csv" {
                    guard !inventory.passwords else { throw ArcImportError.unsupportedSourceFile }
                    var data = Data()
                    while true { let chunk = try read(); if chunk.isEmpty { break }; data.append(chunk); guard data.count <= 32 * 1024 * 1024 else { throw BrowserAuthenticationImportError.invalidCSV } }
                    let result = try BrowserPasswordCSV.read(data)
                    inventory.counts["passwords"] = result.passwords.count
                    inventory.counts["notes"] = result.unrepresentedNotes
                    inventory.counts["otp"] = result.unrepresentedOTP
                    inventory.counts["passkeys"] = result.unrepresentedPasskeys
                    inventory.counts["unsupportedPasswords"] = result.unsupported
                    try root.write(data, to: "Passwords.csv"); inventory.passwords = true; recognized += 1
                } else if ext == "json" {
                    var aggregate = 0
                    var database: AuthenticationSQLite?
                    let canonical = "History-\(histories.count)"
                    let result = try SafariExportJSON(read: read).scan { type, row in
                        if type == "history" {
                            guard let visits = SafariExportJSON.integer(row["visits_count"]), visits > 0,
                                  visits <= 1_000_000_000, SafariExportJSON.integer(row["time_usec"]) != nil,
                                  row["url"] is String else { throw ArcImportError.unreadableSourceDocument }
                            aggregate += Int(visits - 1)
                            if database == nil {
                                try root.write(Data(), to: canonical)
                                database = try AuthenticationSQLite(root.url.appendingPathComponent(canonical))
                                try database!.execute("CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT); CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER); BEGIN")
                            }
                            let time = SafariExportJSON.integer(row["time_usec"])!
                            let hash = SHA256.hash(data: Data((String(time) + "\u{1f}" + (row["url"] as! String)).utf8))
                            let historyID = max(1, hash.prefix(8).reduce(Int64(0)) { ($0 << 8) | Int64($1) } & Int64.max)
                            let db = database!
                            let insert = try db.statement("INSERT OR IGNORE INTO urls VALUES(?,?,?)")
                            defer { sqlite3_finalize(insert) }
                            sqlite3_bind_int64(insert, 1, historyID)
                            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                            sqlite3_bind_text(insert, 2, row["url"] as! String, -1, transient)
                            sqlite3_bind_text(insert, 3, row["title"] as? String ?? "", -1, transient)
                            guard sqlite3_step(insert) == SQLITE_DONE else { throw ArcImportError.historyDatabaseUnreadable }
                            // Preserve invalid dates as zero so the shared history filters count them.
                            let converted = time < 4_102_444_800_000_000 && time > 0 ? time + 11_644_473_600_000_000 : 0
                            try db.execute("INSERT OR IGNORE INTO visits VALUES(\(historyID),\(historyID),\(converted))")
                        }
                    }
                    if result.type == "history" {
                        let key = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
                        guard inventory.histories[key] == nil else { throw ArcImportError.unsupportedSourceFile }
                        if let database { try database.execute("COMMIT") }
                        else {
                            try root.write(Data(), to: canonical)
                            let empty = try AuthenticationSQLite(root.url.appendingPathComponent(canonical))
                            try empty.execute("CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT); CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER)")
                        }
                        inventory.histories[key] = canonical; histories[key] = root.url.appendingPathComponent(canonical)
                        inventory.aggregateVisits[key] = aggregate
                    } else { inventory.counts[result.type, default: 0] += result.count }
                    recognized += 1
                } else { inventory.counts["unsupportedFiles", default: 0] += 1 }
            })
            guard recognized > 0 else { throw ArcImportError.unsupportedSourceFile }
            if histories.isEmpty { inventory.histories["Default"] = "" }
            try root.write(JSONEncoder().encode(inventory), to: "Inventory.json")
            try root.removeChecked(source.lastPathComponent)
            copy.historyDatabases = histories
            return copy
        } catch { copy.remove(); throw error }
    }
    public func makePlan(snapshot: ArcSourceSnapshot, ledger: BrowserImportLedger, defaultProfile: ProfileID?, importedAt: Date) throws -> BrowserImportSourcePlan {
        let inventory = try JSONDecoder().decode(Inventory.self, from: Self.inventoryData(snapshot: snapshot))
        guard inventory.histories[profile.directory] != nil else { throw ArcImportError.sourceNotFound }
        let key = registration.profileKey(profile.directory), identity = ArcImportIdentity(namespace: registration.profileKey(profile.directory))
        let id = ledger.profileMappings[key].map(ProfileID.init) ?? identity.profile(.directory(profile.directory))
        var plan = BrowserImportPlan(); plan.registration = registration
        plan.profiles = [.init(id: id, sourceKey: .directory(profile.directory), name: profile.name, sourceDirectory: profile.directory, isAdopted: false, mappingKey: key)]
        let space = identity.space("bookmarks")
        plan.spaces = [.init(id: space, profileID: id, name: placement.importedSpace, appearance: .init())]
        let bookmarks = includeSharedData && inventory.bookmarks ? try SafariBookmarkReader.nodes(snapshot.directory.appendingPathComponent("Bookmarks.html"), identity: identity, importedAt: importedAt) : []
        plan.sections = [.init(spaceID: space, pinned: bookmarks.isEmpty ? [] : [.folder(.init(id: identity.folder("imported-bookmarks"), title: placement.bookmarkFolder, isCollapsed: false, children: [], createdAt: importedAt), bookmarks)], today: [])]
        if snapshot.historyDatabases[profile.directory] != nil { plan.historySources = [.init(profileID: id, directory: profile.directory)] }
        var result = BrowserImportSourcePlan(plan: plan, capabilities: ["bookmarks": bookmarks.isEmpty ? .empty : .supported,
            "history": plan.historySources.isEmpty ? .empty : .supported, "passwords": includeSharedData && inventory.passwords ? .supported : .empty,
            "payment_cards": .unsupported, "extensions": .unsupported, "notes": .unsupported, "otp": .unsupported, "passkeys": .unsupported])
        var counts = inventory.counts
        counts["aggregateVisitsWithoutTimestamps"] = inventory.aggregateVisits[profile.directory] ?? 0
        if !includeSharedData { for key in ["passwords", "notes", "otp", "passkeys", "unsupportedPasswords"] { counts.removeValue(forKey: key) } }
        result.sourceCounts = counts
        result.notImported = ["cookies", "tabs", "extensions", "payment_cards", "passkeys", "notes", "otp", "siteData", "settings", "downloads"]
        return result
    }
    public func historyReader(file: URL, directory: String) throws -> any BrowserImportHistoryReader {
        try ArcChromiumHistoryReader(snapshotFile: file, directory: directory, identity: .init(namespace: registration.namespace))
    }
    public func passwords(snapshot: ArcSourceSnapshot) throws -> ChromiumPasswordReadResult {
        let root = try OrbitSecureDirectory.open(snapshot.directory, create: false)
        guard includeSharedData, root.exists("Passwords.csv") else { return .init() }
        guard let data = root.read("Passwords.csv", limit: 32 * 1024 * 1024) else { throw BrowserAuthenticationImportError.invalidCSV }
        return try BrowserPasswordCSV.read(data)
    }
}
