import Foundation
import Testing
@testable import BrowserCore

@Suite("Space settings ownership through publication")
struct SpaceSettingsPublicationTests {
    @Test("Target reassignment and archive restoration revoke even when the original owner returns")
    func targetEpochs() async throws {
        let browser = BrowserStore(), settings = try BrowserSettingsStore()
        let profile = await browser.createProfile(name: "Synthetic first")
        let other = await browser.createProfile(name: "Synthetic second")
        _ = try await browser.createSpace(name: "Synthetic retained Space", profileID: profile)
        let space = try await browser.createSpace(name: "Synthetic target", profileID: profile)
        let reassigned = try #require(browser.captureSpaceSettingsAuthority(for: space, profileID: profile))
        try await browser.assignSettingsSpace(space, to: other)
        try await browser.assignSettingsSpace(space, to: profile)
        await #expect(throws: BrowserStoreError.staleContext) {
            try await settings.updateSpace(space, authority: reassigned) { $0.iconSelection = .systemSymbol("star.fill") }
        }
        let archived = try #require(browser.captureSpaceSettingsAuthority(for: space, profileID: profile))
        try await browser.removeSettingsSpace(space, expectedProfileID: profile)
        try await browser.restoreSettingsSpace(space, expectedProfileID: profile)
        await #expect(throws: BrowserStoreError.staleContext) {
            try await settings.updateSpace(space, authority: archived) { $0.iconSelection = .systemSymbol("star.fill") }
        }
        #expect(await settings.snapshot().spaces[space] == nil)
        let fresh = try #require(browser.captureSpaceSettingsAuthority(for: space, profileID: profile))
        try await settings.updateSpace(space, authority: fresh) { $0.iconSelection = .systemSymbol("heart.fill") }
        #expect(await settings.snapshot().space(space).iconSelection == .systemSymbol("heart.fill"))
    }

    @Test("The source window rejects profile ABA and close while same-profile navigation preserves authority")
    func sourceEpochs() async throws {
        let browser = BrowserStore(), settings = try BrowserSettingsStore()
        let profile = await browser.createProfile(name: "Synthetic first")
        let other = await browser.createProfile(name: "Synthetic second")
        let first = try await browser.createSpace(name: "Synthetic first Space", profileID: profile)
        let second = try await browser.createSpace(name: "Synthetic same profile", profileID: profile)
        let foreign = try await browser.createSpace(name: "Synthetic other profile", profileID: other)
        let target = try await browser.createSpace(name: "Synthetic icon target", profileID: profile)
        let window = try await browser.createWindow(activeSpaceID: first)
        func capture() throws -> BrowserSpaceSettingsAuthority {
            try #require(browser.captureSpaceSettingsAuthority(for: target, profileID: profile,
                                                              sourceWindow: window, sourceProfile: profile))
        }
        let sameProfile = try capture()
        try await browser.activateSpace(second, in: window)
        try await settings.updateSpace(target, authority: sameProfile) { $0.iconSelection = .grapheme("🧪") }
        let before = await settings.snapshot()
        let aba = try capture()
        try await browser.activateSpace(foreign, in: window)
        try await browser.activateSpace(first, in: window)
        await #expect(throws: BrowserStoreError.staleContext) {
            try await settings.updateSpace(target, authority: aba) { $0.iconSelection = .none }
        }
        let closed = try capture()
        try await browser.closeWindow(window)
        await #expect(throws: BrowserStoreError.staleContext) {
            try await settings.updateSpace(target, authority: closed) { $0.iconSelection = .none }
        }
        #expect(await settings.snapshot() == before)
    }

    @Test("Revocation is one-shot and cancellation during edit preparation prevents publication")
    func explicitRevocationAndPreparation() async throws {
        let browser = BrowserStore(), settings = try BrowserSettingsStore()
        let profile = await browser.createProfile(name: "Synthetic owner")
        let space = try await browser.createSpace(name: "Synthetic target", profileID: profile)
        let revoked = try #require(browser.captureSpaceSettingsAuthority(for: space, profileID: profile))
        revoked.revoke()
        await #expect(throws: BrowserStoreError.staleContext) {
            try await settings.updateSpace(space, authority: revoked) { $0.iconSelection = .systemSymbol("star.fill") }
        }
        let once = try #require(browser.captureSpaceSettingsAuthority(for: space, profileID: profile))
        try await settings.updateSpace(space, authority: once) { $0.iconSelection = .systemSymbol("star.fill") }
        once.revoke()
        await #expect(throws: BrowserStoreError.staleContext) {
            try await settings.updateSpace(space, authority: once) { $0.iconSelection = .none }
        }
        let duringEdit = try #require(browser.captureSpaceSettingsAuthority(for: space, profileID: profile))
        await #expect(throws: BrowserStoreError.staleContext) {
            try await settings.updateSpace(space, authority: duringEdit) { value in
                duringEdit.revoke()
                value.iconSelection = .none
            }
        }
        #expect(await settings.snapshot().space(space).iconSelection == .systemSymbol("star.fill"))
    }

    @Test("Restoration initializes ownership and typed invalid intent cannot be hidden by another field edit")
    func restorationAndInvalidIntent() async throws {
        let browser = BrowserStore()
        let profile = await browser.createProfile(name: "Synthetic owner")
        let space = try await browser.createSpace(name: "Synthetic target", profileID: profile)
        let restored = try BrowserStore(restoring: await browser.sessionDocument())
        let authority = try #require(restored.captureSpaceSettingsAuthority(for: space, profileID: profile))
        let settings = try BrowserSettingsStore()
        await #expect(throws: BrowserSettingsError.invalidIcon) {
            try await settings.updateSpace(space, authority: authority) { value in
                value.iconSelection = .grapheme(""); value.palette = .lavender
            }
        }
        #expect(await settings.snapshot().spaces[space] == nil)
        let fresh = try #require(restored.captureSpaceSettingsAuthority(for: space, profileID: profile))
        try await settings.updateSpace(space, authority: fresh) { $0.icon = "" }
        #expect(await settings.snapshot().space(space).iconSelection == .none)
    }
}
