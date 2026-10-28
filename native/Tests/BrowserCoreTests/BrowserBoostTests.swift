import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite("Profile-local Boost persistence and compilation")
struct BrowserBoostTests {
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("OrbitBoostTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func boost(host: String = "example.test") throws -> BrowserBoost {
        var content = BrowserBoostContent()
        var colors = BrowserBoostColorScheme()
        colors.source = .colorWheelDriven
        colors.appearance = .dark
        colors.hue = 123.5
        colors.saturation = 0.4
        colors.invertLightness = true
        content.colorScheme = colors
        content.fontFamily = "Synthetic Sans"
        content.textZoom = 1.25
        content.textTransform = .uppercase
        content.zapSelectors = ["aside:has(.promotion)", "[data-label='synthetic, badge']"]
        content.customCSS = "p { color: red; }"
        content.customJavaScript = "document.body.dataset.synthetic = 'yes';"
        return BrowserBoost(title: "Synthetic Boost", hostPattern: try .init(host: host), content: content)
    }

    @Test func roundTripRevisionsAndProfileIsolation() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ProfileID(), second = ProfileID()
        let store = try BrowserBoostStore(profileID: first, persistence: .profileDirectory(root))
        var item = try await store.save(boost())
        #expect(item.revision == 1)
        item.title = "Updated"
        item.javaScriptOptIn = true
        item = try await store.save(item, expectedRevision: 1)
        #expect(item.revision == 2)
        let reopened = try BrowserBoostStore(profileID: first, persistence: .profileDirectory(root))
        #expect(await reopened.snapshot().boosts == [item])
        #expect(await reopened.snapshot().revision == 3)
        #expect(await reopened.matchTable().payloads.first?.isolatedJavaScript == item.content.customJavaScript)
        let other = try BrowserBoostStore(profileID: second, persistence: .profileDirectory(root))
        #expect(await other.snapshot().boosts.isEmpty)
        await #expect(throws: BrowserBoostError.staleRevision) { try await store.save(item, expectedRevision: 1) }
        await #expect(throws: BrowserBoostError.staleRevision) { try await store.remove(item.id, expectedRevision: 1) }
        try await store.remove(item.id, expectedRevision: 2)
        #expect(try await BrowserBoostStore(profileID: first, persistence: .profileDirectory(root)).snapshot().boosts.isEmpty)
        let file = root.appendingPathComponent(first.rawValue.uuidString).appendingPathComponent("boosts.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["boosts.json"])
    }

    @Test func versionZeroMigrationResetsScriptConsentAndPreservesSource() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let store = try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root))
        var original = try boost()
        original.javaScriptOptIn = true
        try await store.save(original)
        let file = root.appendingPathComponent(profile.rawValue.uuidString).appendingPathComponent("boosts.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["version"] = 0
        json["revision"] = nil
        var boosts = try #require(json["boosts"] as? [[String: Any]])
        boosts[0]["revision"] = nil
        boosts[0]["javaScriptOptIn"] = nil
        json["boosts"] = boosts
        let bytes = try JSONSerialization.data(withJSONObject: json)
        try bytes.write(to: file)
        let migrated = try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root))
        let snapshot = await migrated.snapshot()
        #expect(snapshot.version == 1)
        #expect(snapshot.boosts.first?.revision == 1)
        #expect(snapshot.boosts.first?.javaScriptOptIn == false)
        #expect(snapshot.boosts.first?.content == original.content)
        #expect(try Data(contentsOf: file) == bytes) // Reading a migration never rewrites the input.
        #expect(await migrated.matchTable().payloads.first?.isolatedJavaScript == nil)
        try await migrated.save(try #require(snapshot.boosts.first), expectedRevision: 1)
        #expect(try await BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root)).snapshot().version == 1)
    }

    @Test func futureCorruptWrongProfileAndSymlinkFilesAreNotOverwritten() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let store = try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root))
        try await store.save(boost())
        let file = root.appendingPathComponent(profile.rawValue.uuidString).appendingPathComponent("boosts.json")
        let healthy = try Data(contentsOf: file)
        var json = try #require(JSONSerialization.jsonObject(with: healthy) as? [String: Any])
        json["version"] = 999
        let future = try JSONSerialization.data(withJSONObject: json)
        try future.write(to: file)
        #expect(throws: BrowserBoostError.unsupportedVersion) {
            try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root))
        }
        #expect(try Data(contentsOf: file) == future)
        json["version"] = 1
        json["profileID"] = ["rawValue": UUID().uuidString]
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        #expect(throws: BrowserBoostError.wrongProfile) {
            try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root))
        }
        try Data("broken".utf8).write(to: file)
        #expect(throws: (any Error).self) { try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root)) }
        try FileManager.default.removeItem(at: file)
        let target = root.appendingPathComponent("untouched.json")
        try healthy.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        await #expect(throws: (any Error).self) { try await store.save(self.boost(host: "other.test")) }
        #expect(try Data(contentsOf: target) == healthy)
        #expect(await store.snapshot().boosts.count == 1)
    }

    @Test func interruptedReplacementPreservesPublishedDocumentAndTable() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let initial = try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root))
        let original = try await initial.save(boost())
        let store = try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root), beforeReplace: {
            throw POSIXError(.EIO)
        })
        var changed = original
        changed.title = "Interrupted"
        await #expect(throws: (any Error).self) { try await store.save(changed, expectedRevision: original.revision) }
        #expect(await store.snapshot().boosts == [original])
        #expect(await store.matchTable().payloads.first?.revision == original.revision)
        #expect(try await BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root)).snapshot().boosts == [original])
    }

    @Test func killedWriterLeavesPreviousCompleteGeneration() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let store = try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root))
        let original = try await store.save(boost())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        // Re-enter only the child test in the same Swift Testing runner, inheriting its
        // framework paths. No recursive SwiftPM build or shared scratch-path lock.
        var arguments: [String] = []
        if let index = CommandLine.arguments.firstIndex(of: "--test-bundle-path") {
            arguments += ["--test-bundle-path", CommandLine.arguments[index + 1]]
        }
        arguments += ["--filter", "BrowserBoostTests/killedWriterChild", "--testing-library", "swift-testing"]
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ORBIT_BOOST_KILL_ROOT"] = root.path
        environment["ORBIT_BOOST_KILL_PROFILE"] = profile.rawValue.uuidString
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
        let reopened = try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root))
        #expect(await reopened.snapshot().boosts == [original])
        // The uncommitted temporary file is ignored, never mistaken for a new generation.
        #expect(await reopened.matchTable().payloads.first?.revision == original.revision)
    }

    @Test func killedWriterChild() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["ORBIT_BOOST_KILL_ROOT"],
              let id = environment["ORBIT_BOOST_KILL_PROFILE"].flatMap(UUID.init(uuidString:)) else { return }
        let store = try BrowserBoostStore(profileID: ProfileID(id),
                                         persistence: .profileDirectory(URL(fileURLWithPath: path)), beforeReplace: {
            _ = kill(getpid(), SIGKILL)
            while true { _ = pause() }
        })
        try await store.save(boost(host: "uncommitted.test"))
        Issue.record("Writer survived the kill seam")
    }

    @Test func privateStoresAndPreferencesNeverCreateFiles() async throws {
        let profile = ProfileID()
        let store = try BrowserBoostStore(profileID: profile)
        try await store.save(boost())
        #expect(await store.snapshot().boosts.count == 1)
        #expect(try await BrowserBoostStore(profileID: profile).snapshot().boosts.isEmpty)
        let settings = try BrowserSettingsStore()
        #expect(await settings.snapshot().enablesBoostsOnWebsites)
        try await settings.setEnablesBoostsOnWebsites(false)
        #expect(await settings.snapshot().enablesBoostsOnWebsites == false)
        #expect(try await BrowserSettingsStore().snapshot().enablesBoostsOnWebsites)
    }

    @Test func recreatingAnIdentityCannotReuseItsRemovedRevision() async throws {
        let store = try BrowserBoostStore(profileID: ProfileID())
        let original = try await store.save(boost())
        try await store.remove(original.id, expectedRevision: original.revision)
        let recreated = try await store.save(original)
        #expect(recreated.revision > original.revision)
    }

    @Test func globalPreferenceDefaultsMigratesAndPersists() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let settings = try BrowserSettingsStore(destination: file)
        try await settings.setEnablesBoostsOnWebsites(false)
        #expect(try await BrowserSettingsStore(destination: file).snapshot().enablesBoostsOnWebsites == false)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["enablesBoostsOnWebsites"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        #expect(try await BrowserSettingsStore(destination: file).snapshot().enablesBoostsOnWebsites)
    }

    @Test func matcherPolicyTable() throws {
        let profile = ProfileID()
        let exact = try boost()
        var expanded = try boost(host: "example.test")
        expanded.hostPattern = try .init(host: "EXAMPLE.test", includesSubdomains: true, schemes: [.http, .https], port: 8443)
        let table = try BrowserBoostMatchTable(profileID: profile, boosts: [exact, expanded])
        let cases: [(String, [BrowserBoostID])] = [
            ("https://example.test", [exact.id]), ("https://EXAMPLE.TEST:443/path?q=1#part", [exact.id]),
            ("https://example.test/any/path", [exact.id]), ("http://example.test", []),
            ("https://sub.example.test", []), ("https://sub.example.test:8443/path", [expanded.id]),
            ("http://deep.sub.example.test:8443", [expanded.id]), ("https://example.test:8443", [expanded.id]),
            ("https://notexample.test:8443", []), ("https://example.test.attacker.test:8443", []),
            ("https://example.test:444", []), ("https://example.test./", []),
            ("https://user:pass@example.test", []), ("about:blank", []), ("about:srcdoc", []),
            ("blob:https://example.test/id", []), ("data:text/html,synthetic", []),
            ("file:///example.test", []), ("chrome://example.test", []), ("chrome-extension://example.test/page", [])
        ]
        for (source, expected) in cases {
            #expect(table.matching(try #require(URL(string: source)), in: profile).map(\.id) == expected, "URL: \(source)")
        }
        let url = try #require(URL(string: "https://example.test"))
        #expect(table.matching(url, in: ProfileID()).isEmpty)
        #expect(table.matching(url, in: profile, globallyEnabled: false).isEmpty)
        let idn = try boost(host: "xn--bcher-kva.test")
        let idnTable = try BrowserBoostMatchTable(profileID: profile, boosts: [idn])
        for source in ["https://xn--bcher-kva.test", "https://bücher.test"] {
            #expect(idnTable.matching(try #require(URL(string: source)), in: profile).map(\.id) == [idn.id])
        }
        let ip = try boost(host: "127.0.0.1")
        #expect(try BrowserBoostMatchTable(profileID: profile, boosts: [ip])
            .matching(#require(URL(string: "https://127.0.0.1")), in: profile).map(\.id) == [ip.id])
        for host in ["*.example.test", "https://example.test", "example.test/path", "example.test:443", "example.test.", "", "::1", "é.test"] {
            #expect(throws: BrowserBoostError.invalidHostPattern) { try BrowserBoostHostPattern(host: host) }
        }
        #expect(throws: BrowserBoostError.invalidHostPattern) { try BrowserBoostHostPattern(host: "127.0.0.1", includesSubdomains: true) }
        #expect(throws: BrowserBoostError.invalidHostPattern) { try BrowserBoostHostPattern(host: "example.test", schemes: []) }
        #expect(throws: BrowserBoostError.invalidHostPattern) { try BrowserBoostHostPattern(host: "example.test", port: 0) }
    }

    @Test func compilerOutputConsentAndBounds() throws {
        var item = try boost()
        let compiled = try BrowserBoostCompiler.compile(item)
        #expect(compiled.css.contains("aside:has(.promotion) { display: none !important; }"))
        #expect(compiled.css.contains(":not(i):not(i *):not(.material-symbols-outlined)"))
        #expect(compiled.css.contains(":not(.material-icons):not(.material-icons *)"))
        #expect(compiled.css.contains("text-transform: uppercase !important;"))
        #expect(compiled.css.contains(":root { font-size: 125.0% !important; }"))
        #expect(compiled.css.hasSuffix(item.content.customCSS))
        #expect(!compiled.css.contains("filter:"))
        #expect(compiled.isolatedJavaScript == nil)
        item.javaScriptOptIn = true
        #expect(try BrowserBoostCompiler.compile(item).isolatedJavaScript == item.content.customJavaScript)
        item.content.fontFamily = "\"; } body { color:red } /*"
        let escaped = try BrowserBoostCompiler.compile(item)
        #expect(!escaped.css.contains("font-family: \"\";"))
        item.isEnabled = false
        #expect(try BrowserBoostMatchTable(profileID: ProfileID(), boosts: [item]).payloads.isEmpty)
        for selector in ["body { color:red }", "a; p", "@import x", "a/*x*/", "a[", "a\\", "a\nbody"] {
            item.content.zapSelectors = [selector]
            #expect(throws: BrowserBoostError.invalidContent) { try BrowserBoostCompiler.compile(item) }
        }
        item.content.zapSelectors = []
        item.content.textZoom = .infinity
        #expect(throws: BrowserBoostError.invalidContent) { try BrowserBoostCompiler.compile(item) }
        item.content.textZoom = nil
        item.content.customCSS = String(repeating: "x", count: BrowserBoostCompiler.maximumSourceBytes + 1)
        #expect(throws: BrowserBoostError.limitExceeded) { try BrowserBoostCompiler.compile(item) }
        #expect(throws: BrowserBoostError.limitExceeded) {
            try BrowserBoostMatchTable(profileID: ProfileID(), boosts: Array(repeating: item, count: 257))
        }
        #expect(throws: BrowserBoostError.duplicateID) { try BrowserBoostMatchTable(profileID: ProfileID(), boosts: [item, item]) }
    }
}
