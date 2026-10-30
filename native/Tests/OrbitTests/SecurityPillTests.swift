import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

func pageSecurity(level: Int = 0, certificateError: Bool = false, displayed: Bool = false,
                  ran: Bool = false, interstitial: Bool = false, displayedCertificate: Bool = false,
                  ranCertificate: Bool = false) throws -> BrowserPageSecurityState {
    let values: [String: Any] = ["level": level, "certificateStatus": certificateError ? 4 : 0,
        "certificateError": certificateError, "displayedMixedContent": displayed, "ranMixedContent": ran,
        "displayedCertificateErrorContent": displayedCertificate, "ranCertificateErrorContent": ranCertificate,
        "interstitial": interstitial]
    return try JSONDecoder().decode(BrowserPageSecurityState.self, from: JSONSerialization.data(withJSONObject: values))
}

@Suite("Committed address and visible security", .serialized)
@MainActor
struct SecurityPillTests {
    @Test("Pending and script-provided addresses cannot replace the native committed identity")
    func committedIdentity() {
        let engine = SiteSyntheticEngine()
        let surface = engine.makeSurface(profileID: ProfileID())
        let native = PillPageServices()
        surface.nativePageServices = native
        surface.navigate(to: URL(string: "https://pending.test/")!)
        #expect(BrowserAddressPresentation(surface: surface).value.isEmpty)
        native.url = URL(string: "http://committed.test/old")
        surface.navigate(to: URL(string: "https://slow.test/")!)
        #expect(BrowserAddressPresentation(surface: surface).value == native.url?.absoluteString)
        surface.navigate(to: URL(string: "https://spoof.test/pushState")!)
        #expect(BrowserAddressPresentation(surface: surface).label == "committed.test")
        native.url = URL(string: "https://slow.test/")
        #expect(BrowserAddressPresentation(surface: surface).label == "slow.test")
    }

    @Test("The native security formatter owns IDN presentation and receives only the committed URL")
    func homograph() {
        let engine = SiteSyntheticEngine()
        let surface = engine.makeSurface(profileID: ProfileID())
        let native = PillPageServices()
        surface.nativePageServices = native
        native.url = URL(string: "https://xn--pple-43d.com/private?q=synthetic")
        native.formatted = "xn--pple-43d.com"
        let result = BrowserAddressPresentation(surface: surface)
        #expect(result.label == "xn--pple-43d.com")
        #expect(native.formatURL == native.url && native.scheme == .omitHTTPAndHTTPS)
        native.formatted = ""
        #expect(BrowserAddressPresentation(surface: surface).label == uiText("Page"))
    }

    @Test("Data blob and opaque payloads are redacted in resting editing and accessibility values")
    func opaque() {
        for text in ["data:text/html,synthetic-secret", "blob:https://example.test/synthetic-secret",
                     "javascript:synthetic-secret", "custom:synthetic-secret", "about:blank#synthetic-secret",
                     "file:///synthetic-secret", "orbit:settings?synthetic-secret"] {
            var formatterCalled = false
            let address = BrowserAddressPresentation(url: URL(string: text), security: try! pageSecurity(level: 3), format: { _ in formatterCalled = true; return "synthetic-secret" })
            let field = OrbitLocationField()
            field.refreshAddress(text, in: nil, presentation: address)
            #expect(field.stringValue == uiText("Page") && field.displayLabel.stringValue == uiText("Page"))
            #expect(field.securityIcon.isHidden && !formatterCalled)
            #expect(address.connection == .unavailable)
        }
    }

    @Test("Certificate errors interstitials and both mixed-content kinds never show a secure lock")
    func securityStates() throws {
        let url = URL(string: "https://example.test/")!
        let secure = try pageSecurity(level: 3)
        let states = [try pageSecurity(), try pageSecurity(level: 5, certificateError: true, interstitial: true),
                      try pageSecurity(level: 3, displayed: true), try pageSecurity(level: 3, ran: true),
                      try pageSecurity(level: 3, interstitial: true), try pageSecurity(level: 3, displayedCertificate: true),
                      try pageSecurity(level: 3, ranCertificate: true)]
        for state in [secure] + states {
            let model = BrowserSiteControlsModel(url: url, zoom: 1, permissions: [:], capabilities: [], canClearData: false, security: state)
            let address = BrowserAddressPresentation(url: url, security: state, format: { $0.host })
            let field = OrbitLocationField()
            field.refreshAddress(address.value, in: nil, presentation: address)
            #expect(model.connection == address.connection)
            #expect(field.securitySymbol == (state == secure ? "lock.fill" : "lock.slash.fill"))
            let button = OrbitSiteControlCenterView.connectionButton(isSecure: model.connection == .https, onPress: {})
            #expect(button.toolTip == (state == secure ? uiText("Secure connection") : uiText("Connection is not secure")))
        }
        #expect(BrowserSiteControlsModel.Connection.resolve(url: url, security: nil) == .unavailable)
    }

    @Test("Security changes update without navigation and retired subscriptions cannot repaint")
    func securityStream() async throws {
        let first = PillPageServices(), second = PillPageServices()
        let observation = BrowserSecurityObservation()
        var updates = 0
        observation.observe(first) { updates += 1 }
        first.emit(try pageSecurity(level: 3))
        for _ in 0..<10 { await Task.yield() }
        #expect(updates == 1)
        observation.observe(second) { updates += 10 }
        first.emit(try pageSecurity(level: 5, ran: true))
        second.emit(try pageSecurity(level: 5, certificateError: true, interstitial: true))
        for _ in 0..<10 { await Task.yield() }
        #expect(updates == 11)
        observation.observe(nil, changed: {})
        second.emit(try pageSecurity(level: 3))
        for _ in 0..<10 { await Task.yield() }
        #expect(updates == 11)
    }
}

extension NativeWebKitTests {
@Suite("Committed address window projection", .serialized)
@MainActor
struct SecurityPillWindowTests {
    @Test("Slow navigation drafts and security-only events use the committed page in the actual field")
    func projection() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.window?.close() }
        owner.submitAddress("https://committed.test/old")
        await owner.session.waitForPendingCommands()
        let surface = try #require(owner.session.selectedSurface)
        let native = PillPageServices()
        native.url = URL(string: "https://committed.test/old")
        native.state = try pageSecurity(level: 3)
        surface.nativePageServices = native
        owner.refreshNavigation(for: surface)
        #expect(owner.addressField.securitySymbol == "lock.fill")
        surface.navigate(to: URL(string: "https://pending.test/new")!)
        #expect(owner.addressField.stringValue == "https://committed.test/old")
        owner.addressField.stringValue = "https://typed.test/"
        owner.addressEditingDidEnd(Notification(name: NSTextField.textDidEndEditingNotification))
        #expect(owner.addressField.stringValue == "https://committed.test/old")
        native.emit(try pageSecurity(level: 5, ran: true))
        for _ in 0..<20 { await Task.yield() }
        #expect(owner.addressField.securitySymbol == "lock.slash.fill")
        #expect(owner.addressField.displayLabel.stringValue == "committed.test")
    }
}
}

@MainActor
private final class PillPageServices: BrowserNativePageServices {
    var url: URL?
    var state = try! pageSecurity()
    var formatted: String?
    var formatURL: URL?
    var scheme: BrowserSecuritySchemeDisplay?
    var continuations: [AsyncStream<BrowserPageSecurityState>.Continuation] = []
    func securityState() -> BrowserPageSecurityState? { state }
    func securityChanges() -> AsyncStream<BrowserPageSecurityState> {
        AsyncStream { continuations.append($0); $0.yield(state) }
    }
    func emit(_ value: BrowserPageSecurityState) { state = value; continuations.forEach { $0.yield(value) } }
    func committedURL() -> URL? { url }
    func securityDisplay(for url: URL, scheme: BrowserSecuritySchemeDisplay) -> String? {
        formatURL = url; self.scheme = scheme; return formatted ?? url.host
    }
    func fullscreenChanges() -> AsyncStream<BrowserPageFullscreenChange> { AsyncStream { $0.finish() } }
    func navigationHistory() -> BrowserNavigationHistory? { nil }
    func goToEntry(index: Int) -> Bool { false }
    func mediaState() -> BrowserMediaSessionState? { nil }
    func mediaChanges() -> AsyncStream<BrowserMediaSessionState> { AsyncStream { $0.finish() } }
    func mediaAction(_ action: BrowserMediaAction, seconds: Double) -> Bool { false }
}
