import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

private final class LibraryAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    let release = DispatchSemaphore(value: 0)
    var entered: Bool { lock.withLock { started } }
    func hold() {
        lock.withLock { started = true }
        _ = release.wait(timeout: .now() + 10)
    }
}
private extension BrowserStore {
    func holdForLibraryAdmission(_ gate: LibraryAdmissionGate) { gate.hold() }
}

extension NativeWebKitTests {
@Suite("Library admission R2", .serialized)
@MainActor
struct LibraryCatalogAdmissionR2Tests {
    @Test("Actual presentation lifecycle revokes selection before actor admission",
          arguments: ["hide", "category", "close", "freeze", "retire"])
    func lifecycleBeforeAdmission(action: String) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic catalog admission")
        let first = try await store.createSpace(name: "First", profileID: profile)
        let target = try await store.createSpace(name: "Target", profileID: profile)
        let windowID = try await store.createWindow(activeSpaceID: first)
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: first,
            engine: SiteSyntheticEngine(), restoringWindowID: windowID, onClose: {}, onActivate: {})
        defer { controller.session.close(); controller.window?.close() }
        await controller.session.waitForPendingCommands()
        controller.showLibrary(.spaces)
        await controller.session.waitForPendingCommands()
        let catalog = try #require(controller.session.catalog)
        let gate = LibraryAdmissionGate()
        let holder = Task.detached { await store.holdForLibraryAdmission(gate) }
        defer { gate.release.signal() }
        try await withNativeTestDeadline("Store gate entered", timeout: 3) {
            while !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        }
        let (_, admission) = controller.library.beginSelection()
        var checks = 0
        var accepted: Bool?
        controller.session.activateCatalogSpace(target, catalog: catalog, admission: admission, isCurrent: {
            checks += 1
            return true
        }, completion: { accepted = $0 })
        try await withNativeTestDeadline("Main check passed before actor admission", timeout: 3) {
            while checks == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        switch action {
        case "hide": controller.hideLibrary()
        case "category": controller.library.category = .history
        case "close": controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        case "freeze": controller.freezeCommandsForTermination()
        case "retire": controller.retireForTermination()
        default: Issue.record("Unexpected test action")
        }
        #expect(admission.state == .revoked)
        gate.release.signal()
        await holder.value
        await controller.session.waitForPendingCommands()
        #expect(accepted == false)
        if action == "close" {
            #expect(!(await store.sessionDocument()).windows.contains(where: { $0.id == windowID }))
        } else {
            #expect(try await store.captureWindowState(in: windowID).snapshot.activeSpaceID == first)
        }
    }

    @Test("Only the latest pending inventory intent is retained and old completion cannot retire it")
    func pendingReplacement() {
        let presentation = BrowserLibraryPresentation()
        let (firstID, first) = presentation.beginSelection()
        let (_, second) = presentation.beginSelection()
        #expect(first.state == .revoked && second.state == .pending)
        presentation.finishSelection(firstID)
        #expect(second.state == .pending)
        presentation.isPresented = false
        #expect(second.state == .revoked)
    }

    @Test("Releasing a presentation revokes a pending intent retained by queued work")
    func presentationDeinit() {
        var presentation: BrowserLibraryPresentation? = BrowserLibraryPresentation()
        let (_, admission) = presentation!.beginSelection()
        weak var released = presentation
        presentation = nil
        #expect(released == nil && admission.state == .revoked)
    }

    @Test("Accepted store selection survives presentation cancellation and its token cannot be replayed")
    func admittedIntent() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic accepted inventory")
        let first = try await store.createSpace(name: "First", profileID: profile)
        let target = try await store.createSpace(name: "Target", profileID: profile)
        let windowID = try await store.createWindow(activeSpaceID: first)
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: first,
            engine: SiteSyntheticEngine(), restoringWindowID: windowID, onClose: {}, onActivate: {})
        defer { controller.session.close(); controller.window?.close() }
        await controller.session.waitForPendingCommands()
        controller.showLibrary(.spaces)
        await controller.session.waitForPendingCommands()
        let (_, admission) = controller.library.beginSelection()
        let catalog = try #require(controller.session.catalog)
        var accepted: Bool?
        controller.session.activateCatalogSpace(target, catalog: catalog, admission: admission,
            isCurrent: { true }, completion: { accepted = $0 })
        await controller.session.waitForPendingCommands()
        #expect(accepted == true && admission.state == .admitted)
        controller.hideLibrary()
        #expect(!admission.revoke() && admission.state == .admitted)
        #expect(controller.session.snapshot?.activeSpaceID == target)
        accepted = nil
        controller.session.activateCatalogSpace(first, catalog: catalog, admission: admission,
            isCurrent: { true }, completion: { accepted = $0 })
        await controller.session.waitForPendingCommands()
        #expect(accepted == false && controller.session.snapshot?.activeSpaceID == target)
    }
}
}
