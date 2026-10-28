import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class CreationTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

extension NativeWebKitTests {
    @Test("New Space command page and reverse swipe keep the source selection and discard cancelled drafts")
    @MainActor
    func spaceCreationPagerRoundTrip() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let first = try await store.createSpace(name: "First", profileID: profile)
        _ = try await store.createSpace(name: "Last", profileID: profile)
        let catalog = await store.catalogSnapshot()
        let window = CreationTestWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 640),
                                        styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let sidebar = BrowserSidebarView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(sidebar)
        defer { sidebar.spaceSwipe.detach(); window.close() }
        sidebar.onNewSpace = {}
        sidebar.configureNewSpacePage = { $0.configure(profiles: catalog.profiles, selected: profile) }
        sidebar.render(catalog: catalog, activeSpaceID: first, organization: nil)
        sidebar.layoutSubtreeIfNeeded()
        let swipe = sidebar.spaceSwipe
        swipe.automaticallyAdvances = false; swipe.clock = { 10 }
        swipe.presentCreationPage()
        #expect(swipe.isCreationPageVisible)
        let form = try #require(sidebar.newSpaceSwipePage)
        #expect(form.frame.minX == 0)
        form.name.stringValue = "Discard me"
        swipe.cancel() // Typing/clicking in the live form must not remove it.
        #expect(sidebar.newSpaceSwipePage === form)
        sidebar.render(catalog: catalog, activeSpaceID: first, organization: nil)
        #expect(sidebar.newSpaceSwipePage === form)
        func event(_ phase: Int64, x: Int32 = 0, time: Double) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: x, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.timestamp = UInt64(time * 1_000_000_000)
            return try #require(NSEvent(cgEvent: cg))
        }
        _ = swipe.handleScroll(try event(1, time: 1), inside: true)
        _ = swipe.handleScroll(try event(2, x: 400, time: 1.02), inside: true)
        _ = swipe.handleScroll(try event(4, time: 1.03), inside: true)
        _ = swipe.advance(to: 12)
        #expect(!swipe.isCreationPageVisible && sidebar.newSpaceSwipePage == nil)
        #expect(sidebar.swipeContext?.1 == first)
        #expect(await store.catalogSnapshot() == catalog)
        swipe.presentCreationPage()
        #expect(sidebar.newSpaceSwipePage?.name.stringValue == "")
        swipe.dismissCreationPage()
        #expect(!swipe.isCreationPageVisible)
    }

    @Test("Creation validates names and submits typed icon, theme and existing or new profile once")
    @MainActor
    func spaceCreationDraft() async throws {
        let store = BrowserStore()
        let id = await store.createProfile(name: "Personal")
        let catalog = await store.catalogSnapshot()
        let page = SidebarNewSpacePageView(frame: NSRect(x: 0, y: 0, width: 228, height: 540))
        page.configure(profiles: catalog.profiles, selected: id)
        var submissions = 0
        page.onCreate = { name, profile, newName, icon, theme in
            submissions += 1
            #expect(name == "Research")
            #expect(profile == id && newName == nil)
            #expect(icon == .systemSymbol("flask"))
            #expect(theme == BrowserSpaceThemePresets.default)
        }
        page.name.stringValue = "   "; page.create()
        #expect(submissions == 0)
        page.name.stringValue = "Research"; page.setIcon(.systemSymbol("flask")); page.create(); page.create()
        #expect(submissions == 1)
        let fresh = SidebarNewSpacePageView()
        fresh.configure(profiles: catalog.profiles, selected: id)
        fresh.profiles.selectItem(at: catalog.profiles.count)
        fresh.profileChanged()
        fresh.name.stringValue = "Work"
        fresh.refreshValidation()
        #expect(!fresh.createButton.isEnabled)
    }

    @Test("Creation publishes one empty Space with its selected profile, theme and icon; fresh sessions use Personal")
    @MainActor
    func spaceCreationPublication() async throws {
        let store = BrowserStore()
        let engine = SiteSyntheticEngine()
        let session = BrowserWindowSession<SiteSyntheticSurface>(store: store, makeSurface: { profile, _ in engine.makeSurface(profileID: profile) })
        defer { session.close() }
        await session.waitForPendingCommands()
        #expect(session.catalog?.spaces.first?.name == "Personal")
        #expect(session.catalog?.profiles.first?.name == "Personal")
        let settings = try BrowserSettingsStore()
        var rejected = false
        session.createSpace(name: "Invalid", profileID: nil, newProfileName: "Must not exist",
                            theme: BrowserSpaceThemePresets.default, icon: .grapheme("invalid"), settings: settings) { rejected = !$0 }
        await session.waitForPendingCommands()
        #expect(rejected && session.catalog?.spaces.count == 1 && session.catalog?.profiles.count == 1)
        var beforePublication = false, completed = false
        session.createSpace(name: "Research", profileID: nil, newProfileName: "Isolated",
                                  theme: BrowserSpaceThemePresets.default, icon: .grapheme("🧪"), settings: settings,
                                  beforePublication: { beforePublication = true }) { completed = $0 }
        await session.waitForPendingCommands()
        let document = await store.sessionDocument()
        let created = try #require(document.spaces.first { $0.name == "Research" })
        #expect(completed && beforePublication)
        #expect(document.spaces.count == 2 && document.profiles.count == 2)
        #expect(created.theme == BrowserSpaceThemePresets.default)
        #expect(document.profiles.first { $0.id == created.profileID }?.name == "Isolated")
        #expect(session.snapshot?.activeSpaceID == created.id)
        #expect(session.snapshot?.tabs.isEmpty == true)
        #expect(await settings.snapshot().space(created.id).iconSelection == .grapheme("🧪"))
    }
}

extension NativeWebKitTests {
    @Test("Last Space pull shows only the edge ring until release; cancellation restores the source")
    @MainActor
    func spaceCreationEdgeBeforeForm() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let last = try await store.createSpace(name: "Last", profileID: profile)
        let catalog = await store.catalogSnapshot()
        let window = CreationTestWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 950),
                                        styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let sidebar = BrowserSidebarView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(sidebar)
        defer { sidebar.spaceSwipe.detach(); window.close() }
        sidebar.onNewSpace = {}
        sidebar.configureNewSpacePage = { $0.configure(profiles: catalog.profiles, selected: profile) }
        sidebar.render(catalog: catalog, activeSpaceID: last, organization: nil)
        sidebar.layoutSubtreeIfNeeded()
        let swipe = sidebar.spaceSwipe
        swipe.automaticallyAdvances = false; swipe.clock = { 10 }
        func send(_ phase: Int64, _ x: Int32, _ time: Double) throws {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: x, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.timestamp = UInt64(time * 1_000_000_000)
            _ = swipe.handleScroll(try #require(NSEvent(cgEvent: cg)), inside: true)
        }
        try send(1, 0, 1)
        try send(2, -180, 1.02)
        #expect(sidebar.creationEdge != nil)
        #expect(sidebar.newSpaceSwipePage == nil)
        #expect(abs(sidebar.page.frame.minX) < 24)
        try send(8, 0, 1.03)
        _ = swipe.advance(to: 12)
        #expect(sidebar.creationEdge == nil && sidebar.newSpaceSwipePage == nil)
        #expect(sidebar.page.frame.minX == 0)
        #expect(sidebar.swipeContext?.1 == last)
        #expect(await store.catalogSnapshot() == catalog)
    }
}
