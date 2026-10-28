import AppKit
@testable import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Daily flow ownership and focus", .serialized)
@MainActor
struct DailyFlowTests {
    @Test("A Boost editor closes when another tab in the same profile becomes selected")
    func boostSelectionChange() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.window?.close() }
        owner.submitAddress("https://first.test/")
        await owner.session.waitForPendingCommands()
        owner.createBoost()
        await owner.boostTask?.value
        let editor = try #require(owner.boostEditor)
        owner.openTab(url: URL(string: "https://second.test/")!)
        await owner.session.waitForPendingCommands()
        #expect(owner.boostEditor == nil)
        #expect(editor.session.isClosed)
        editor.session.edit { $0.fontFamily = "Ignored" }
        await editor.session.pending?.value
        #expect(await editor.session.store.snapshot().boosts.first?.content.fontFamily == nil)
    }

    @Test("A Library Boost opened in an empty Space retires on another empty Space of the same profile")
    func emptySpaceOverlay() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.window?.close() }
        let profile = try #require(owner.session.activeProfileID)
        owner.createSpace(name: "Synthetic empty source", profileID: profile)
        await owner.session.waitForPendingCommands()
        #expect(owner.session.snapshot?.selectedOccurrenceID == nil)
        let store = try environment.boosts.store(for: profile)
        let draft = try await BrowserBoostEditorSession.create(in: store,
            url: URL(string: "https://overlay.test/")!, title: "Synthetic")
        owner.showLibrary(.boosts)
        await owner.session.waitForPendingCommands()
        owner.openLibraryBoost(draft.boost, profile: profile)
        await owner.boostTask?.value
        let overlay = try #require(owner.presentedPeekSurface)
        owner.createSpace(name: "Synthetic empty destination", profileID: profile)
        await owner.session.waitForPendingCommands()
        #expect(owner.session.snapshot?.selectedOccurrenceID == nil)
        #expect(!owner.isPeekPresented)
        #expect(owner.boostEditor == nil)
        #expect(overlay.isDisposed)
    }

    @Test("A pending Library Boost open cannot land in a newly selected Space of the same profile")
    func pendingBoostSpaceChange() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.window?.close() }
        let profile = try #require(owner.session.activeProfileID)
        let store = try environment.boosts.store(for: profile)
        let draft = try await BrowserBoostEditorSession.create(in: store,
            url: URL(string: "https://pending.test/")!, title: "Synthetic")
        owner.showLibrary(.boosts)
        await owner.session.waitForPendingCommands()
        await owner.library.boostsTask?.value
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let held = Task { await store.holdDailySnapshot(entered.continuation, release: release) }
        for await _ in entered.stream { break }
        defer { release.signal() }
        owner.openLibraryBoost(draft.boost, profile: profile)
        let open = owner.boostTask
        owner.createSpace(name: "Synthetic pending destination", profileID: profile)
        await owner.session.waitForPendingCommands()
        release.signal()
        await held.value
        await open?.value
        #expect(!owner.isPeekPresented)
        #expect(owner.boostEditor == nil)
    }

    @Test("Finishing Zap returns keyboard focus to the page and removes its input interceptor")
    func zapFocus() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.window?.close() }
        owner.submitAddress("https://focus.test/")
        await owner.session.waitForPendingCommands()
        owner.createBoost()
        await owner.boostTask?.value
        let editor = try #require(owner.boostEditor)
        let page = try #require(owner.session.selectedSurface)
        owner.beginBoostZap(editor)
        let picker = try #require(editor.zapView)
        #expect(owner.window?.firstResponder === picker)
        picker.onDone?()
        #expect(picker.superview == nil && editor.zapView == nil)
        #expect((owner.window?.firstResponder as? NSView)?.isDescendant(of: page.hostView) == true)
    }
}
}

private extension BrowserBoostStore {
    func holdDailySnapshot(_ entered: AsyncStream<Void>.Continuation, release: DispatchSemaphore) {
        entered.yield(())
        entered.finish()
        _ = release.wait(timeout: .now() + 5)
    }
}
