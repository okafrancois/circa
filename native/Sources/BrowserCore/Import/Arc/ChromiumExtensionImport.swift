import CryptoKit
import Darwin
import Foundation

/// Closed-runtime migration of internal user packages. Browser credentials and extension storage
/// are deliberately excluded. Chromium remains responsible for manifest and content verification.
enum ChromiumExtensionImport {
    static let fileLimit = 64 * 1024 * 1024
    static let totalLimit = 256 * 1024 * 1024

    static func manifest(in profile: OrbitSecureDirectory, prefix: String) throws -> [(relative: String, limit: Int64?, required: Bool)] {
        var result: [(relative: String, limit: Int64?, required: Bool)] = []
        var bytes: Int64 = 0
        func walk(_ folder: OrbitSecureDirectory, _ path: String, depth: Int) throws {
            guard depth < 32 else { throw ArcImportError.unsupportedSourceFile }
            for name in try folder.checkedEntries().sorted() {
                let relative = path + "/" + name
                switch try folder.checkedKind(name) {
                case S_IFDIR?: try walk(folder.directory(name, create: false), relative, depth: depth + 1)
                case S_IFREG?:
                    bytes += folder.size(name)
                    guard folder.size(name) <= fileLimit, bytes <= totalLimit, result.count < 20_000 else { throw ArcImportError.unsupportedSourceFile }
                    result.append((prefix + relative, Int64(fileLimit), true))
                default: throw ArcImportError.unsupportedSourceFile
                }
            }
        }
        for name in ["Preferences", "Secure Preferences"] where profile.exists(name) {
            result.append((prefix + name, Int64(fileLimit), true))
        }
        if profile.exists("Extensions") { try walk(profile.directory("Extensions", create: false), "Extensions", depth: 0) }
        return result
    }

    /// Private snapshots retain only extension import fields, never the source preference file
    /// as a whole, account metadata, encryption material or source integrity hashes.
    static func preferenceSnapshot(_ data: Data) throws -> Data {
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Data("{\"extensions\":{\"settings\":{}}}".utf8)
        }
        let extensions = document["extensions"] as? [String: Any] ?? [:]
        let fields: Set<String> = ["location", "path", "manifest", "state", "disable_reasons",
            "was_installed_by_default", "was_installed_by_oem", "from_webstore", "active_permissions",
            "granted_permissions", "withholding_permissions", "blacklist_state", "omaha_blocklist_state",
            "extension_telemetry_service_blocklist_state"]
        var projected: [String: Any] = [:]
        if let settings = extensions["settings"] as? [String: [String: Any]] {
            projected["settings"] = settings.mapValues { entry in entry.filter { fields.contains($0.key) } }
        }
        if let pins = extensions["pinned_extensions"] as? [String] { projected["pinned_extensions"] = pins }
        return try JSONSerialization.data(withJSONObject: ["extensions": projected], options: [.sortedKeys])
    }

    struct Payload { var files: [String: Data] = [:]; var count = 0; var skipped = 0 }
    static func read(snapshot: ArcSourceSnapshot, directory: String, arc: Bool) throws -> Payload {
        let root = try OrbitSecureDirectory.open(snapshot.directory, create: false)
        let relative = (arc ? "User Data/" : "") + directory
        guard let profile = try? root.directory(relative, create: false) else { return Payload() }
        func json(_ name: String) -> [String: Any] {
            guard let data = profile.read(name, limit: fileLimit) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        let plain = json("Preferences"), secure = json("Secure Preferences")
        let protected = secure["extensions"] as? [String: Any] ?? [:]
        let ordinary = plain["extensions"] as? [String: Any] ?? [:]
        let entries = protected["settings"] as? [String: [String: Any]] ?? ordinary["settings"] as? [String: [String: Any]] ?? [:]
        var payload = Payload(), settings: [String: Any] = [:]
        for (id, entry) in entries.sorted(by: { $0.key < $1.key }) {
            do {
                guard id.count == 32, id.utf8.allSatisfy({ (97...112).contains($0) }),
                      entry["location"] as? Int == 1,
                      ["blacklist_state", "omaha_blocklist_state", "extension_telemetry_service_blocklist_state"].allSatisfy({ entry[$0] == nil || entry[$0] as? Int == 0 }),
                      entry["was_installed_by_default"] as? Bool != true,
                      entry["was_installed_by_oem"] as? Bool != true,
                      let cached = entry["manifest"] as? [String: Any],
                      cached["manifest_version"] as? Int == 3,
                      let key = cached["key"] as? String, let keyData = Data(base64Encoded: key),
                      SHA256.hash(data: keyData).prefix(16).flatMap({ [$0 >> 4, $0 & 15] }).map({ String(UnicodeScalar(Int($0) + 97)!) }).joined() == id,
                      let path = entry["path"] as? String else { throw ArcImportError.unsupportedSourceFile }
                let parts = path.split(separator: "/")
                guard parts.count >= 2, parts[parts.count - 2] == Substring(id),
                      let version = parts.last, version.allSatisfy({ $0.isNumber || $0 == "." || $0 == "_" }), !version.isEmpty else { throw ArcImportError.unsupportedSourceFile }
                let packagePath = "Extensions/" + id + "/" + version
                let package = try profile.directory(packagePath, create: false)
                guard let manifestData = package.read("manifest.json", limit: fileLimit),
                      let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                      manifest["version"] as? String == cached["version"] as? String,
                      manifest["key"] as? String == key, manifest["manifest_version"] as? Int == 3 else { throw ArcImportError.unsupportedSourceFile }
                var reasons: [Int]
                if let list = entry["disable_reasons"] as? [Int], list.allSatisfy({ $0 > 0 && $0 <= Int32.max }) { reasons = list }
                else if let mask = entry["disable_reasons"] as? Int, mask >= 0, mask <= Int32.max { reasons = (0..<31).map { 1 << $0 }.filter { mask & $0 != 0 } }
                else if entry["disable_reasons"] == nil { reasons = [] }
                else { throw ArcImportError.unsupportedSourceFile }
                // Legacy disabled state must never become enabled when reasons are absent.
                if let state = entry["state"] as? Int {
                    guard state == 0 || state == 1 else { throw ArcImportError.unsupportedSourceFile }
                    if state == 0 && reasons.isEmpty { reasons = [1] }
                } else if entry["disable_reasons"] == nil { throw ArcImportError.unsupportedSourceFile }
                var files: [String: Data] = [:]
                func collect(_ folder: OrbitSecureDirectory, path: String) throws {
                    for name in try folder.checkedEntries() {
                        if folder.kind(name) == S_IFDIR { try collect(folder.directory(name, create: false), path: path + "/" + name) }
                        else {
                            guard let data = folder.read(name, limit: fileLimit) else { throw ArcImportError.unsupportedSourceFile }
                            files[path + "/" + name] = data
                        }
                    }
                }
                try collect(package, path: packagePath)
                var target: [String: Any] = ["location": 1, "path": id + "/" + version, "manifest": manifest, "disable_reasons": reasons, "from_webstore": entry["from_webstore"] as? Bool ?? false]
                for name in ["active_permissions", "granted_permissions", "withholding_permissions"] {
                    target[name] = entry[name]
                }
                settings[id] = target
                payload.files.merge(files) { first, _ in first }; payload.count += 1
            } catch { payload.skipped += 1 }
        }
        if !settings.isEmpty {
            let pinned = (ordinary["pinned_extensions"] as? [String] ?? protected["pinned_extensions"] as? [String] ?? []).filter { settings[$0] != nil }
            payload.files["OrbitExtensionImport.json"] = try JSONSerialization.data(withJSONObject: ["extensions": ["settings": settings, "pinned_extensions": pinned]], options: [.sortedKeys])
        }
        return payload
    }
}
