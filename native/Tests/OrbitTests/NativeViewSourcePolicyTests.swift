import AppKit
import BrowserCore
import BrowserEngine
import Foundation
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeViewSourcePolicyTests {
    private let allowed = [
        "view-source:https://example.test/page?query=1#section",
        "view-source:http://example.test:8080/",
        "VIEW-SOURCE:HTTPS://example.test/",
        "view-source:https://user:password@example.test/path/file:///synthetic/ignored",
        "view-source:https://example.test/?next=javascript:alert(1)"
    ]
    private let denied = [
        "view-source:file:///synthetic/not-granted.txt",
        "view-source:file:///synthetic/granted.html",
        "view-source:data:text/html,synthetic",
        "view-source:javascript:alert(1)",
        "view-source:view-source:https://example.test/",
        "view-source:view-source:file:///synthetic/not-granted.txt",
        "view-source:", "view-source:relative/path", "view-source:https:",
        "view-source:https:relative", "view-source:https:///missing-host",
        "view-source:https://", "view-source:https://[invalid",
        "view-source:FILE:///synthetic/not-granted.txt",
        "view-source:JaVaScRiPt:alert(1)", "view-source:DATA:text/html,synthetic",
        "view-source:VIEW-SOURCE:https://example.test/",
        "view-source:%66ile:///synthetic/not-granted.txt",
        "view-source:%68ttps://example.test/",
        "view-source://example.test/path", "view-source:https:/example.test/",
        "view-source:http://?file:///synthetic/not-granted.txt",
        "view-source:https://#file:///synthetic/not-granted.txt",
        "view-source:blob:https://example.test/id", "view-source:about:blank",
        "view-source: https://example.test/", "view-source:https%3A//example.test/"
    ]

    @Test("Main, presented Peek and Little Orbit apply the same source boundary to actions and responses")
    func shellPolicyMatrix() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
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

        for text in allowed + denied {
            let url = try #require(URL(string: text))
            let expected: BrowserNavigationActionPolicy = allowed.contains(text) ? .allow : .cancel
            let action = BrowserNavigationAction(url: url, isMainFrame: true)
            for surface in [tab, child, littleSurface] {
                #expect(actionPolicy(action, on: surface) == expected, "\(text)")
                let response = BrowserNavigationResponse(response: URLResponse(url: url, mimeType: "text/html",
                    expectedContentLength: 0, textEncodingName: nil), canShowMIMEType: true, isForMainFrame: true)
                #expect(responsePolicy(response, on: surface) == (expected == .allow ? .allow : .cancel), "\(text)")
                let count = surface.requestedURLs.count
                surface.navigate(to: url)
                #expect(surface.requestedURLs.count == count + (expected == .allow ? 1 : 0), "\(text)")
                if expected == .allow { #expect(surface.currentURL == url) }
            }
        }
    }

    @Test("Initial Little Orbit and Peek new-target loads cannot bypass the wrapped URL boundary")
    func initialRoutes() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.retireQuickWindows(); controller.window?.close() }
        controller.submitAddress("https://example.test/")
        await controller.session.waitForPendingCommands()
        let tab = try #require(controller.session.selectedSurface)
        for text in allowed + denied {
            let url = try #require(URL(string: text))
            let little = try await environment.makeQuickWindow(url: url)
            let surface = try #require(little.surface)
            #expect(surface.requestedURLs == (allowed.contains(text) ? [url] : []), "\(text)")
            little.window?.close()
            // Peek's initial command/routing intentionally accepts plain web URLs only.
            #expect(controller.openPeek(url) == nil)
            let target = tab.openNewTarget(url, modifiers: [.shift])
            await controller.session.waitForPendingCommands()
            #expect(!controller.isPeekPresented)
            #expect(target == nil, "New-target creation already refuses source wrappers: \(text)")
        }
        let web = URL(string: "https://example.test/initial-peek")!
        let child = try #require(tab.openNewTarget(web, modifiers: [.shift]))
        await controller.session.waitForPendingCommands()
        #expect(controller.isPeekPresented && child.currentURL == web)
    }

    @Test("Source wrappers cannot borrow local HTML grants; Peek keeps its separate file boundary")
    func localGrantAndDownloads() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.retireQuickWindows(); controller.window?.close() }
        controller.submitAddress("https://example.test/")
        await controller.session.waitForPendingCommands()
        let tab = try #require(controller.session.selectedSurface)
        let child = try #require(controller.openPeek(URL(string: "https://example.test/peek")!))
        let little = try await environment.makeQuickWindow(url: URL(string: "https://example.test/little")!)
        let littleSurface = try #require(little.surface)
        // No file is opened: these surfaces and URLs are entirely synthetic.
        let granted = URL(fileURLWithPath: "/synthetic/granted.html")
        for surface in [tab, child, littleSurface] {
            #expect(actionPolicy(.init(url: granted, isMainFrame: true, kind: .typed), on: surface) == .cancel)
            BrowserNavigationPolicy.authorizeLocalDocument(granted, for: surface)
            #expect(actionPolicy(.init(url: granted, isMainFrame: true, kind: .typed), on: surface)
                == (surface === child ? .cancel : .allow))
            for text in ["file:///synthetic/not-granted.txt", "file:///outside/synthetic.html",
                         "view-source:file:///synthetic/granted.html"] {
                #expect(actionPolicy(.init(url: URL(string: text), isMainFrame: true, kind: .typed), on: surface) == .cancel)
            }
            for text in ["https://example.test/download", "http://example.test/download",
                         "blob:https://example.test/id", "data:text/plain,synthetic"] {
                #expect(actionPolicy(.init(url: URL(string: text), shouldPerformDownload: true, isMainFrame: true),
                                     on: surface) == .download)
            }
            for text in allowed + denied {
                #expect(actionPolicy(.init(url: URL(string: text), shouldPerformDownload: true, isMainFrame: true),
                                     on: surface) == .cancel)
            }
        }
        var forwarded: [URL] = []
        controller.peek.onExternalLink = { _, action in if let url = action.url { forwarded.append(url) } }
        let mail = URL(string: "mailto:synthetic@example.test")!
        #expect(actionPolicy(.init(url: mail, isMainFrame: true, kind: .linkActivation, isUserGesture: true), on: child) == .cancel)
        #expect(forwarded == [mail], "Peek still forwards application links to the window's confirmation gate")
        controller.peek.dismiss(animated: false, remember: false)
        #expect(actionPolicy(.init(url: URL(string: allowed[0]), isMainFrame: true), on: child) == .cancel)
    }

    private func actionPolicy(_ action: BrowserNavigationAction, on surface: PeekSyntheticSurface) -> BrowserNavigationActionPolicy {
        var policy = BrowserNavigationActionPolicy.cancel
        let decision = BrowserPolicyDecision<BrowserNavigationActionPolicy>(canSuspend: false, fallback: .cancel) { policy = $0 }
        surface.delegate?.surface(surface, decidePolicyFor: action, decision: decision)
        decision.endSynchronousTurn()
        return policy
    }

    private func responsePolicy(_ response: BrowserNavigationResponse, on surface: PeekSyntheticSurface) -> BrowserNavigationResponsePolicy {
        var policy = BrowserNavigationResponsePolicy.cancel
        let decision = BrowserPolicyDecision<BrowserNavigationResponsePolicy>(canSuspend: false, fallback: .cancel) { policy = $0 }
        surface.delegate?.surface(surface, decidePolicyFor: response, decision: decision)
        decision.endSynchronousTurn()
        return policy
    }
}
}
