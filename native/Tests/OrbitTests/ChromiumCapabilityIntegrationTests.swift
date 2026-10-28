import BrowserEngine
import Testing
import WebKitEngine

@Suite("R3 and essentials capability integration")
struct ChromiumCapabilityIntegrationTests {
    @Test("Page interaction capabilities never imply Safe Browsing")
    func pageInteractionIsIndependentOfSafeBrowsing() {
        let pageCapabilities: BrowserEngineCapabilities = [.pageContextMenus, .beforeUnloadOnClose]
        #expect(!pageCapabilities.contains(.safeBrowsing))
        #expect(BrowserEngineCapabilities.safeBrowsing.intersection(pageCapabilities).isEmpty)
    }

    @Test("WebKit retains printing and Safe Browsing independently of hosted page menus")
    @MainActor
    func webKitRetainsBothCapabilities() async {
        let engine = WebKitBrowserEngine()
        #expect(engine.capabilities.contains(.printing))
        #expect(engine.capabilities.contains(.safeBrowsing))
        #expect(!engine.capabilities.contains(.pageContextMenus))
        #expect(!engine.capabilities.contains(.beforeUnloadOnClose))
        await engine.shutdown()
    }
}
