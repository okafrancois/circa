import AppKit
import CoreGraphics
import BrowserCore
import CryptoKit
import Foundation
import SQLite3

// Fixture operations only. No system Keychain and no personal profile locations.
@main
struct SiteSessionFixture {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let command = arguments[1]
        if command == "windows" || command == "activate" {
            let pid = Int32(arguments[2])!
            if command == "activate" {
                NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
            } else {
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                func area(_ window: [String: Any]) -> Double {
                    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
                    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
                }
                for window in windows.sorted(by: { area($0) < area($1) }) where (window[kCGWindowOwnerPID as String] as? Int32) == pid && area(window) > 15_000 {
                    print(window[kCGWindowNumber as String]!)
                }
            }
            return
        }
        let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
        guard root.path.hasPrefix("/"), !root.path.contains("/Library/") else { fatalError("Fixture root required") }
        if command == "seed" {
            let store = BrowserStore()
            let profile = await store.createProfile(name: "Session Fixture")
            let space = try await store.createSpace(name: "Connections", profileID: profile)
            let window = try await store.createWindow(activeSpaceID: space)
            let context = try await store.captureContext(in: window)
            _ = try await store.openTab(url: URL(string: arguments[3])!, from: context, activate: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let document = await store.sessionDocument()
            try document.encoded().write(to: root.appendingPathComponent("session.json"))
            var ledger = BrowserImportLedger()
            ledger.profileMappings[ArcProfileKey.directory("Default").ledgerKey] = profile.rawValue
            let imports = root.appendingPathComponent("Import")
            try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
            try JSONEncoder().encode(ledger).write(to: imports.appendingPathComponent("orbit-import-ledger.json"))
            print(profile.rawValue.uuidString.lowercased())
        } else if command == "rekey" {
            let sourceKey = try ArcChromiumCookieCipher.deriveKey(password: Data("mock_password".utf8))
            let targetKey = try ArcChromiumCookieCipher.deriveKey(password: Data("fixture-orbit-password".utf8))
            var db: OpaquePointer?
            guard sqlite3_open(root.appendingPathComponent("Cookies").path, &db) == SQLITE_OK else { fatalError("Fixture database unavailable") }
            defer { sqlite3_close(db) }
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { fatalError("Fixture transaction failed") }
            var rows: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT rowid,host_key,encrypted_value FROM cookies", -1, &rows, nil) == SQLITE_OK else { fatalError("Fixture schema unavailable") }
            defer { sqlite3_finalize(rows) }
            var count = 0
            while sqlite3_step(rows) == SQLITE_ROW {
                let id = sqlite3_column_int64(rows, 0)
                let host = String(cString: sqlite3_column_text(rows, 1))
                let data = Data(bytes: sqlite3_column_blob(rows, 2)!, count: Int(sqlite3_column_bytes(rows, 2)))
                let converted = try ArcChromiumCookieCipher.reencrypt(data, host: host, sourceKey: sourceKey, targetKey: targetKey)
                var update: OpaquePointer?
                guard sqlite3_prepare_v2(db, "UPDATE cookies SET encrypted_value=? WHERE rowid=?", -1, &update, nil) == SQLITE_OK else { fatalError("Fixture update failed") }
                let bound = converted.withUnsafeBytes { sqlite3_bind_blob(update, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                guard bound == SQLITE_OK, sqlite3_bind_int64(update, 2, id) == SQLITE_OK, sqlite3_step(update) == SQLITE_DONE else { fatalError("Fixture update failed") }
                sqlite3_finalize(update)
                count += 1
            }
            guard count > 0, sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { fatalError("Fixture has no cookies") }
            print("rekeyed cookies: \(count)")
        }
    }
}
