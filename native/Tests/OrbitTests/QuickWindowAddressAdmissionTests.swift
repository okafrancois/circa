import AppKit
import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct QuickWindowAddressAdmissionTests {
    @Test("A queued address action cannot navigate during promotion preparation")
    func addressRespectsPromotionPreparation() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let (space, _) = try await environment.initialContext.value
        let original = URL(string: "https://synthetic.invalid/original")!
        let little = try await environment.makeQuickWindow(spaceID: space, url: original)
        defer { environment.retireQuickWindows() }
        let surface = try #require(little.surface)
        #expect(surface.currentURL == original)
        #expect(little.beginPromotionPreparation())
        #expect(!little.acceptsCommands)
        let field = NSTextField(string: "https://synthetic.invalid/queued")
        let priorRequests = surface.requestedURLs
        _ = little.perform(NSSelectorFromString("submitAddress:"), with: field)
        #expect(surface.currentURL == original)
        #expect(surface.requestedURLs == priorRequests)
        little.endPromotionPreparation()
        _ = little.perform(NSSelectorFromString("submitAddress:"), with: field)
        #expect(surface.currentURL == URL(string: field.stringValue))
        #expect(surface.requestedURLs.count == priorRequests.count + 1)
    }
}
}
