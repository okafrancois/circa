import AppKit
import BrowserCore
import BrowserShell
import ChromiumEngine
import Foundation

private final class ArchiveSmokeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    var uptime: TimeInterval { lock.withLock { elapsed } }
    var now: Date { Date(timeIntervalSince1970: 1_800_000_000 + uptime) }
    func advance(_ seconds: TimeInterval) { lock.withLock { elapsed += seconds } }
}

/// Runs only in the marked, mock-keychain smoke bundle. The runtime and surfaces are production
/// implementations; the injected clock advances twelve hours without changing the machine clock.
@MainActor
enum OrbitArchiveAutoScenario {
    static func run(engine: ActiveEngine, fixture: URL, root: URL,
                    record: (String, String, [String: Any]) -> Void) async {
        func check(_ name: String, _ passed: Bool) { record("archive-auto." + name, passed ? "proven" : "failed", [:]) }
        let clock = ArchiveSmokeClock()
        let store = BrowserStore(clock: { clock.now })
        var controller: OrbitWindowController?
        var runtime: BrowserArchiveRuntime<ChromiumSurface>?
        defer { runtime?.scheduler.stop(); controller?.session.close(); controller?.window?.close() }
        do {
            let profile = await store.createProfile(name: "Synthetic Archive")
            let space = try await store.createSpace(name: "Synthetic Archive", profileID: profile)
            let windowID = try await store.createWindow(activeSpaceID: space)
            let owner = OrbitWindowController(id: UUID(), store: store, spaceID: space, engine: engine,
                restoringWindowID: windowID, opensInitialTab: false, onClose: {}, onActivate: {})
            controller = owner
            await owner.session.waitForPendingCommands()
            let archive = BrowserArchiveRuntime<ChromiumSurface>(store: store, launchGrace: 300,
                uptime: { clock.uptime }, wallClock: { clock.now })
            runtime = archive
            archive.register(owner.session)
            func open(_ path: String) async throws -> TabID {
                let url = URL(string: "/" + path, relativeTo: fixture)!.absoluteURL
                owner.session.openTab(url: url)
                await owner.session.waitForPendingCommands()
                guard await OrbitRelaunchScenarios.until({
                    owner.session.selectedSurface?.isReady == true && owner.session.selectedSurface?.navigationState.isLoading == false
                }), let id = owner.session.organization?.selectedTab?.id else { throw BrowserStoreError.tabMissing }
                return id
            }
            let idle = try await open("archive-idle")
            let pinned = try await open("archive-pinned")
            _ = try await store.pinTabs([pinned], from: store.captureContext(in: windowID))
            let favorite = try await open("archive-favorite")
            _ = try await store.addToFavorites([favorite], from: store.captureContext(in: windowID))
            let a = try await open("archive-split-a"), b = try await open("archive-split-b")
            _ = try await store.createSplit([a, b], from: store.captureContext(in: windowID))
            let visible = try await open("archive-visible")
            let ready = await OrbitRelaunchScenarios.until {
                owner.session.ownedSurfaces.allSatisfy { $0.isReady && !$0.navigationState.isLoading }
            }
            check("real-surfaces-ready", ready && owner.session.ownedSurfaces.count == 6)
            // Record the actual engine media contract, including unknown audibility protection.
            var protectsIdle = false
            for surface in owner.session.ownedSurfaces {
                let media = await surface.requestMediaState()
                if surface.currentURL?.path == "/archive-idle" {
                    protectsIdle = BrowserArchiveRuntime<ChromiumSurface>.protects(media)
                    record("archive-auto.engine-media", "proven", [
                        "audibleKnown": media.isAudible != nil, "audioPlayingKnown": media.isAudioPlaying != nil,
                        "protected": protectsIdle])
                }
            }
            check("launch-grace", await archive.scheduler.sweep().isEmpty)
            clock.advance(12 * 3600 - 1)
            check("before-threshold", await archive.scheduler.sweep().isEmpty)
            clock.advance(1)
            let records = await archive.scheduler.sweep()
            if protectsIdle {
                // Older engines cannot establish silence; keep the production safeguard visible
                // in the evidence, then exercise the same scheduler with known silent observations.
                check("unknown-state-protected", records.isEmpty)
                let silent = BrowserArchiveRuntime<ChromiumSurface>(store: store, launchGrace: 0,
                    uptime: { clock.uptime }, wallClock: { clock.now },
                    readMedia: { _ in .init(playback: .none, isAudible: false) })
                silent.register(owner.session)
                clock.advance(12 * 3600)
                let admitted = await silent.scheduler.sweep()
                check("known-silent-archives", Set(admitted.map(\.id)) == [idle, a, b])
            } else { check("threshold-archives", Set(records.map(\.id)) == [idle, a, b]) }
            let document = await store.sessionDocument()
            check("pins-favorites-visible-retained", Set(document.organization.tabs.map(\.id)) == [pinned, favorite, visible])
            check("archive-origin-and-time", document.organization.archive.allSatisfy {
                $0.profileID == profile && $0.spaceID == space && $0.archivedAt == clock.now && $0.reason == .automatic
            })
            try document.validate()
            try document.encoded().write(to: root.appendingPathComponent("archive-session.json"), options: .atomic)
            check("persisted", true)
        } catch { record("archive-auto.operation", "failed", ["kind": String(describing: error)]) }
    }
}
