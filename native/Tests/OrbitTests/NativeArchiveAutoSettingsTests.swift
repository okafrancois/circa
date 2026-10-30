import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Automatic archive settings", .serialized)
@MainActor
struct NativeArchiveAutoSettingsTests {
    @Test("Settings displays the effective default and a captured change keeps its profile")
    func effectiveAndCapturedProfile() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let (space, profile) = try await environment.initialContext.value
        let other = await environment.store.createProfile(name: "Synthetic Other")
        _ = try await environment.store.createSpace(name: "Synthetic Other", profileID: other)
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        #expect(model.archiveThreshold == .twelveHours)
        let change = BrowserArchiveSettingsChange(profile: profile, profileName: "Synthetic", threshold: .sevenDays)
        model.selectProfile(other)
        await model.waitForPendingActions()
        try await model.setArchiveThreshold(change.threshold, profile: change.profile)
        await model.reload()
        #expect(model.archiveThreshold == .twelveHours)
        #expect(await environment.store.archivePolicy().threshold(for: profile) == .sevenDays)
        #expect(await environment.store.catalogSnapshot().spaces.contains { $0.id == space && $0.profileID == profile })
        try await model.setArchiveThreshold(.oneDay, profile: other, allProfiles: true)
        await model.reload()
        #expect(model.archiveThreshold == .oneDay)
        #expect(await environment.store.archivePolicy().threshold(for: profile) == .oneDay)
        #expect(change.title == "Circa will now archive your tabs after 7 days")
        environment.autoArchive.scheduler.stop()
    }

    @Test("A deleted captured profile cannot apply a delayed change to every other profile")
    func deletedCapture() async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let (_, profile) = try await environment.initialContext.value
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await #expect(throws: BrowserStoreError.profileMissing) {
            try await model.setArchiveThreshold(.thirtyDays, profile: ProfileID(), allProfiles: true)
        }
        #expect(await environment.store.archivePolicy().threshold(for: profile) == .twelveHours)
        environment.autoArchive.scheduler.stop()
    }

    @Test("A cached favicon remains profile scoped after its tab is archived and persisted")
    func cachedArchiveIcon() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic Icon")
        let space = try await store.createSpace(name: "Synthetic Icon", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        let home = URL(string: "https://archive-icon.test/page")!
        let occurrence = try await store.openTab(url: home, from: store.captureContext(in: window), activate: true)
        let tab = try #require(await store.sessionDocument().tabs.first { $0.occurrenceID == occurrence }?.id)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32))
        rep.setColor(.red, atX: 0, y: 0)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let image = try #require(BrowserFaviconImage(sourceURL: URL(string: "https://archive-icon.test/favicon.png")!, png: png))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("archive-auto-icons-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FavoriteIconStore(directory: directory)
        await cache.put(image, profile: profile, home: home)
        _ = try await store.archiveTabs([tab], from: store.captureContext(in: window))
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(await store.sessionDocument().encoded()))
        let record = try #require(await restored.sessionDocument().organization.archive.first)
        let reopenedCache = FavoriteIconStore(directory: directory)
        #expect(await reopenedCache.cachedImage(profile: record.profileID, home: record.tab.url)?.png == image.png)
        #expect(await reopenedCache.cachedImage(profile: ProfileID(), home: record.tab.url) == nil)
        let memory = SidebarIconMemoryCache()
        await memory.preload(document: await restored.sessionDocument(), store: reopenedCache)
        #expect(memory.image(profile: record.profileID, home: record.tab.url) != nil)
        #expect(memory.image(profile: ProfileID(), home: record.tab.url) == nil)
    }
}
}
