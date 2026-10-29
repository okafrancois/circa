import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct MemorySuspensionPolicyTests {
    @Test("Native discard preserves the sleeping row through wake without manufacturing a cover")
    func nativeDiscard() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let window = try await environment.makeWindow()
        defer { window.tabSuspension.close(); window.session.close(); window.window?.close(); environment.autoArchive.scheduler.stop() }
        window.openTab(url: URL(string: "https://memory.test/native")!)
        await window.session.waitForPendingCommands()
        let surface = try #require(window.session.selectedSurface)
        let id = try #require(window.session.snapshot?.selectedOccurrenceID)
        window.openTab(url: URL(string: "https://memory.test/anchor")!)
        await window.session.waitForPendingCommands()
        surface.isSuspended = true
        surface.onChange?()
        #expect(window.tabSuspension.preservesSleepingPresentation(for: id))
        var cache = window.tabSuspension.covers
        #expect(cache.value(for: id) == nil)
        #expect(window.tabSuspension.activeCoverIDs.isEmpty)
        surface.delegate?.surfaceDidStartNavigation(surface)
        surface.delegate?.surfaceDidFinishNavigation(surface)
        #expect(window.tabSuspension.preservesSleepingPresentation(for: id))
        surface.isSuspended = false
        surface.isLoading = true
        surface.delegate?.surfaceDidStartNavigation(surface)
        surface.delegate?.surfaceDidFinishNavigation(surface)
        #expect(window.tabSuspension.preservesSleepingPresentation(for: id))
        surface.isLoading = false
        surface.onChange?()
        #expect(!window.tabSuspension.preservesSleepingPresentation(for: id))
        surface.isSuspended = true
        surface.onChange?()
        #expect(window.tabSuspension.preservesSleepingPresentation(for: id))
        window.session.closeOccurrence(id)
        await window.session.waitForPendingCommands()
        window.tabSuspension.selectionDidChange()
        #expect(!window.tabSuspension.preservesSleepingPresentation(for: id))
    }

    @Test("Background pinned and Favorite tabs retain their away URL, icon and native history",
          arguments: [false, true])
    func pinnedState(favorite: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let window = try await environment.makeWindow()
        defer { window.tabSuspension.close(); window.session.close(); window.window?.close(); environment.autoArchive.scheduler.stop() }
        let home = URL(string: "https://memory.test/home")!
        let away = URL(string: "https://memory.test/away")!
        window.openTab(url: home)
        await window.session.waitForPendingCommands()
        let surface = try #require(window.session.selectedSurface)
        let tab = try #require(window.session.snapshot?.tabs.first { $0.occurrenceID == window.session.snapshot?.selectedOccurrenceID })
        if favorite { window.session.addToFavorites([tab.id]) } else { window.session.pinTabs([tab.id]) }
        await window.session.waitForPendingCommands()
        surface.navigate(to: away)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32))
        rep.setColor(.red, atX: 0, y: 0)
        surface.faviconImage = BrowserFaviconImage(sourceURL: home.appendingPathComponent("favicon.png"),
            png: try #require(rep.representation(using: .png, properties: [:])))
        surface.allowsSuspension = true
        await window.session.waitForPendingCommands()
        window.openTab(url: URL(string: "https://memory.test/selected")!)
        await window.session.waitForPendingCommands()
        window.tabSuspension.close()
        window.tabSuspension = BrowserTabSuspensionController(owner: window, store: environment.store)
        window.tabSuspension.selectionDidChange(now: 100)
        #expect(await window.tabSuspension.sweep(now: 3699) == 0)
        #expect(await window.tabSuspension.sweep(now: 3700) == 1)
        #expect(surface.suspensionCount == 1 && !surface.isDisposed)
        #expect(window.tabSuspension.icon(for: tab.occurrenceID) != nil)
        let item = try #require(await environment.store.sessionDocument().organization.tabs.first { $0.id == tab.id })
        #expect(item.pinnedURL == home && item.url == away)
        let title = item.pageTitle
        surface.delegate?.surfaceDidFinishNavigation(surface)
        #expect(window.tabSuspension.preservesSleepingPresentation(for: tab.occurrenceID))
        surface.isLoading = true
        surface.delegate?.surfaceDidStartNavigation(surface)
        surface.delegate?.surfaceDidFinishNavigation(surface)
        let row = try #require(window.session.organization?.allTabs.first { $0.id == tab.id })
        let activity = window.sidebar.liveActivity(row)
        #expect(activity.isLoading == false)
        #expect(activity.favicon != nil)
        #expect(window.tabSuspension.preservesSleepingPresentation(for: tab.occurrenceID))
        window.session.selectOccurrence(tab.occurrenceID)
        await window.session.waitForPendingCommands()
        #expect(window.session.selectedSurface === surface)
        #expect(surface.currentURL == away && surface.navigationState.canGoBack)
        let restored = try #require(await environment.store.sessionDocument().organization.tabs.first { $0.id == tab.id })
        #expect(restored.pinnedURL == home && restored.url == away && restored.pageTitle == title)
        #expect(window.tabSuspension.icon(for: tab.occurrenceID) != nil)
        surface.isLoading = false
        surface.delegate?.surfaceDidFinishNavigation(surface)
        #expect(!window.tabSuspension.preservesSleepingPresentation(for: tab.occurrenceID))
        surface.isLoading = true
        #expect(window.sidebar.liveActivity(row).isLoading == true)
        surface.isLoading = false
        #expect(surface.goBack() == home)
        #expect(surface.goForward() == away)
        #expect(await window.tabSuspension.sweep(now: 10000) == 0)
    }

    @Test("Pinned admission still fails closed on engine refusal and selection during capture")
    func refusals() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let window = try await environment.makeWindow()
        defer { window.tabSuspension.close(); window.session.close(); window.window?.close(); environment.autoArchive.scheduler.stop() }
        window.openTab(url: URL(string: "https://memory.test/protected")!)
        await window.session.waitForPendingCommands()
        let surface = try #require(window.session.selectedSurface)
        let tab = try #require(window.session.snapshot?.tabs.last)
        window.session.pinTabs([tab.id])
        window.openTab(url: URL(string: "https://memory.test/other")!)
        await window.session.waitForPendingCommands()
        window.tabSuspension.close()
        window.tabSuspension = BrowserTabSuspensionController(owner: window, store: environment.store)
        window.tabSuspension.selectionDidChange(now: 0)
        #expect(await window.tabSuspension.sweep(now: 3601) == 0)
        surface.allowsSuspension = true
        surface.suspensionCapture = { nil }
        #expect(await window.tabSuspension.sweep(now: 3601) == 0)
        surface.suspensionCapture = {
            BrowserSuspensionState(url: surface.currentURL!, documentGeneration: surface.documentGeneration &+ 1, scrollX: 0, scrollY: 0)
        }
        #expect(await window.tabSuspension.sweep(now: 3601) == 0)
        surface.suspensionCapture = {
            BrowserSuspensionState(url: URL(string: "https://memory.test/stale")!, documentGeneration: surface.documentGeneration, scrollX: 0, scrollY: 0)
        }
        #expect(await window.tabSuspension.sweep(now: 3601) == 0)
        surface.suspensionCapture = {
            window.session.selectOccurrence(tab.occurrenceID)
            await window.session.waitForPendingCommands()
            return BrowserSuspensionState(url: surface.currentURL!, documentGeneration: surface.documentGeneration, scrollX: 0, scrollY: 0)
        }
        #expect(await window.tabSuspension.sweep(now: 3601) == 0)
        #expect(surface.suspensionCount == 0 && !surface.isDisposed)
    }
}
}
