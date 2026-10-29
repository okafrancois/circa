import Foundation

/// Bounded, no-follow metadata access for the explicit native import picker. Content stores are
/// never opened by discovery. Missing/unreadable metadata is a selectable unavailable source.
public enum BrowserImportMetadata {
    public static func read(root: URL, name: String, limit: Int = 1_048_576) throws -> Data {
        guard ["Local State", "profiles.ini", "installs.ini"].contains(name) else { throw ArcImportError.unsupportedSourceFile }
        guard let bytes = try OrbitSecureDirectory.open(root, create: false).read(name, limit: limit) else {
            throw ArcImportError.sourceNotFound
        }
        return bytes
    }
    public static func readCSV(_ file: URL) throws -> Data {
        guard file.pathExtension.lowercased() == "csv",
              let bytes = try OrbitSecureDirectory.open(file.deletingLastPathComponent(), create: false)
                .read(file.lastPathComponent, limit: 32 * 1024 * 1024) else { throw BrowserAuthenticationImportError.invalidCSV }
        _ = try BrowserPasswordCSV.read(bytes)
        return bytes
    }
    public static func readResult(root: URL) throws -> Data? {
        try OrbitSecureDirectory.open(root, create: false).read("browser-import-result.json", limit: 65536)
    }
    public static func writeResult(_ bytes: Data, root: URL) throws {
        try OrbitSecureDirectory.open(root, create: false).write(bytes, to: "browser-import-result.json")
    }
    public static func removeResult(root: URL) throws {
        try OrbitSecureDirectory.open(root, create: false).removeChecked("browser-import-result.json")
    }
}
