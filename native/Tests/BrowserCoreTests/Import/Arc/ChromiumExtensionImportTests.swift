@testable import BrowserCore
import CryptoKit
import Foundation
import Testing

@Suite("Chromium extension import", .serialized)
struct ChromiumExtensionImportTests {
    static let key = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA9wRdfPHwFkw6X8vkFI1I7hg0e/7sMYs39wBUaL0OI6P17JJLHvuhopdxrvaLI9ZZzDhdG7iSgZ8SJ/AnxIfuEeNh4GB4KFkHDWa9z9gSj/T0jA+WvDpU7nYdCQkcPDXq9x2Px/8INfcybFBWlAMZ+ur/WkKt27plLjZXK5vqimfcG5KeYRRn7tp4+1EmNM2P+GoZdKBxDA+9DAgpoc+NWuLlcAU1Ya08lpPhZyQBqK7SxMLpkdguRU/UIQ2dWjEd4PRGukqdbr+ZyhsMCkzwrYy34JmykmMJu/yrxphjQzsInN5hLo7+V4Yc9rcjSc5kB9I2ZytiZlEArdGoPmwy4QIDAQAB"
    static var id: String { SHA256.hash(data: Data(base64Encoded: key)!).prefix(16).flatMap { [$0 >> 4, $0 & 15] }.map { String(UnicodeScalar(Int($0) + 97)!) }.joined() }
    func seed(_ source: URL, directory: String, disabled: Bool = false) throws {
        let root = source.appendingPathComponent("User Data/" + directory)
        let package = root.appendingPathComponent("Extensions/" + Self.id + "/1.0_0")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Import functional fixture", "version": "1.0", "key": Self.key,
            "permissions": ["storage"], "action": ["default_title": "Imported fixture"],
            "content_scripts": [["matches": ["http://127.0.0.1/*"], "js": ["content.js"]]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("manifest.json"))
        try Data("package-asset-must-remain-unchanged".utf8).write(to: package.appendingPathComponent("Preferences"))
        try Data("chrome.storage.local.set({functionalImport:true}, () => { if (!chrome.runtime.lastError) document.documentElement.dataset.extensionImport = chrome.runtime.id; });".utf8).write(to: package.appendingPathComponent("content.js"))
        let entry: [String: Any] = ["location": 1, "path": Self.id + "/1.0_0", "manifest": manifest, "state": disabled ? 0 : 1, "disable_reasons": disabled ? 1 : 0,
            "active_permissions": ["api": ["storage"], "explicit_host": [], "scriptable_host": ["http://127.0.0.1/*"]],
            "granted_permissions": ["api": ["storage"], "explicit_host": [], "scriptable_host": ["http://127.0.0.1/*"]]]
        try JSONSerialization.data(withJSONObject: ["extensions": ["pinned_extensions": [Self.id]], "account_info": [["secret": "excluded"]]])
            .write(to: root.appendingPathComponent("Preferences"))
        try JSONSerialization.data(withJSONObject: ["extensions": ["settings": [Self.id: entry]], "protection": ["macs": "source-integrity-must-not-migrate"]])
            .write(to: root.appendingPathComponent("Secure Preferences"))
    }
    @Test func packagesAndStateThroughImporter() async throws {
        let fixture = try OrbitImportTestFixture()
        defer { fixture.remove() }
        try seed(fixture.source, directory: "Default")
        try seed(fixture.source, directory: "Profile 1", disabled: true)
        var expectedCount = 2
        if let external = ProcessInfo.processInfo.environment["ORBIT_EXTENSION_IMPORT_PUBLIC_PACKAGE"] {
            let source = URL(fileURLWithPath: external)
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("manifest.json"))) as! [String: Any]
            let key = manifest["key"] as! String
            let id = SHA256.hash(data: Data(base64Encoded: key)!).prefix(16).flatMap { [$0 >> 4, $0 & 15] }.map { String(UnicodeScalar(Int($0) + 97)!) }.joined()
            let root = fixture.source.appendingPathComponent("User Data/Default")
            let path = id + "/" + (manifest["version"] as! String) + "_0"
            let destination = root.appendingPathComponent("Extensions/" + path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            let prefs = root.appendingPathComponent("Secure Preferences")
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: prefs)) as! [String: Any]
            var extensions = json["extensions"] as! [String: Any]
            var settings = extensions["settings"] as! [String: [String: Any]]
            let permissions: [String: Any] = ["api": manifest["permissions"] as? [String] ?? [],
                "explicit_host": manifest["host_permissions"] as? [String] ?? [], "scriptable_host": []]
            settings[id] = ["manifest": manifest, "location": 1, "path": path, "disable_reasons": [], "from_webstore": true,
                "active_permissions": permissions, "granted_permissions": permissions]
            extensions["settings"] = settings; json["extensions"] = extensions
            try JSONSerialization.data(withJSONObject: json).write(to: prefs)
            expectedCount += 1
        }
        let sourceBefore = try Data(contentsOf: fixture.source.appendingPathComponent("User Data/Default/Preferences"))
        let target = try fixture.target()
        let importer = fixture.importer()
        let preparation = try await importer.prepare(for: target)
        #expect(preparation.report.sourceCounts?["extensions"] == expectedCount)
        let projection = try Data(contentsOf: preparation.snapshot.directory.appendingPathComponent("User Data/Default/Preferences"))
        #expect(!String(decoding: projection, as: UTF8.self).contains("account_info"))
        #expect(!String(decoding: projection, as: UTF8.self).contains("secret"))
        let protectedProjection = try Data(contentsOf: preparation.snapshot.directory.appendingPathComponent("User Data/Default/Secure Preferences"))
        #expect(!String(decoding: protectedProjection, as: UTF8.self).contains("source-integrity"))
        let plan = preparation.plan
        let outcome = try await importer.apply(preparation, to: target)
        #expect(outcome.extensionsStaged == expectedCount)
        for profile in plan.profiles where ["Default", "Profile 1"].contains(profile.sourceDirectory ?? "") {
            let folder = target.location.dataDirectory.appendingPathComponent("Chromium/profile-" + profile.id.rawValue.uuidString.lowercased())
            #expect(try Data(contentsOf: folder.appendingPathComponent("Extensions/" + Self.id + "/1.0_0/Preferences")) == Data("package-asset-must-remain-unchanged".utf8))
            let prefs = try Data(contentsOf: folder.appendingPathComponent("OrbitExtensionImport.json"))
            #expect(!String(decoding: prefs, as: UTF8.self).contains("secret"))
            let json = try JSONSerialization.jsonObject(with: prefs) as! [String: Any]
            let settings = (json["extensions"] as! [String: Any])["settings"] as! [String: [String: Any]]
            #expect(settings[Self.id]?["disable_reasons"] as? [Int] == (profile.sourceDirectory == "Default" ? [] : [1]))
        }
        #expect(try Data(contentsOf: fixture.source.appendingPathComponent("User Data/Default/Preferences")) == sourceBefore)
        let again = try await importer.prepare(for: target)
        #expect(try await importer.apply(again, to: target).extensionsStaged == nil)
        await target.close()
        if let destination = ProcessInfo.processInfo.environment["ORBIT_EXTENSION_IMPORT_EVIDENCE_ROOT"] {
            let url = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture.sessionFile.deletingLastPathComponent(), to: url.appendingPathComponent("data"))
            try Data(Self.id.utf8).write(to: url.appendingPathComponent("extension-id"))
        }
    }
    @Test func identityAndMissingPackageAreRejected() async throws {
        let fixture = try OrbitImportTestFixture(); defer { fixture.remove() }
        try seed(fixture.source, directory: "Default")
        let package = fixture.source.appendingPathComponent("User Data/Default/Extensions/" + Self.id + "/1.0_0/manifest.json")
        try Data("{}".utf8).write(to: package)
        let target = try fixture.target()
        let preparation = try await fixture.importer().prepare(for: target)
        #expect(preparation.report.sourceCounts?["extensions"] == 0)
        #expect(preparation.report.sourceCounts?["extensionsSkipped"] == 1)
        preparation.discard(); await target.close()
    }
    @Test func interruptedImportRestoresPackagesWithProfiles() async throws {
        let fixture = try OrbitImportTestFixture(); defer { fixture.remove() }
        try seed(fixture.source, directory: "Default")
        let target = try fixture.target()
        let importer = fixture.importer(checkpoint: { point in
            if point == .afterApply { throw ArcImportError.cancelled }
        })
        let preparation = try await importer.prepare(for: target)
        let ids = preparation.plan.profiles.map(\.id)
        do { _ = try await importer.apply(preparation, to: target); Issue.record("Expected injected failure") }
        catch { }
        await target.close()
        let recovery = try #require(try BrowserImportRecovery.open(at: target.location.dataDirectory))
        #expect(recovery.needsRecovery)
        try recovery.recover(.restore)
        for id in ids {
            #expect(!FileManager.default.fileExists(atPath: target.location.dataDirectory.appendingPathComponent("Chromium/profile-" + id.rawValue.uuidString.lowercased()).path))
        }
    }
    @Test func componentAndMissingPackagesAreExcluded() async throws {
        let fixture = try OrbitImportTestFixture(); defer { fixture.remove() }
        try seed(fixture.source, directory: "Default")
        let prefs = fixture.source.appendingPathComponent("User Data/Default/Secure Preferences")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: prefs)) as! [String: Any]
        var ext = json["extensions"] as! [String: Any]
        var settings = ext["settings"] as! [String: [String: Any]]
        settings[Self.id]?["location"] = 5
        ext["settings"] = settings; json["extensions"] = ext
        try JSONSerialization.data(withJSONObject: json).write(to: prefs)
        let target = try fixture.target()
        let first = try await fixture.importer().prepare(for: target)
        #expect(first.report.sourceCounts?["extensions"] == 0)
        first.discard()
        try seed(fixture.source, directory: "Default")
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("User Data/Default/Extensions"))
        let second = try await fixture.importer().prepare(for: target)
        #expect(second.report.sourceCounts?["extensions"] == 0)
        #expect(second.report.sourceCounts?["extensionsSkipped"] == 1)
        second.discard(); await target.close()
    }

    @Test(arguments: ChromiumImportRegistry.descriptors)
    func chromiumSourcesMapPackagesToSelectedProfile(_ descriptor: BrowserImportDescriptor) async throws {
        let fixture = try OrbitImportTestFixture(); defer { fixture.remove() }
        try seed(fixture.source, directory: "Profile 1", disabled: true)
        let source = fixture.source.appendingPathComponent("User Data")
        var importer = BrowserImportOrchestrator(source: source, probe: NeverRunningProbe(), snapshotParent: fixture.snapshots)
        importer.adapter = ChromiumBrowserImportAdapter(descriptor: descriptor, installationID: UUID(),
            profile: .init(directory: "Profile 1", name: "Synthetic Work"),
            placement: .init(importedSpace: "Imported", bookmarkFolder: "Bookmarks", windowName: "Window"))
        let target = try fixture.target()
        let preparation = try await importer.prepare(for: target)
        #expect(preparation.plan.profiles.count == 1)
        let id = try #require(preparation.plan.profiles.first?.id)
        #expect(try await importer.apply(preparation, to: target).extensionsStaged == 1)
        let stages = try BrowserExtensionImportStage.pending(dataRoot: target.location.dataDirectory)
        #expect(stages.count == 1)
        #expect(stages.first?.profileID == id)
        #expect(stages.first?.json.contains(Self.id) == true)
        await target.close()
    }

    @Test func packageLinksCannotReadOutsideTheSource() async throws {
        let fixture = try OrbitImportTestFixture(); defer { fixture.remove() }
        try seed(fixture.source, directory: "Default")
        let sentinel = fixture.root.appendingPathComponent("sentinel")
        try Data("must-not-be-copied".utf8).write(to: sentinel)
        let linked = fixture.source.appendingPathComponent("User Data/Default/Extensions/" + Self.id + "/1.0_0/linked.js")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: sentinel)
        let target = try fixture.target()
        await #expect(throws: (any Error).self) { try await fixture.importer().prepare(for: target) }
        #expect(!FileManager.default.fileExists(atPath: target.location.sessionFile.path))
        #expect(try Data(contentsOf: sentinel) == Data("must-not-be-copied".utf8))
        await target.close()
    }

    @Test func registrationReceiptPublishesTargetIntegrityAfterRuntimeCloses() async throws {
        let fixture = try OrbitImportTestFixture(); defer { fixture.remove() }
        try seed(fixture.source, directory: "Default")
        let target = try fixture.target()
        let importer = fixture.importer()
        _ = try await importer.apply(try await importer.prepare(for: target), to: target)
        let stage = try #require(try BrowserExtensionImportStage.pending(dataRoot: target.location.dataDirectory).first)
        #expect(!stage.isPersisted())
        var generated = try JSONSerialization.jsonObject(with: Data(stage.json.utf8)) as! [String: Any]
        // A unit-only target integrity placeholder; real Chromium acceptance supplies real hashes.
        generated["protection"] = ["macs": ["extensions": ["settings": [Self.id: "target-integrity-placeholder"]]]]
        let bytes = try JSONSerialization.data(withJSONObject: generated)
        let file = target.location.dataDirectory.appendingPathComponent("Chromium/profile-" + stage.profileID.rawValue.uuidString.lowercased() + "/Secure Preferences")
        try bytes.write(to: file)
        #expect(stage.isPersisted())
        try stage.retainRegistration()
        try Data("{}".utf8).write(to: file)
        try stage.complete()
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try BrowserExtensionImportStage.pending(dataRoot: target.location.dataDirectory).isEmpty)
        #expect(try BrowserImportRecovery.open(at: target.location.dataDirectory) == nil)
        await target.close()
    }

    @Test(arguments: ["malformed", "negative", "future-mask", "blocklisted"])
    func invalidOrBlockedStateCannotBecomeEnabled(_ kind: String) async throws {
        let fixture = try OrbitImportTestFixture(); defer { fixture.remove() }
        try seed(fixture.source, directory: "Default")
        let file = fixture.source.appendingPathComponent("User Data/Default/Secure Preferences")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var ext = document["extensions"] as! [String: Any]
        var entries = ext["settings"] as! [String: [String: Any]]
        if kind == "malformed" { entries[Self.id]?["disable_reasons"] = "disabled" }
        if kind == "negative" { entries[Self.id]?["disable_reasons"] = -1 }
        if kind == "future-mask" { entries[Self.id]?["disable_reasons"] = Int64(1) << 40 }
        if kind == "blocklisted" { entries[Self.id]?["blacklist_state"] = 1 }
        ext["settings"] = entries; document["extensions"] = ext
        try JSONSerialization.data(withJSONObject: document).write(to: file)
        let target = try fixture.target()
        let preparation = try await fixture.importer().prepare(for: target)
        #expect(preparation.report.sourceCounts?["extensions"] == 0)
        #expect(preparation.report.sourceCounts?["extensionsSkipped"] == 1)
        preparation.discard(); await target.close()
    }

}
