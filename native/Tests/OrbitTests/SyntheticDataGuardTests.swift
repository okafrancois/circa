import Darwin
import Foundation
import Testing
@testable import Orbit

// CHROMIUM-APP-R2 (review H1/H2): a synthetic (mock Keychain) run can neither name a personal
// session file nor reach personal data through a derived path. Every test builds its own fake
// home under a fresh temporary directory; no real personal location is read or written.

@Suite("Synthetic run confinement", .serialized)
struct SyntheticDataGuardTests {
    /// A fake home with a personal Orbit data root that holds a session and a Chromium directory.
    private struct Fixture {
        let base: URL
        let support: URL
        let personalRoot: URL
        let personalSession: URL
        let personalChromium: URL
        let syntheticRoot: URL

        init() throws {
            let manager = FileManager.default
            let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("orbit-guard-" + UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
            // The spelling the configuration keeps (`standardizedFileURL` drops `/private`).
            base = temporary.standardizedFileURL
            support = base.appendingPathComponent("home/Library/Application Support", isDirectory: true)
            personalRoot = support.appendingPathComponent("Orbit", isDirectory: true)
            personalSession = personalRoot.appendingPathComponent("session.json")
            personalChromium = personalRoot.appendingPathComponent("Chromium", isDirectory: true)
            syntheticRoot = base.appendingPathComponent("run/data", isDirectory: true)
            try manager.createDirectory(at: personalChromium.appendingPathComponent("profile-p"), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: personalSession)
            try Data("cookies".utf8).write(to: personalChromium.appendingPathComponent("profile-p/Cookies"))
            try manager.createDirectory(at: syntheticRoot, withIntermediateDirectories: true)
        }

        func configuration(root: URL? = nil, mock: Bool = true) throws -> OrbitProductConfiguration {
            var arguments = ["Orbit", "--orbit-data-root=" + (root ?? syntheticRoot).path]
            if mock { arguments.append("--use-mock-keychain") }
            return try OrbitProductConfiguration(arguments: arguments, applicationSupport: support,
                                                build: mock ? OrbitBuildIdentity(bundleIdentifier: nil, signature: nil)
                                                    : .stableProductForTests)
        }

        func launch(sessionFile: String) throws -> PreviewLaunchConfiguration {
            try PreviewLaunchConfiguration(arguments: ["Orbit", "--session-file", sessionFile],
                                           confinement: try configuration().syntheticGuard)
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    private func refusal(_ body: () throws -> Void) -> SyntheticDataGuard.Violation? {
        do {
            try body()
            return nil
        } catch PreviewEnvironmentError.sessionFileRefused(let violation) {
            return violation
        } catch let violation as SyntheticDataGuard.Violation {
            return violation
        } catch {
            Issue.record("Unexpected error \(error)")
            return nil
        }
    }

    @Test("H1: a synthetic run refuses the personal session file in every spelling")
    func personalSessionFileRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.personalSession.path
        let spellings = [
            session,
            session.replacingOccurrences(of: "/Application Support/Orbit/", with: "/application support/ORBIT/"),
            fixture.base.path + "/home/Library/../Library/Application Support/Orbit/session.json",
        ]
        for spelling in spellings {
            #expect(refusal { _ = try fixture.launch(sessionFile: spelling) } == .personalLocation(URL(fileURLWithPath: spelling).standardizedFileURL.path),
                    "spelling \(spelling)")
        }
        // Another spelling of the same directory on the data volume (a firmlink): only the file
        // identity of an ancestor tells it apart.
        let firmlinked = "/System/Volumes/Data" + SyntheticDataGuard.resolved(fixture.personalSession)!.path
        if FileManager.default.fileExists(atPath: firmlinked) {
            #expect(refusal { _ = try fixture.launch(sessionFile: firmlinked) } == .personalLocation(firmlinked))
        }
    }

    @Test("H1: links inside the synthetic root and files outside it are refused; its own file is accepted")
    func sessionFileLinksRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let fileLink = fixture.syntheticRoot.appendingPathComponent("linked.json")
        try manager.createSymbolicLink(at: fileLink, withDestinationURL: fixture.personalSession)
        #expect(refusal { _ = try fixture.launch(sessionFile: fileLink.path) } == .personalLocation(fileLink.path))

        let directoryLink = fixture.syntheticRoot.appendingPathComponent("personal", isDirectory: true)
        try manager.createSymbolicLink(at: directoryLink, withDestinationURL: fixture.personalRoot)
        let throughDirectory = directoryLink.appendingPathComponent("session.json").path
        #expect(refusal { _ = try fixture.launch(sessionFile: throughDirectory) } == .personalLocation(throughDirectory))

        // A link to a harmless file inside the root is still not a session file.
        let local = fixture.syntheticRoot.appendingPathComponent("local.json")
        try Data("{}".utf8).write(to: local)
        let localLink = fixture.syntheticRoot.appendingPathComponent("local-link.json")
        try manager.createSymbolicLink(at: localLink, withDestinationURL: local)
        #expect(refusal { _ = try fixture.launch(sessionFile: localLink.path) } == .symbolicLink(localLink.path))

        let hardLink = fixture.syntheticRoot.appendingPathComponent("hard.json")
        try manager.linkItem(at: fixture.personalSession, to: hardLink)
        #expect(refusal { _ = try fixture.launch(sessionFile: hardLink.path) } == .hardLink(hardLink.path))

        let outside = fixture.base.appendingPathComponent("elsewhere/session.json").path
        #expect(refusal { _ = try fixture.launch(sessionFile: outside) } == .outsideSyntheticRoot(outside))

        let own = fixture.syntheticRoot.appendingPathComponent("session.json")
        #expect(try fixture.launch(sessionFile: own.path).sessionFile?.path == own.path)
        #expect(try PreviewLaunchConfiguration(arguments: ["Orbit", "--ephemeral"],
                                               confinement: try fixture.configuration().syntheticGuard).sessionFile == nil)
        // The product (real Keychain) is not confined.
        #expect(try fixture.configuration(mock: false).syntheticGuard == nil)
    }

    @Test("H2: a synthetic root reached through a link into ~/Library is refused")
    func syntheticRootAliasRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.base.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.support)
        #expect(throws: OrbitProductConfiguration.Failure.mockKeychainOnPersonalRoot) {
            _ = try fixture.configuration(root: alias.appendingPathComponent("Other", isDirectory: true))
        }
        #expect(throws: OrbitProductConfiguration.Failure.mockKeychainOnPersonalRoot) {
            _ = try fixture.configuration(root: fixture.support.appendingPathComponent("Orbit Test", isDirectory: true))
        }
    }

    @Test("H2: every derived path of a synthetic run is a real entry inside its root")
    func derivedPathsValidated() throws {
        let manager = FileManager.default
        do {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let chromium = fixture.syntheticRoot.appendingPathComponent("Chromium", isDirectory: true)
            try manager.createSymbolicLink(at: chromium, withDestinationURL: fixture.personalChromium)
            #expect(refusal { try fixture.configuration().prepareDirectories() } == .personalLocation(chromium.path))
            #expect(!manager.fileExists(atPath: fixture.personalChromium.appendingPathComponent("default").path))
        }
        do {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let elsewhere = fixture.base.appendingPathComponent("elsewhere", isDirectory: true)
            try manager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let chromium = fixture.syntheticRoot.appendingPathComponent("Chromium", isDirectory: true)
            try manager.createSymbolicLink(at: chromium, withDestinationURL: elsewhere)
            #expect(refusal { try fixture.configuration().prepareDirectories() } == .outsideSyntheticRoot(chromium.path))
        }
        do {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let chromium = fixture.syntheticRoot.appendingPathComponent("Chromium", isDirectory: true)
            try manager.createDirectory(at: chromium, withIntermediateDirectories: true)
            let cache = chromium.appendingPathComponent("default", isDirectory: true)
            try manager.createSymbolicLink(at: cache, withDestinationURL: fixture.personalChromium)
            #expect(refusal { try fixture.configuration().prepareDirectories() } == .personalLocation(cache.path))
        }
        do {
            // A link deep inside a profile directory.
            let fixture = try Fixture()
            defer { fixture.remove() }
            let profile = fixture.syntheticRoot.appendingPathComponent("Chromium/profile-s", isDirectory: true)
            try manager.createDirectory(at: profile, withIntermediateDirectories: true)
            let cookies = profile.appendingPathComponent("Cookies")
            try manager.createSymbolicLink(at: cookies, withDestinationURL: fixture.personalChromium.appendingPathComponent("profile-p/Cookies"))
            #expect(refusal { try fixture.configuration().prepareDirectories() } == .symbolicLink(cookies.path))
        }
        do {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let profile = fixture.syntheticRoot.appendingPathComponent("Chromium/profile-s", isDirectory: true)
            try manager.createDirectory(at: profile, withIntermediateDirectories: true)
            let cookies = profile.appendingPathComponent("Cookies")
            try manager.linkItem(at: fixture.personalChromium.appendingPathComponent("profile-p/Cookies"), to: cookies)
            #expect(refusal { try fixture.configuration().prepareDirectories() } == .hardLink(cookies.path))
        }
        do {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let session = fixture.syntheticRoot.appendingPathComponent("session.json")
            try manager.createSymbolicLink(at: session, withDestinationURL: fixture.personalSession)
            #expect(refusal { try fixture.configuration().prepareDirectories() } == .personalLocation(session.path))
        }
    }

    @Test("A substituted synthetic root refuses before creating entries or changing target permissions")
    func substitutedRootRefusedBeforeWrites() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        // Keep the parsed configuration to cover substitution between parsing and preparation too.
        let configuration = try fixture.configuration()
        let original = fixture.base.appendingPathComponent("original-root")
        let target = fixture.base.appendingPathComponent("owned-target")
        try manager.moveItem(at: fixture.syntheticRoot, to: original)
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        try manager.createSymbolicLink(at: fixture.syntheticRoot, withDestinationURL: target)
        #expect(refusal { try configuration.prepareDirectories() } == .symbolicLink(fixture.syntheticRoot.path))
        #expect(throws: OrbitProductConfiguration.Failure.mockKeychainOnPersonalRoot) {
            _ = try OrbitProductLaunch.prepare(arguments: ["Orbit"], infoDictionary: [
                "CFBundleIdentifier": "io.github.okatech.orbit.test.orbit.test.root-substitution", "OrbitSyntheticBundle": true,
                "OrbitUseMockKeychain": true, "OrbitDataRoot": fixture.syntheticRoot.path
            ], applicationSupport: fixture.support, build: OrbitBuildIdentity(bundleIdentifier: nil, signature: nil))
        }
        #expect(try manager.contentsOfDirectory(atPath: target.path).isEmpty)
        let attributes = try manager.attributesOfItem(atPath: target.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    /// Compare the entry itself, canonicalizing its existing parent without following the refused link.
    private func canonicalLinkPath(_ url: URL) throws -> String {
        let parent = url.deletingLastPathComponent().path
        let resolved = try #require(realpath(parent, nil))
        defer { free(resolved) }
        return String(cString: resolved) + "/" + url.lastPathComponent
    }

    @Test("H2: a clean or crashed synthetic layout is accepted, with Chromium's singleton links only at the engine root")
    func cleanLayoutAccepted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let configuration = try fixture.configuration()
        try configuration.prepareDirectories()
        var info = stat()
        #expect(lstat(configuration.engineRoot.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR)
        #expect(info.st_mode & 0o777 == 0o700)
        // What a killed Chromium leaves behind (process singleton), then a profile.
        try manager.createSymbolicLink(atPath: configuration.engineRoot.appendingPathComponent("SingletonLock").path,
                                       withDestinationPath: "synthetic-host-4242")
        try manager.createSymbolicLink(atPath: configuration.engineRoot.appendingPathComponent("SingletonSocket").path,
                                       withDestinationPath: "/private/tmp/orbit-synthetic-socket")
        try manager.createSymbolicLink(atPath: configuration.engineRoot.appendingPathComponent("RunningChromeVersion").path,
                                       withDestinationPath: "156.0.8078.48:1")
        try manager.createDirectory(at: configuration.engineRoot.appendingPathComponent("profile-s"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: configuration.sessionFile)
        try configuration.prepareDirectories()
        // The same name below the engine root is not a singleton link.
        let nested = configuration.engineRoot.appendingPathComponent("profile-s/SingletonLock")
        try manager.createSymbolicLink(atPath: nested.path, withDestinationPath: "synthetic-host-4242")
        let rejected = refusal { try configuration.prepareDirectories() }
        guard case .symbolicLink(let path)? = rejected else { Issue.record("Expected a symbolic link refusal"); return }
        #expect(try canonicalLinkPath(URL(fileURLWithPath: path)) == canonicalLinkPath(nested))
    }

    @Test("H2: the product refuses a symlinked Chromium directory too")
    func productRefusesLinkedEngineRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let elsewhere = fixture.base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let chromium = fixture.syntheticRoot.appendingPathComponent("Chromium", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: chromium, withDestinationURL: elsewhere)
        let product = try fixture.configuration(mock: false)
        let rejected = refusal { try product.prepareDirectories() }
        guard case .symbolicLink(let path)? = rejected else { Issue.record("Expected a symbolic link refusal"); return }
        #expect(try canonicalLinkPath(URL(fileURLWithPath: path)) == canonicalLinkPath(chromium))
    }
}
