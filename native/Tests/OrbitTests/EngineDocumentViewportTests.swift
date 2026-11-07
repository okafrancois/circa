import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Document viewport ownership", .serialized)
@MainActor
struct EngineDocumentViewportTests {
    init() { NSApplication.shared.setActivationPolicy(.prohibited) }

    @Test("Developer tool edits outside the document cannot mark the page as unsaved")
    func documentResponderOwnership() async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.window?.close() }
        owner.session.openTab(url: URL(string: "https://example.test/viewport")!)
        await owner.session.waitForQueuedCommands()
        let surface = try #require(owner.session.selectedSurface)
        let contract: any BrowserEngineSurface = surface
        #expect(contract.documentView === surface.documentView)
        #expect(contract.documentView !== contract.hostView)
        let pageEditor = SiteSyntheticDocumentView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        let toolsEditor = SiteSyntheticDocumentView(frame: NSRect(x: 200, y: 0, width: 120, height: 40))
        surface.documentView.addSubview(pageEditor)
        surface.hostView.addSubview(toolsEditor)
        OrbitUnsavedInputGuard.register(surface)
        OrbitUnsavedInputGuard.clear(surface)
        #expect(owner.window?.makeFirstResponder(toolsEditor) == true)
        OrbitUnsavedInputGuard.paste(into: surface)
        #expect(!OrbitUnsavedInputGuard.preventsInstallation([surface]))
        #expect(owner.window?.makeFirstResponder(pageEditor) == true)
        OrbitUnsavedInputGuard.paste(into: surface)
        #expect(OrbitUnsavedInputGuard.preventsInstallation([surface]))
    }
}
}
