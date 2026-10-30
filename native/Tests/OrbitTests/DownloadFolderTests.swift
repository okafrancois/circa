import BrowserCore
import BrowserEngine
import Foundation
import Testing
@testable import Orbit

@Suite("Download folder preferences")
@MainActor
struct DownloadFolderTests {
    @Test("Defaults save directly to the user's Downloads folder")
    func defaults() {
        let preferences = BrowserSettingsDocument().downloads
        #expect(!preferences.asksWhereToSave)
        #expect(preferences.folderURL == FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true))
    }

    @Test("Folder and prompt preferences survive reopening and older documents keep defaults")
    func persistence() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("download-settings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let store = try BrowserSettingsStore(destination: url)
        let path = root.appendingPathComponent("chosen").path
        try await store.updateDownloads { $0.folderPath = path }
        try await store.updateDownloads { $0.asksWhereToSave = true }
        let reopened = try BrowserSettingsStore(destination: url)
        #expect(await reopened.snapshot().downloads.folderURL.path == path)
        #expect(await reopened.snapshot().downloads.asksWhereToSave)
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        legacy.removeValue(forKey: "downloads")
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)
        let migrated = try BrowserSettingsStore(destination: url)
        #expect(await migrated.snapshot().downloads == BrowserDownloadPreferences())
    }

    @Test("Automatic saves skip the sheet; explicit prompting passes the selected folder", arguments: [false, true])
    func destinationChoice(ask: Bool) async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = BrowserDownloadsController()
        defer { controller.shutdown() }
        var preferences = BrowserDownloadPreferences()
        preferences.folderPath = root.path
        preferences.asksWhereToSave = ask
        controller.preferencesProvider = { preferences }
        var requests: [BrowserDownloadsController.SaveRequest] = []
        let selected = root.appendingPathComponent("selected.txt")
        controller.saveSheetProvider = { request in requests.append(request); return selected }
        let chosen = await controller.chooseDestination(filename: "file.txt", sourceWindow: nil)
        #expect(chosen == (ask ? selected : root.appendingPathComponent("file.txt")))
        #expect(requests.count == (ask ? 1 : 0))
        if ask {
            #expect(requests.first?.directory.path == root.path)
            #expect(requests.first?.filename == "file.txt")
            #expect(requests.first?.explanation == nil)
        }
    }

    @Test("Unavailable folders fall back to an explained save sheet", arguments: [false, true], [false, true])
    func unavailableFolder(notWritable: Bool, ask: Bool) async throws {
        let root = try folder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let chosenFolder = notWritable ? root : root.appendingPathComponent("missing")
        if notWritable { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path) }
        let controller = BrowserDownloadsController()
        defer { controller.shutdown() }
        var preferences = BrowserDownloadPreferences()
        preferences.folderPath = chosenFolder.path
        preferences.asksWhereToSave = ask
        controller.preferencesProvider = { preferences }
        var explained = false
        controller.saveSheetProvider = { request in
            explained = request.explanation?.isEmpty == false && request.directory.path == chosenFolder.path
            return nil
        }
        #expect(await controller.chooseDestination(filename: "file.txt", sourceWindow: nil) == nil)
        #expect(explained)
    }

    @Test("Unique destinations preserve existing files and sanitize suggested names")
    func uniqueNames() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["file.txt", "file (1).txt", "plain", ".hidden"] {
            try Data([42]).write(to: root.appendingPathComponent(name))
        }
        #expect(BrowserDownloadPaths.uniqueDestination(filename: "../file.txt", in: root)?.lastPathComponent == "file (2).txt")
        #expect(BrowserDownloadPaths.uniqueDestination(filename: "plain", in: root)?.lastPathComponent == "plain (1)")
        #expect(BrowserDownloadPaths.uniqueDestination(filename: ".hidden", in: root)?.lastPathComponent == ".hidden (1)")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.txt").path,
                                                 withDestinationPath: root.appendingPathComponent("missing").path)
        #expect(BrowserDownloadPaths.uniqueDestination(filename: "link.txt", in: root)?.lastPathComponent == "link (1).txt")
        #expect(try Data(contentsOf: root.appendingPathComponent("file.txt")) == Data([42]))
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("download-folder-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
