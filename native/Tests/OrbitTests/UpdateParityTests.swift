import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Orbit

@Suite("Update cadence and pending replacement")
@MainActor
struct UpdateParityTests {
    @Test("Persistent installation switch uses Sparkle keys and hourly checks survive an older override")
    func preferences() throws {
        final class Target: OrbitAutomaticUpdateTarget {
            var automaticallyChecksForUpdates = false
            var automaticallyDownloadsUpdates = false
            var updateCheckInterval: TimeInterval = 86400
        }
        let domain = "orbit.test.updates.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let updater = OrbitUpdater(defaults: defaults)
        #expect(!updater.requiresFreshCheck)
        updater.markPendingCancellation()
        #expect(OrbitUpdater(defaults: defaults).requiresFreshCheck)
        for value in [false, true, false] {
            updater.setAutomaticallyUpdates(value)
            #expect(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool == value)
            #expect(OrbitUpdater(defaults: defaults).automaticallyUpdates == value)
            let target = Target()
            OrbitUpdater.applyAutomaticallyUpdates(value, to: target)
            #expect(target.updateCheckInterval == 3600)
            #expect(target.automaticallyChecksForUpdates)
            #expect(target.automaticallyDownloadsUpdates == value)
        }
    }

    @Test("Feed checks use an isolated session without cookies, credentials or cache")
    func isolatedFeedSession() {
        let configuration = OrbitUpdateFeed.session.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(OrbitUpdateFeed.session !== URLSession.shared)
    }

    @Test("An unsorted feed selects the newest full build and ignores nested delta sources and channels")
    func appcast() throws {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:version>25</sparkle:version></item>
        <item><sparkle:version>27</sparkle:version><sparkle:deltas><enclosure sparkle:version="999"/></sparkle:deltas></item>
        <item><sparkle:version>22</sparkle:version></item>
        <item><sparkle:version>30</sparkle:version><sparkle:channel>nightly</sparkle:channel></item>
        <item><sparkle:version>40</sparkle:version><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion></item>
        </channel></rss>
        """
        #expect(try OrbitUpdateFeed.latestVersion(data: Data(xml.utf8)) == "27")
        #expect(try OrbitUpdateFeed.latestVersion(data: Data(xml.utf8), allowedChannels: ["nightly"]) == "30")
        let promoted = xml.replacingOccurrences(of: "<sparkle:version>27", with: "<sparkle:version>31")
        #expect(try OrbitUpdateFeed.latestVersion(data: Data(promoted.utf8), allowedChannels: ["nightly"]) == "31")
        #expect(throws: (any Error).self) { try OrbitUpdateFeed.latestVersion(data: Data("broken".utf8)) }
    }

    @Test("The freshness hint follows Sparkle's stable phased rollout but keeps the prepared and critical updates")
    func phasedAppcast() throws {
        // Same element layout as generate_appcast with --phased-rollout-interval 86400.
        let published = "Mon, 16 Nov 2026 12:00:00 +0000"
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:version>27</sparkle:version><pubDate>Mon, 09 Nov 2026 12:00:00 +0000</pubDate></item>
        <item><sparkle:version>30</sparkle:version><pubDate>\(published)</pubDate>\
        <sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval></item>
        </channel></rss>
        """
        let release = try #require(DateFormatter.rfc822Fixture.date(from: published))
        func latest(group: UInt64, after days: Double, pending: String? = nil, feed: String = xml) throws -> String {
            let phasing = OrbitUpdateFeed.Phasing(group: group, now: release.addingTimeInterval(days * 86400),
                                                  pendingVersion: pending, hostVersion: "25")
            return try OrbitUpdateFeed.latestVersion(data: Data(feed.utf8), phasing: phasing)
        }
        #expect(try latest(group: 0, after: 0) == "30")
        #expect(try latest(group: 3, after: 2.9) == "27")
        #expect(try latest(group: 3, after: 3) == "30")
        #expect(try latest(group: 6, after: 5.99) == "27")
        #expect(try latest(group: 13, after: 6) == "30")  // Sparkle uses identifier % 7.
        // A user-initiated check may prepare the phased build early; it stays verifiable.
        #expect(try latest(group: 6, after: 0, pending: "30") == "30")
        // Without a group (Sparkle never ran a scheduled check) nothing is filtered.
        #expect(try OrbitUpdateFeed.latestVersion(data: Data(xml.utf8)) == "30")
        let critical = xml.replacingOccurrences(of: "<sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>",
                                                with: "<sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval><sparkle:criticalUpdate/>")
        #expect(try latest(group: 6, after: 0, feed: critical) == "30")
        let criticalBelowHost = critical.replacingOccurrences(of: "<sparkle:criticalUpdate/>",
                                                              with: "<sparkle:criticalUpdate sparkle:version=\"20\"/>")
        #expect(try latest(group: 6, after: 0, feed: criticalBelowHost) == "27")
        let domain = "orbit.test.phasing.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(OrbitUpdateFeed.Phasing(defaults: defaults, pendingVersion: nil, hostVersion: "25") == nil)
        defaults.set(NSNumber(value: UInt32(4_000_000_005)), forKey: OrbitUpdateFeed.Phasing.identifierKey)
        #expect(OrbitUpdateFeed.Phasing(defaults: defaults, pendingVersion: nil, hostVersion: "25")?.group == 4_000_000_005 % 7)
    }

    @Test("A bundle requiring signed feeds reads only feeds whose embedded signature matches its key")
    func signedAppcast() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        func signed(_ content: String, with signer: Curve25519.Signing.PrivateKey = key) throws -> Data {
            let body = Data(content.utf8)
            let signature = try signer.signature(for: body).base64EncodedString()
            return body + Data("<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(body.count)\n-->\n".utf8)
        }
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>\
        <item><sparkle:version>27</sparkle:version></item></channel></rss>
        """
        let info: [String: Any] = ["SURequireSignedFeed": true, "SUPublicEDKey": publicKey]
        #expect(try OrbitUpdateFeed.latestVersion(data: signed(xml), info: info) == "27")
        #expect(try OrbitUpdateFeed.verifiedContent(signed(xml), publicKey: publicKey) == Data(xml.utf8))
        let tampered = String(decoding: try signed(xml), as: UTF8.self).replacingOccurrences(of: ">27<", with: ">28<")
        let forged = try signed(xml, with: Curve25519.Signing.PrivateKey())
        for data in [Data(xml.utf8), Data(tampered.utf8), forged, try signed(xml) + Data("<item/>".utf8)] {
            #expect(throws: (any Error).self) { try OrbitUpdateFeed.latestVersion(data: data, info: info) }
        }
        // Bundles from before the requirement keep reading the unsigned hint.
        #expect(try OrbitUpdateFeed.latestVersion(data: Data(xml.utf8), info: [:]) == "27")
    }

    @Test("A pending intermediate update is cancelled before downloading the latest and never offered")
    func replacement() async {
        let updater = OrbitUpdater()
        var events: [String] = []
        updater.fetchLatestVersion = { "27" }
        updater.discardPendingUpdate = { events.append("cancel-25") }
        updater.downloadLatestUpdate = { events.append("download-27") }
        updater.installPendingUpdate = { events.append("install") }
        updater.prepared(version: "25")
        #expect(updater.readyVersion == nil)
        #expect(!(await updater.validatePendingUpdate()))
        #expect(events == ["cancel-25", "download-27"])
        #expect(updater.readyVersion == nil && updater.pendingVersion == nil)
        updater.prepared(version: "27")
        #expect(await updater.validatePendingUpdate())
        #expect(updater.readyVersion == "27")
    }

    @Test("A newly prepared build is validated while an older feed request is still pending", arguments: [false, true])
    func supersededValidation(offline: Bool) async throws {
        let updater = OrbitUpdater()
        var firstReply: CheckedContinuation<String, any Error>?
        var requests = 0
        updater.fetchLatestVersion = {
            requests += 1
            if requests == 1 {
                return try await withCheckedThrowingContinuation { firstReply = $0 }
            }
            return "27"
        }
        updater.prepared(version: "25")
        for _ in 0..<100 where firstReply == nil { await Task.yield() }
        let reply = try #require(firstReply)
        updater.prepared(version: "27")
        for _ in 0..<30 { await Task.yield() }
        if offline { reply.resume(throwing: URLError(.notConnectedToInternet)) }
        else { reply.resume(returning: "25") }
        for _ in 0..<30 { await Task.yield() }
        #expect(requests == 2)
        #expect(updater.pendingVersion == "27")
        #expect(updater.readyVersion == "27")
    }

    @Test("Completing an old cancellation cannot erase a newly prepared build")
    func supersededCancellation() async throws {
        let updater = OrbitUpdater()
        var cancellation: CheckedContinuation<Void, Never>?
        updater.fetchLatestVersion = { "27" }
        updater.discardPendingUpdate = { await withCheckedContinuation { cancellation = $0 } }
        updater.prepared(version: "25")
        for _ in 0..<100 where cancellation == nil { await Task.yield() }
        let reply = try #require(cancellation)
        updater.prepared(version: "27")
        for _ in 0..<30 { await Task.yield() }
        reply.resume()
        for _ in 0..<30 { await Task.yield() }
        #expect(updater.pendingVersion == "27")
        #expect(updater.readyVersion == "27")
    }

    @Test("Restart revalidates; a newer publication replaces the card instead of installing its stale build")
    func staleRestart() async {
        let updater = OrbitUpdater()
        var latest = "25"
        var installed = false
        var discarded = false
        updater.fetchLatestVersion = { latest }
        updater.discardPendingUpdate = { discarded = true }
        updater.installPendingUpdate = { installed = true }
        updater.prepared(version: "25")
        #expect(await updater.validatePendingUpdate())
        latest = "27"
        updater.restartToUpdate()
        for _ in 0..<20 { await Task.yield() }
        #expect(discarded && !installed && updater.readyVersion == nil)
    }

    @Test("Offline or removed feeds hide the card and cancel pending installation before quit")
    func failClosed() async {
        for offline in [false, true] {
            let updater = OrbitUpdater()
            var discarded = false
            updater.fetchLatestVersion = { if offline { throw URLError(.notConnectedToInternet) }; return "22" }
            updater.discardPendingUpdate = { discarded = true }
            updater.prepared(version: "25")
            await updater.prepareForQuit()
            #expect(discarded && updater.readyVersion == nil && updater.pendingVersion == nil)
        }
    }

    @Test("Turning automatic updates off cancels an already staged installer on normal quit")
    func disabledQuit() async throws {
        let domain = "orbit.test.disabled-quit.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let updater = OrbitUpdater(defaults: defaults)
        var cancelled = false, installs = 0
        updater.fetchLatestVersion = { "27" }
        updater.discardPendingUpdate = { cancelled = true }
        updater.installPendingUpdate = { installs += 1 }
        updater.prepared(version: "27")
        #expect(await updater.validatePendingUpdate())
        updater.setAutomaticallyUpdates(false)
        await updater.prepareForQuit()
        updater.restartToUpdate()
        for _ in 0..<20 { await Task.yield() }
        #expect(cancelled && installs == 0)
        #expect(updater.pendingVersion == nil && updater.readyVersion == nil)
    }

    @Test("Disabling automatic updates during extraction waits for the cancellable installer before quitting")
    func disabledWhileStaging() async throws {
        let domain = "orbit.test.staging-quit.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let updater = OrbitUpdater(defaults: defaults)
        updater.setAutomaticallyUpdates(false)
        updater.beganStaging()
        var finished = false, cancelled = false
        let quit = Task { await updater.prepareForQuit(); finished = true }
        for _ in 0..<20 { await Task.yield() }
        #expect(!finished)
        updater.fetchLatestVersion = { "27" }
        updater.discardPendingUpdate = { cancelled = true }
        updater.prepared(version: "27")
        updater.finishedStaging()
        await quit.value
        #expect(finished && cancelled && updater.pendingVersion == nil)
    }

    @Test("Quitting with automatic updates off cancels a download without waiting for extraction")
    func disabledDownload() async throws {
        let domain = "orbit.test.download-quit.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let updater = OrbitUpdater(defaults: defaults)
        updater.setAutomaticallyUpdates(false)
        var cancelled = false
        updater.beganStaging { cancelled = true; updater.finishedStaging() }
        await updater.prepareForQuit()
        #expect(cancelled && updater.readyVersion == nil)
    }

    @Test("An explicit restart remains consent when automatic installation and idle admission are off")
    func explicitConsent() async throws {
        let domain = "orbit.test.explicit-update.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let updater = OrbitUpdater(defaults: defaults)
        updater.setAutomaticallyUpdates(false)
        updater.idleSignals = { .init() }
        updater.fetchLatestVersion = { "27" }
        var installs = 0
        updater.installPendingUpdate = { installs += 1 }
        updater.prepared(version: "27")
        #expect(await updater.validatePendingUpdate())
        updater.restartToUpdate()
        for _ in 0..<30 { await Task.yield() }
        #expect(installs == 1 && !updater.automaticRelaunchRequested)
    }

    @Test("Card admission excludes synthetic, private and standalone windows; local smoke may force it")
    func visibility() {
        for ready in [String?.none, "27"] {
            for synthetic in [false, true] {
                for forced in [false, true] {
                    for standalone in [false, true] {
                        for isPrivate in [false, true] {
                            #expect(OrbitUpdater.showsCard(ready: ready, synthetic: synthetic, forced: forced,
                                standalone: standalone, isPrivate: isPrivate)
                                == (ready != nil && (!synthetic || forced) && !standalone && !isPrivate))
                        }
                    }
                }
            }
        }
    }
}

private extension DateFormatter {
    static var rfc822Fixture: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }
}
