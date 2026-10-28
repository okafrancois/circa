import AppKit
import BrowserCore
import BrowserEngine
import Foundation
import Testing
@testable import Orbit

/// EXT-OUTCOME-R1: Chrome extension documents (`chrome-extension://<id>/…`) are rendered and
/// access-checked by the engine's extension system (installed and enabled extension,
/// web-accessible resources for frames a site embeds, profile). On an engine that claims
/// `extensionDocuments`, the shell stops cancelling them in tabs, Peek and Little Orbit — main
/// frames (options, onboarding and sign-in pages, `tabs.update`) and subframes (password-manager
/// and other extension UI injected into sites). It grants nothing else. Synthetic IDs only.
extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct ExtensionDocumentPolicyTests {
    private let documents = [
        "chrome-extension://abcdefghijklmnopabcdefghijklmnop/popup.html",
        "chrome-extension://abcdefghijklmnopabcdefghijklmnop/options/index.html?tab=general#security",
        "chrome-extension://47b0e7e4-94dc-4ca6-958c-9d4bfebf7735/zapper-ui.html",
        "CHROME-EXTENSION://abcdefghijklmnopabcdefghijklmnop/onboarding.html"
    ]
    private let refused = [
        "chrome-extension://abcdefghijklmnopabcdefghijklmnoq/x.html",     // q is not an ID letter
        "chrome-extension://abcdefghijklmnop/x.html",                     // short
        "chrome-extension://ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP/x.html",     // IDs are lowercase a–p
        "chrome-extension://abcdefghijklmnopabcdefghijklmnop:80/x.html",
        "chrome-extension://user@abcdefghijklmnopabcdefghijklmnop/x.html",
        "chrome-extension:abcdefghijklmnopabcdefghijklmnop/x.html",
        "chrome-extension:///x.html",
        "chrome://settings/", "chrome-untrusted://synthetic/", "devtools://devtools/"
    ]

    private func environment(extensionDocuments: Bool) -> BrowserEnvironment<PeekSyntheticEngine> {
        let engine = PeekSyntheticEngine()
        if extensionDocuments { engine.capabilities.insert(.extensionDocuments) }
        return BrowserEnvironment(engine: engine)
    }

    @Test("Extension documents pass in tabs, Peek and Little Orbit, main frames and subframes, only when the engine renders them")
    func extensionDocumentsFollowEngineCapability() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for capable in [true, false] {
            let environment = environment(extensionDocuments: capable)
            let controller = try await environment.makeWindow()
            defer { environment.retireQuickWindows(); controller.window?.close() }
            controller.submitAddress("https://example.test/")
            await controller.session.waitForPendingCommands()
            let tab = try #require(controller.session.selectedSurface)
            let child = try #require(tab.openNewTarget(URL(string: "https://example.test/peek")!, modifiers: [.shift]))
            await controller.session.waitForPendingCommands()
            #expect(controller.isPeekPresented)
            let little = try await environment.makeQuickWindow(url: URL(string: "https://example.test/little")!)
            let littleSurface = try #require(little.surface)
            for surface in [tab, child, littleSurface] {
                for text in documents {
                    let url = try #require(URL(string: text))
                    for main in [true, false] {
                        for kind in [BrowserNavigationKind.linkActivation, .other, .redirect] {
                            let action = BrowserNavigationAction(url: url, isMainFrame: main, kind: kind)
                            #expect(actionPolicy(action, on: surface) == (capable ? .allow : .cancel),
                                    "\(text) main=\(main) \(kind) capable=\(capable)")
                        }
                    }
                    let response = BrowserNavigationResponse(response: URLResponse(url: url, mimeType: "text/html",
                        expectedContentLength: 0, textEncodingName: nil), canShowMIMEType: true, isForMainFrame: true)
                    #expect(responsePolicy(response, on: surface) == (capable ? .allow : .cancel), "\(text)")
                    // Never a download, never routed elsewhere: the shell grants no file or action.
                    #expect(actionPolicy(.init(url: url, shouldPerformDownload: true, isMainFrame: true), on: surface) == .cancel)
                }
                for text in refused {
                    let url = try #require(URL(string: text))
                    for main in [true, false] {
                        #expect(actionPolicy(.init(url: url, isMainFrame: main), on: surface) == .cancel, "\(text)")
                    }
                }
            }
            // Ordinary web navigation is unchanged.
            #expect(actionPolicy(.init(url: URL(string: "https://example.test/next"), isMainFrame: true), on: tab) == .allow)
        }
    }

    @Test("A tab's new target to an extension document opens as a tab only when the engine renders it")
    func extensionDocumentNewTargets() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for capable in [true, false] {
            let environment = environment(extensionDocuments: capable)
            let controller = try await environment.makeWindow()
            defer { controller.window?.close() }
            controller.submitAddress("https://example.test/")
            await controller.session.waitForPendingCommands()
            let tab = try #require(controller.session.selectedSurface)
            let url = try #require(URL(string: documents[1]))
            let child = tab.openNewTarget(url)
            await controller.session.waitForPendingCommands()
            #expect((child != nil) == capable, "capable=\(capable)")
            if let child {
                #expect(controller.session.occurrenceID(for: child) != nil && child.profileID == tab.profileID)
                #expect(child.currentURL == url)
            }
            for text in refused {
                #expect(tab.openNewTarget(try #require(URL(string: text))) == nil, "\(text)")
            }
        }
    }

    @Test("Typing an extension address remains unsupported; only engine-driven documents pass")
    func typedExtensionAddressStaysUnsupported() {
        #expect(throws: (any Error).self) {
            _ = try AddressResolver().resolve("chrome-extension://abcdefghijklmnopabcdefghijklmnop/popup.html")
        }
    }

    private func responsePolicy(_ response: BrowserNavigationResponse, on surface: PeekSyntheticSurface) -> BrowserNavigationResponsePolicy {
        var policy = BrowserNavigationResponsePolicy.cancel
        let decision = BrowserPolicyDecision<BrowserNavigationResponsePolicy>(canSuspend: false, fallback: .cancel) { policy = $0 }
        surface.delegate?.surface(surface, decidePolicyFor: response, decision: decision)
        decision.endSynchronousTurn()
        return policy
    }

    private func actionPolicy(_ action: BrowserNavigationAction, on surface: PeekSyntheticSurface) -> BrowserNavigationActionPolicy {
        var policy = BrowserNavigationActionPolicy.cancel
        let decision = BrowserPolicyDecision<BrowserNavigationActionPolicy>(canSuspend: false, fallback: .cancel) { policy = $0 }
        surface.delegate?.surface(surface, decidePolicyFor: action, decision: decision)
        decision.endSynchronousTurn()
        return policy
    }
}
}
