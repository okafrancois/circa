import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct DailySurfacesTests {
    @Test("Native audio playback fallback reaches the row without inventing acoustic audibility")
    func audioPlaybackFallback() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        window.submitAddress("https://example.test/audio-fallback")
        await window.session.waitForPendingCommands()
        let surface = try #require(window.session.selectedSurface)
        surface.media = .init(playback: .playing, isAudioMuted: false, isAudioPlaying: true)
        window.siteControls.refreshMedia(surface)
        for _ in 0..<100 where window.sidebar.listContent.tabs.first?.activity.isAudible != true {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(surface.media.isAudible == nil)
        #expect(window.sidebar.listContent.tabs.first?.activity.isAudible == true)
        surface.media = .init(playback: .paused, isAudioMuted: true, isAudioPlaying: false)
        window.siteControls.refreshMedia(surface)
        for _ in 0..<100 where window.sidebar.listContent.tabs.first?.activity.isAudioMuted != true {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(window.sidebar.listContent.tabs.first?.activity.isAudible == false)
        #expect(window.sidebar.listContent.tabs.first?.activity.isAudioMuted == true)
    }

    @Test("The Retina drag image draws the live favicon in point coordinates without clipping it")
    func dragImageScale() throws {
        let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let tab = SidebarTabItem(id: TabID(), title: "Synthetic Notes", selected: true,
                                 activity: .init(favicon: icon))
        let entry = SidebarListEntry(node: .tab(tab.id), section: .today, ancestors: [], content: .tab(tab))
        let image = SidebarDragImage.render(entry, size: NSSize(width: 212, height: 36),
            accent: .defaultSpace, appearance: try #require(NSAppearance(named: .aqua)))
        let pixels = try #require(image.representations.first as? NSBitmapImageRep)
        let x = Int((OrbitTokens.Metrics.Sidebar.rowInsetX + 8) * 2)
        let color = try #require(pixels.colorAt(x: x, y: 36)?.usingColorSpace(.sRGB))
        #expect(color.redComponent > 0.9 && color.greenComponent < 0.2 && color.blueComponent < 0.2)
    }

    @Test("Address editing notifications clear the lifted pill when AppKit still retains its editor")
    func addressEditingEnds() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        window.window?.makeFirstResponder(window.addressControl)
        NotificationCenter.default.post(name: NSControl.textDidBeginEditingNotification, object: window.addressControl)
        #expect(window.sidebar.addressContainer.isEditing)
        NotificationCenter.default.post(name: NSControl.textDidEndEditingNotification, object: window.addressControl)
        #expect(!window.sidebar.addressContainer.isEditing)
    }

    @Test("Sidebar media updates reach background rows and their mute action targets the same occurrence")
    func backgroundAudio() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        window.submitAddress("https://example.test/audio")
        await window.session.waitForPendingCommands()
        let surface = try #require(window.session.selectedSurface)
        let id = try #require(window.session.organization?.selectedTab?.id)
        window.openTab(url: URL(string: "https://example.test/second")!)
        await window.session.waitForPendingCommands()
        window.siteControls.refreshMedia(surface)
        for _ in 0..<100 where window.sidebar.listContent.tabs.first(where: { $0.id == id })?.activity.isAudible != true {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(window.sidebar.listContent.tabs.first(where: { $0.id == id })?.activity.isAudible == true)
        window.sidebar.onToggleTabAudio?(id)
        await window.session.waitForPendingCommands()
        for _ in 0..<100 where window.sidebar.listContent.tabs.first(where: { $0.id == id })?.activity.isAudioMuted != true {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(surface.media.isAudioMuted == true)
        #expect(window.session.selectedSurface !== surface)
        #expect(window.sidebar.listContent.tabs.first(where: { $0.id == id })?.activity.isAudioMuted == true)
    }

    @Test("Peek uses the contract's link metadata when an engine has no legacy metadata provider")
    func currentEngineMetadata() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine()
        let environment = BrowserEnvironment(engine: engine)
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        window.submitAddress("https://example.test/source")
        await window.session.waitForPendingCommands()
        let source = try #require(window.session.selectedSurface)
        let child = engine.makeSurface(profileID: source.profileID)
        let request = BrowserNewSurfaceRequest(url: URL(string: "https://example.org/peek")!, modifiers: [.shift],
            kind: .linkActivation, isUserGesture: true, disposition: .newWindow)
        guard case .handled = window.routeNewTargetToPeek(from: source, request: request, make: { child }) else {
            Issue.record("A real engine link must reach Peek without the obsolete provider")
            return
        }
        #expect(window.presentedPeekSurface === child)
        window.dismissPeek(animated: false)
        var script = request
        script.kind = .other
        guard case .declined = window.routeNewTargetToPeek(from: source, request: script, make: { child }) else {
            Issue.record("A script popup is not a link activation")
            return
        }
    }
}
}
