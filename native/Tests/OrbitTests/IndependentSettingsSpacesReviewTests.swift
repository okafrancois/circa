import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

/// A callback-free actor turn held until the reviewer releases it. No product hook is added.
private final class ReviewCatalogGate: @unchecked Sendable {
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
    func holdForCatalogReview(_ gate: ReviewCatalogGate) { gate.hold() }
}

extension NativeWebKitTests {
@Suite("Independent Settings and Spaces review", .serialized)
@MainActor
struct IndependentSettingsSpacesReviewTests {
    private typealias Controller = BrowserWindowController<SiteSyntheticEngine>
    private func fixture(onInput: ((@escaping @MainActor (Controller) -> Void) -> Void)? = nil) async throws
        -> (Controller, BrowserStore, SpaceID, SpaceID) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Independent Inventory")
        let first = try await store.createSpace(name: "First", profileID: profile)
        let target = try await store.createSpace(name: "Target", profileID: profile)
        let id = try await store.createWindow(activeSpaceID: first)
        let controller = Controller(id: UUID(), store: store, spaceID: first, engine: SiteSyntheticEngine(),
            restoringWindowID: id, onInput: onInput, onClose: {}, onActivate: {})
        await controller.session.waitForPendingCommands()
        return (controller, store, first, target)
    }

    @Test("Revocation before actor admission must reject a pending catalog activation")
    func revocationBeforeActorAdmission() async throws {
        let (controller, store, first, target) = try await fixture()
        defer { controller.session.close(); controller.window?.close() }
        let catalog = try #require(controller.session.catalog)
        let gate = ReviewCatalogGate()
        let holder = Task.detached { await store.holdForCatalogReview(gate) }
        defer { gate.release.signal() }
        try await withNativeTestDeadline("Actor review gate entered", timeout: 3) {
            while !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        }
        let admission = CatalogSelectionAdmission()
        var current = true
        var checks = 0
        var accepted: Bool?
        controller.session.activateCatalogSpace(target, catalog: catalog, admission: admission, isCurrent: {
            checks += 1
            return current
        }, completion: { accepted = $0 })
        try await withNativeTestDeadline("Main actor admission check reached", timeout: 3) {
            while checks == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        // The store is still executing the preceding actor turn: no activation was admitted.
        #expect(gate.entered && accepted == nil)
        current = false
        admission.revoke()
        gate.release.signal()
        await holder.value
        await controller.session.waitForPendingCommands()
        #expect(accepted == false)
        #expect(controller.session.snapshot?.activeSpaceID == first)
    }

    @Test("Revocation after the store accepted selection does not roll it back")
    func acceptedStoreBoundary() async throws {
        let (controller, _, _, target) = try await fixture()
        defer { controller.session.close(); controller.window?.close() }
        var current = true
        let previous = controller.session.onChange
        controller.session.onChange = {
            previous?()
            if controller.session.snapshot?.activeSpaceID == target { current = false }
        }
        var accepted: Bool?
        controller.session.activateCatalogSpace(target, catalog: try #require(controller.session.catalog), admission: CatalogSelectionAdmission(),
            isCurrent: { current }, completion: { accepted = $0 })
        await controller.session.waitForPendingCommands()
        #expect(!current && accepted == true)
        #expect(controller.session.snapshot?.activeSpaceID == target)
        controller.session.onChange = previous
    }

    @Test("An actual deferred row action cannot close or activate a reopened presentation")
    func deferredRowAfterReopen() async throws {
        var deferred: (@MainActor (Controller) -> Void)?
        let (controller, _, first, target) = try await fixture(onInput: { deferred = $0 })
        defer { controller.session.close(); controller.window?.close() }
        controller.showLibrary(.spaces)
        await controller.session.waitForPendingCommands()
        let view = controller.library.spacesView
        view.table.selectRowIndexes(IndexSet(integer: try #require(view.rows.firstIndex { $0.space.id == target })), byExtendingSelection: false)
        view.openSelected()
        let click = try #require(deferred)
        controller.hideLibrary()
        controller.showLibrary(.spaces)
        await controller.session.waitForPendingCommands()
        let ticket = controller.library.presentationID
        click(controller)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.activeSpaceID == first)
        #expect(controller.library.isPresented && controller.library.presentationID == ticket)
    }

    @Test("Deleted targets reject the displayed catalog without selecting a fallback")
    func deletedTarget() async throws {
        let (controller, store, first, target) = try await fixture()
        defer { controller.session.close(); controller.window?.close() }
        let catalog = try #require(controller.session.catalog)
        try await store.removeSettingsSpace(target)
        var accepted: Bool?
        controller.session.activateCatalogSpace(target, catalog: catalog, admission: CatalogSelectionAdmission(), isCurrent: { true }, completion: { accepted = $0 })
        await controller.session.waitForPendingCommands()
        #expect(accepted == false && controller.session.snapshot?.activeSpaceID == first)
    }

    @Test("Native category switching finishes ordinary editing without submitting a rename")
    func ordinaryEditCompletion() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let model = BrowserSettingsModel(environment: environment, profileID: nil, shortcuts: OrbitCommandCatalog.definitions,
            defaultBrowser: .init(status: { .init(http: "synthetic", https: "synthetic", html: "synthetic") },
                canRequest: { false }, request: { Issue.record("Unexpected system request") }))
        await model.reload()
        let controller = BrowserSettingsWindowController(model: model)
        let window = try #require(controller.window)
        defer { window.close() }
        let field = BrowserSettingsNameTextField()
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 25)
        let draft = BrowserSettingsNameDraft(name: "Original")
        field.draft = draft
        field.applyDraft()
        var submissions = 0
        field.onSubmit = { submissions += 1 }
        window.contentView?.addSubview(field)
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.string = "Unsubmitted Draft"
        field.editorDidChange(editor)
        #expect(controller.selectSection(.about))
        #expect(field.currentEditor() == nil && submissions == 0)
        #expect(draft.text == "Unsubmitted Draft")
        // settings-window-2026-10-27.md: About is a deep link outside the six toolbar tabs.
        #expect(window.toolbar?.selectedItemIdentifier == nil)
        #expect(model.settingsSection == .about && window.title == BrowserSettingsSection.about.title)
        #expect(!window.isVisible)
    }

    @Test("Every native overflow action restores selection while termination admission is suspended")
    func overflowDuringTermination() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let model = BrowserSettingsModel(environment: environment, profileID: nil, shortcuts: [],
            defaultBrowser: .init(status: { .init(http: "synthetic", https: "synthetic", html: "synthetic") },
                canRequest: { false }, request: { Issue.record("Unexpected system request") }))
        await model.reload()
        // settings-window-2026-10-27.md: Links is one of the six native toolbar tabs.
        model.settingsSection = .links
        let controller = BrowserSettingsWindowController(model: model)
        let window = try #require(controller.window)
        defer { window.close() }
        try await model.suspendForTermination(timeout: .seconds(2))
        for item in try #require(window.toolbar).items {
            let menu = try #require(item.menuFormRepresentation)
            #expect(NSApplication.shared.sendAction(try #require(menu.action), to: menu.target, from: menu))
            #expect(model.settingsSection == .links)
            #expect(window.toolbar?.selectedItemIdentifier == BrowserSettingsSection.links.toolbarIdentifier)
        }
        model.resumeAfterCancelledTermination()
        #expect(controller.selectSection(.general))
        #expect(!window.isVisible)
    }
    @Test("All six native Settings key equivalents select their own category")
    func allCategoryKeys() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let model = BrowserSettingsModel(environment: environment, profileID: nil, shortcuts: [],
            defaultBrowser: .init(status: { .init(http: "synthetic", https: "synthetic", html: "synthetic") },
                canRequest: { false }, request: { Issue.record("Unexpected system request") }))
        await model.reload()
        let controller = BrowserSettingsWindowController(model: model)
        let window = try #require(controller.window)
        defer { window.close() }
        // settings-window-2026-10-27.md: six tabs use physical number keys on AZERTY too.
        let numberKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22]
        for (index, section) in BrowserSettingsSection.allCases.enumerated() {
            let key = String(index + 1)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: numberKeyCodes[index]))
            #expect(window.performKeyEquivalent(with: event))
            #expect(model.settingsSection == section)
            #expect(window.toolbar?.selectedItemIdentifier == section.toolbarIdentifier)
        }
        #expect(!window.isVisible)
    }

    @Test("Composing search commands cannot activate a row or dismiss the inventory")
    func composingSearch() async throws {
        let (controller, _, first, _) = try await fixture()
        defer { controller.session.close(); controller.window?.close() }
        controller.showLibrary(.spaces)
        await controller.session.waitForPendingCommands()
        let view = controller.library.spacesView
        view.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let editor = NSTextView()
        editor.setMarkedText("に", selectedRange: .init(location: 1, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)),
                         #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:))] {
            #expect(!view.control(view.searchField, textView: editor, doCommandBy: selector))
        }
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.activeSpaceID == first && controller.library.isPresented)
        #expect(view.table.selectedRow == 1 && editor.hasMarkedText())
    }

}
}
