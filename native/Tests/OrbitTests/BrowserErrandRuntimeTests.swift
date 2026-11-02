import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

@MainActor struct BrowserErrandRuntimeTests {
    @Test func navigationApprovalIsOneRequestWithBoundedSameOriginRedirects() {
        let source = NSObject(), other = NSObject(), url = URL(string: "https://example.test/search?q=a")!
        let grant = BrowserErrandNavigationGrant(surface: source, destination: url)
        #expect(!grant.permits(.init(url: url, isMainFrame: true, kind: .typed), from: other))
        #expect(!grant.permits(.init(url: url, isMainFrame: true, kind: .redirect), from: source))
        #expect(!grant.permits(.init(url: url, isMainFrame: true, disposition: .newWindow), from: source))
        #expect(!grant.permits(.init(url: url, shouldPerformDownload: true, isMainFrame: true), from: source))
        #expect(grant.permits(.init(url: url, isMainFrame: true, kind: .typed), from: source))
        #expect(!grant.permits(.init(url: url, isMainFrame: true, kind: .typed), from: source))
        for _ in 0..<4 {
            #expect(grant.permits(.init(url: URL(string: "https://example.test/results")!, isMainFrame: true, kind: .redirect), from: source))
        }
        #expect(!grant.permits(.init(url: url, isMainFrame: true, kind: .redirect), from: source))
        grant.revoke()
        #expect(!grant.permits(.init(url: url, isMainFrame: true), from: source))
    }

    @Test func formsBindOriginPathAndTransportWhileAllowingSubmittedQuery() {
        let source = NSObject(), url = URL(string: "https://example.test/find")!
        let grant = BrowserErrandNavigationGrant(surface: source, destination: url, form: true)
        for raw in ["https://other.test/find", "http://example.test/find", "https://example.test:444/find", "https://example.test/delete", "javascript:alert(1)"] {
            #expect(!grant.permits(.init(url: URL(string: raw), isMainFrame: true, kind: .formSubmission), from: source))
        }
        #expect(!grant.permits(.init(url: url, isMainFrame: true, kind: .other), from: source))
        #expect(grant.permits(.init(url: URL(string: "https://example.test/find?to=Lisbon"), isMainFrame: true, kind: .formSubmission), from: source))
        #expect(!grant.permits(.init(url: URL(string: "https://other.test/next"), isMainFrame: true, kind: .redirect), from: source))
        let expired = BrowserErrandNavigationGrant(surface: source, destination: url, lifetime: .zero)
        #expect(!expired.permits(.init(url: url, isMainFrame: true), from: source))
    }

    @Test func blockedPopupCannotReleaseASecondQueuedPopupAfterStop() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); owner.session.close(); owner.window?.close() }
        owner.submitAddress("https://example.test/task")
        await owner.session.waitForPendingCommands()
        let surface = try #require(owner.session.selectedSurface)
        owner.errandGuardedSurfaces.insert(ObjectIdentifier(surface))
        var made = 0
        let request = BrowserNewSurfaceRequest(url: URL(string: "https://example.test/popup")!, isUserGesture: false)
        for _ in 0..<2 {
            #expect(owner.surface(surface, createSurfaceFor: request, make: { made += 1; return surface }) == nil)
        }
        #expect(made == 0)
        #expect(owner.errandGuardedSurfaces.contains(ObjectIdentifier(surface)))
        #expect(owner.navigationActionPolicy(for: .init(url: URL(string: "https://example.test/late"), isMainFrame: true, kind: .other, isUserGesture: false), in: surface) == .cancel)
        _ = await owner.session.closeOwnedSurface(surface).value
        #expect(!owner.errandGuardedSurfaces.contains(ObjectIdentifier(surface)))
    }
}
