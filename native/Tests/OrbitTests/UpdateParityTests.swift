import AppKit
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

    @Test("An unsorted feed selects the newest full build and ignores nested delta sources and channels")
    func appcast() throws {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:version>25</sparkle:version></item>
        <item><sparkle:version>27</sparkle:version><sparkle:deltas><enclosure sparkle:version="999"/></sparkle:deltas></item>
        <item><sparkle:version>22</sparkle:version></item>
        <item><sparkle:version>30</sparkle:version><sparkle:channel>beta</sparkle:channel></item>
        <item><sparkle:version>40</sparkle:version><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion></item>
        </channel></rss>
        """
        #expect(try OrbitUpdateFeed.latestVersion(data: Data(xml.utf8)) == "27")
        #expect(throws: (any Error).self) { try OrbitUpdateFeed.latestVersion(data: Data("broken".utf8)) }
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
