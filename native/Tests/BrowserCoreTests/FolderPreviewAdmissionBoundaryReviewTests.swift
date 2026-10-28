import Foundation
import Testing
@testable import BrowserCore

/// Revokes from an existing synchronous dependency after the admission read and before
/// selectOccurrence writes its new selection. No scheduler timing or production hook is needed.
private final class SelectionAdmissionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var admission: BrowserSidebarSelectionAdmission?
    func arm(_ admission: BrowserSidebarSelectionAdmission) { lock.withLock { self.admission = admission } }
    func read() -> Date {
        lock.withLock { admission?.revoke() }
        return Date(timeIntervalSinceReferenceDate: 800_000_000)
    }
}

@Suite("Independent folder preview admission boundary")
struct FolderPreviewAdmissionBoundaryReviewTests {
    @Test("Revocation after store admission cannot roll back the synchronous selection")
    func independentPostAdmissionBoundary() async throws {
        let clock = SelectionAdmissionClock()
        let store = BrowserStore(clock: { clock.read() })
        let profile = await store.createProfile(name: "Synthetic boundary")
        let space = try await store.createSpace(name: "Synthetic space", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        let first = try await store.openTab(url: organizationURL("boundary-first"), from: store.captureContext(in: window), activate: true)
        _ = try await store.openTab(url: organizationURL("boundary-second"), from: store.captureContext(in: window), activate: true)
        let context = try await store.captureContext(in: window)
        let expected = try await store.organizationSnapshot(from: context)
        let target = try #require(expected.allTabs.first { $0.occurrenceID == first }?.id)
        let admission = BrowserSidebarSelectionAdmission()
        clock.arm(admission)
        let state = try await store.selectTab(target, from: context, expecting: expected, admission: admission)
        #expect(!admission.isValid)
        #expect(state.organization.selectedTab?.id == target)
        // This documents admission semantics, not an atomic lock around mutation.
        let committed = await store.sessionDocument()
        _ = try await store.selectTab(target, from: store.captureContext(in: window), admission: admission)
        #expect(await store.sessionDocument() == committed)
    }
}
