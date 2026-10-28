import AppKit
import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct QuickWindowAddressAdmissionTests {
    @Test("Editing a loaded address offers suggestions and commits once without resizing or replacing its document")
    func editLoadedAddress() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let little = try await environment.makeQuickWindow(url: URL(string: "https://synthetic.invalid/original")!)
        defer { environment.retireQuickWindows() }
        let document = try #require(little.surface)
        let frame = try #require(little.window?.frame)
        let input = try #require(little.prepareAddressEditing())
        #expect(input.input.stringValue == document.currentURL?.absoluteString)
        input.input.stringValue = "https://synthetic.invalid/edited"
        little.queryCompactInput(input.input.stringValue)
        let result = try #require(input.rows.first)
        #expect(result.title.contains("synthetic.invalid/edited"))
        result.accept()
        result.accept()
        #expect(document.requestedURLs.count == 2)
        #expect(document.currentURL == URL(string: "https://synthetic.invalid/edited"))
        #expect(little.surface === document && little.window?.frame == frame)
        #expect(!little.isEditingAddress && !input.window.isVisible)
        _ = little.prepareAddressEditing()
        input.onCancel?()
        #expect(!little.isClosed && !little.isEditingAddress)
        #expect(document.requestedURLs.count == 2)
        _ = little.prepareAddressEditing()
        let query = "https://synthetic.invalid/search-this-url"
        input.input.stringValue = query
        little.queryCompactInput(query)
        #expect(input.rows.prefix(2).map(\.title) == [query, query])
        input.rows[1].accept()
        #expect(document.currentURL == SearchEngine.google.searchURL(for: query))
        #expect(little.window?.frame == frame)
    }

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
