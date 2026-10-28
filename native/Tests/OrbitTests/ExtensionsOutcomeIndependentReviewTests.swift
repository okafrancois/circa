import AppKit
import BrowserCore
import BrowserEngine
import Foundation
import Testing
@testable import Orbit

/// Independent policy boundaries. Plain views only; no window or engine is created.
extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct ExtensionsOutcomeIndependentReviewTests {
    @Test("Extension responses and actions retain held-surface and download boundaries in every frame")
    func heldSurfaceAndSubframeResponses() throws {
        let surface = PeekSyntheticSurface(profileID: ProfileID(), engine: nil)
        let hooks = BrowserSurfaceEventHooks<PeekSyntheticSurface>()
        var routed = 0
        hooks.routeNavigations { _, _ in routed += 1; return .handled(.cancel) }
        let url = try #require(URL(string: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/frame.html"))
        for capability in [false, true] {
            for held in [false, true] {
                for main in [false, true] {
                    let expected = capability && held
                    let action = BrowserNavigationAction(url: url, isMainFrame: main, kind: .redirect)
                    #expect(BrowserNavigationPolicy.action(action, surface: surface, held: held,
                        routesEnabled: true, hooks: hooks, extensionDocuments: capability) == (expected ? .allow : .cancel))
                    let response = BrowserNavigationResponse(response: URLResponse(url: url,
                        mimeType: "text/html", expectedContentLength: 0, textEncodingName: nil),
                        canShowMIMEType: false, isForMainFrame: main)
                    #expect(BrowserNavigationPolicy.response(response, surface: surface, held: held,
                        extensionDocuments: capability) == (expected ? .allow : .cancel))
                    #expect(BrowserNavigationPolicy.action(.init(url: url, shouldPerformDownload: true,
                        isMainFrame: main), surface: surface, held: held, routesEnabled: true,
                        hooks: hooks, extensionDocuments: capability) == .cancel)
                }
            }
        }
        #expect(routed == 0)
    }

    @Test("Extension authority refuses explicit ports, empty credentials, wrong alphabets and foreign schemes")
    func strictAuthority() throws {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        for text in ["chrome-extension://\(id):443/x", "chrome-extension://\(id):0/x",
                     "chrome-extension://@\(id)/x", "chrome-extension://:\(id)@\(id)/x",
                     "chrome-extension://abcdefghijklmnopabcdefghijklmnoq/x",
                     "chrome-extension://\(id)./x", "https://\(id)/x",
                     "chrome-extension://\(id)evil.invalid/x"] {
            #expect(!BrowserNavigationPolicy.isExtensionDocument(try #require(URL(string: text))), "\(text)")
        }
    }
}
}
