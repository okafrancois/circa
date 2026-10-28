import AppKit
import BrowserEngine
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Peek link origin", .serialized)
@MainActor
struct PeekOriginTests {
    @Test("An asynchronous link lookup retains the activation point and rejects a replaced document")
    func deferredLinkOrigin() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let main = try await environment.makeWindow()
        defer { main.window?.close() }
        main.submitAddress("https://synthetic.invalid/source")
        await main.session.waitForPendingCommands()
        let source = try #require(main.session.selectedSurface)
        source.linkActivationPoint = NSPoint(x: 210, y: 145)
        source.linkGeometryResult = BrowserLinkGeometry(bounds: NSRect(x: 180, y: 130, width: 180, height: 30), cornerRadius: 4)
        source.clickLink(to: URL(string: "https://example.org/preview")!, modifiers: [.shift])
        source.linkActivationPoint = NSPoint(x: 700, y: 400)
        for _ in 0..<10 { await Task.yield() }
        let prepare = try #require(main.peekOverlay.prepareSource)
        let result = await prepare()
        #expect(source.linkGeometryPoints == [NSPoint(x: 210, y: 145)])
        #expect(result?.rect.width == 180 && result?.cornerRadius == 4)
        source.scriptNavigate(to: URL(string: "https://synthetic.invalid/replaced")!)
        #expect(await prepare() == nil)
    }

    @Test("Programmatic Peek uses the pointer box without inspecting an unrelated link")
    func commandFallback() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let main = try await environment.makeWindow()
        defer { main.window?.close() }
        main.openPeek(URL(string: "https://synthetic.invalid/preview")!)
        #expect(main.peekOverlay.prepareSource == nil)
        #expect(main.peekOverlay.sourceRect?.size == NSSize(width: 120, height: 20))
        main.dismissPeek(animated: false)
        main.openPeek(URL(string: "https://synthetic.invalid/keyboard-preview")!, trigger: .shiftClick)
        #expect(main.peekOverlay.prepareSource == nil)
        #expect(main.peekOverlay.sourceRect?.size == NSSize(width: 120, height: 20))
        #expect(main.session.selectedSurface?.linkGeometryPoints.isEmpty == true)
    }
}
}
