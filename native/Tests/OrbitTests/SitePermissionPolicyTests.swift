import BrowserCore
import BrowserEngine
import Foundation
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Site permission request policy")
@MainActor
struct SitePermissionPolicyTests {
    private let origin = BrowserSiteOrigin(requestOrigin: "https://example.test")!
    private let profile = ProfileID()
    private var request: BrowserPermissionRequest {
        BrowserPermissionRequest(kind: .camera, origin: origin.value, isMainFrame: true)
    }

    @Test("Allow once is a single response and never becomes a persisted grant")
    func allowOnce() async throws {
        let policy = BrowserSitePermissionPolicy(store: try BrowserSitePermissionStore())
        var prompts = 0
        for _ in 0..<2 {
            let result = await policy.resolve(request, profileID: profile, isCurrent: { true }) { _, _ in
                prompts += 1
                return .allowOnce
            }
            #expect(result == .grantOnce)
        }
        #expect(prompts == 2)
        #expect(await policy.store.setting(for: .camera, origin: origin, profileID: profile) == .ask)
    }

    @Test("Captured prompt kinds reach the existing UI, including same-origin embedded media",
          arguments: [BrowserPermissionKind.camera, .microphone, .cameraAndMicrophone, .geolocation,
                      .notifications, .other("clipboardRead")], [true, false])
    func auditedKinds(kind: BrowserPermissionKind, mainFrame: Bool) async throws {
        let policy = BrowserSitePermissionPolicy(store: .ephemeral())
        var prompts = 0
        let request = BrowserPermissionRequest(kind: kind, origin: origin.value, isMainFrame: mainFrame)
        #expect(await policy.resolve(request, profileID: profile, isCurrent: { true }) { _, _ in
            prompts += 1
            return .allowOnce
        } == .grantOnce)
        #expect(prompts == 1)
        #expect(await policy.store.configuredOrigins(profileID: profile).isEmpty)
    }

    @Test("Uncaptured engine prompt kinds remain refused", arguments: (0..<30).filter { ![2, 4, 8, 12, 15].contains($0) })
    func uncapturedKinds(bit: Int) async throws {
        let policy = BrowserSitePermissionPolicy(store: .ephemeral())
        #expect(await policy.resolve(.init(kind: .other("cef-permission-\(UInt32(1) << bit)"), origin: origin.value, isMainFrame: true),
                                    profileID: profile, isCurrent: { true }) { _, _ in
            Issue.record("An unrecognized capability reached the prompt")
            return .alwaysAllow
        } == .deny)
    }

    @Test("One-time decisions do not create or alter the permission file or profile settings")
    func onceLeavesDiskUntouched() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/Orbit-Permissions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("permissions.json")
        let policy = BrowserSitePermissionPolicy(store: try BrowserSitePermissionStore(destination: file))
        var persisted = 0
        policy.onPersistedDecision = { _, _, _, _ in persisted += 1 }
        #expect(await policy.resolve(request, profileID: profile, isCurrent: { true }) { _, _ in .allowOnce } == .grantOnce)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try await policy.store.set(.block, for: [.notifications], origin: origin, profileID: profile)
        let before = try Data(contentsOf: file)
        #expect(await policy.resolve(request, profileID: profile, isCurrent: { true }) { _, _ in .allowOnce } == .grantOnce)
        #expect(try Data(contentsOf: file) == before)
        #expect(persisted == 0)
        let reopened = try BrowserSitePermissionStore(destination: file)
        #expect(await reopened.setting(for: .camera, origin: origin, profileID: profile) == .ask)
        #expect(await reopened.setting(for: .camera, origin: origin, profileID: ProfileID()) == .ask)
    }

    @Test("Always allow and block are applied through later requests without prompting")
    func rememberedChoice() async throws {
        let policy = BrowserSitePermissionPolicy(store: try BrowserSitePermissionStore())
        #expect(await policy.resolve(request, profileID: profile, isCurrent: { true }) { _, _ in .alwaysAllow } == .grant)
        var prompted = false
        #expect(await policy.resolve(request, profileID: profile, isCurrent: { true }) { _, _ in prompted = true; return .dismiss } == .grant)
        #expect(!prompted)
        try await policy.store.set(.block, for: [.camera], origin: origin, profileID: profile)
        #expect(await policy.resolve(request, profileID: profile, isCurrent: { true }) { _, _ in prompted = true; return .alwaysAllow } == .deny)
        #expect(!prompted)
        #expect(await policy.resolve(request, profileID: ProfileID(), isCurrent: { true }) { _, _ in .dismiss } == .dismiss)
    }

    @Test("A blocked microphone refuses a combined request despite an allowed camera")
    func combinedDecision() async throws {
        let policy = BrowserSitePermissionPolicy(store: try BrowserSitePermissionStore())
        try await policy.store.set(.allow, for: [.camera], origin: origin, profileID: profile)
        try await policy.store.set(.block, for: [.microphone], origin: origin, profileID: profile)
        let request = BrowserPermissionRequest(kind: .cameraAndMicrophone, origin: origin.value, isMainFrame: true)
        var prompted = false
        #expect(await policy.resolve(request, profileID: profile, isCurrent: { true }) { _, _ in prompted = true; return .alwaysAllow } == .deny)
        #expect(!prompted)
    }

    @Test("Navigation during a prompt cannot grant or persist a decision")
    func stalePrompt() async throws {
        let policy = BrowserSitePermissionPolicy(store: try BrowserSitePermissionStore())
        var current = true
        let result = await policy.resolve(request, profileID: profile, isCurrent: { current }) { _, _ in
            current = false
            return .alwaysAllow
        }
        #expect(result == .deny)
        #expect(await policy.store.setting(for: .camera, origin: origin, profileID: profile) == .ask)
    }

    @Test("Unknown kinds insecure sites and malformed origins fail closed")
    func unsupportedRequests() async throws {
        let policy = BrowserSitePermissionPolicy(store: try BrowserSitePermissionStore())
        var prompted = false
        for request in [
            BrowserPermissionRequest(kind: .other("unknown"), origin: origin.value, isMainFrame: true),
            BrowserPermissionRequest(kind: .camera, origin: "http://example.test", isMainFrame: true),
            BrowserPermissionRequest(kind: .camera, origin: "https://example.test/private", isMainFrame: true)
        ] {
            #expect(await policy.resolve(request, profileID: profile, isCurrent: { true }) { _, _ in prompted = true; return .alwaysAllow } == .deny)
        }
        #expect(!prompted)
    }

    @Test("A pending prompt cannot overwrite a newer block from another window")
    func concurrentRevocation() async throws {
        let policy = BrowserSitePermissionPolicy(store: try BrowserSitePermissionStore())
        let result = await policy.resolve(request, profileID: profile, isCurrent: { true }) { _, _ in
            try! await policy.store.set(.block, for: [.camera], origin: origin, profileID: profile)
            return .alwaysAllow
        }
        #expect(result == .deny)
        #expect(await policy.store.setting(for: .camera, origin: origin, profileID: profile) == .block)
    }

    @Test("Popover keeps HTTPS security unknown without native evidence")
    func viewModel() {
        let secure = BrowserSiteControlsModel(url: URL(string: origin.value), zoom: 1.25, permissions: [.camera: .ask],
            capabilities: [.audioMuting], canClearData: true)
        #expect(secure.connection == .unavailable)
        #expect(secure.zoomPercent == 125)
        #expect(!secure.canMute)
        #expect(secure.media.isAudible == nil)
        #expect(secure.canClearData)
        let internalPage = BrowserSiteControlsModel(url: URL(string: "about:blank"), zoom: .nan, permissions: [:],
            media: BrowserMediaState(playback: .playing, isAudible: false, isAudioMuted: true),
            capabilities: [.audioMuting], canClearData: true)
        #expect(internalPage.connection == .internalPage)
        #expect(internalPage.origin == nil)
        #expect(!internalPage.canClearData)
        #expect(internalPage.canMute)
        #expect(internalPage.zoomPercent == 100)
        let insecure = BrowserSiteControlsModel(url: URL(string: "http://example.test"), zoom: 1, permissions: [:],
            capabilities: [], canClearData: false)
        #expect(insecure.connection == .insecure)
    }
}
}
