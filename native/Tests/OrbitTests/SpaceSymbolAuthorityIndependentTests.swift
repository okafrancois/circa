import AppKit
import BrowserCore
import BrowserShell
import Foundation
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Independent Space symbol authority", .serialized)
@MainActor
struct SpaceSymbolAuthorityIndependentTests {
    init() { NSApplication.shared.setActivationPolicy(.prohibited) }

    @Test("Queued Settings edits reject profile selection ABA, reassignment and archive; a fresh target still works")
    func queuedSettingsRevocation() async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let profile = try #require(controller.session.activeProfileID)
        let other = await environment.store.createProfile(name: "Synthetic symbol other")
        let target = try await environment.store.createSpace(name: "Synthetic symbol target", profileID: profile)
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        var release: CheckedContinuation<Void, Never>?
        func holdQueue() async throws {
            release = nil
            model.perform { await withCheckedContinuation { release = $0 } }
            try await withNativeTestDeadline("Independent Settings queue gate", timeout: 3) {
                while release == nil { await Task.yield() }
            }
        }
        try await holdQueue()
        model.queueSpaceIconEdit(spaceID: target, profileID: profile, icon: .systemSymbol("star.fill"))
        model.selectProfile(other); model.selectProfile(profile)
        release?.resume(); release = nil
        await model.waitForPendingActions()
        #expect(environment.settings.document.space(target).iconSelection == .none)
        try await holdQueue()
        model.queueSpaceIconEdit(spaceID: target, profileID: profile, icon: .systemSymbol("star.fill"))
        try await environment.store.assignSettingsSpace(target, to: other)
        release?.resume(); release = nil
        await model.waitForPendingActions()
        #expect(environment.settings.document.space(target).iconSelection == .none)
        try await environment.store.assignSettingsSpace(target, to: profile)
        try await holdQueue()
        model.queueSpaceIconEdit(spaceID: target, profileID: profile, icon: .systemSymbol("star.fill"))
        try await environment.removeSpaceFromSettings(target, expectedProfileID: profile)
        release?.resume(); release = nil
        await model.waitForPendingActions()
        #expect(environment.settings.document.spaces[target] == nil)
        try await environment.store.restoreSettingsSpace(target, expectedProfileID: profile)
        model.queueSpaceIconEdit(spaceID: target, profileID: profile, icon: .systemSymbol("star.fill"))
        await model.waitForPendingActions()
        #expect(environment.settings.document.space(target).iconSelection == .systemSymbol("star.fill"))
        #expect(controller.window?.isVisible == false)
    }

    @Test("Already-open Libraries and both profile footers track symbol to grapheme to none without a stale image")
    func openProjectionAcrossProfiles() async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let first = try await environment.makeWindow()
        let id = try #require(first.session.snapshot?.activeSpaceID)
        let firstProfile = try #require(first.session.activeProfileID)
        let secondProfile = await environment.store.createProfile(name: "Synthetic distinct symbol profile")
        let other = try await environment.store.createSpace(name: "Synthetic distinct symbol Space", profileID: secondProfile)
        let second = try await environment.makeWindow(spaceID: other)
        defer { environment.autoArchive.scheduler.stop(); first.window?.close(); second.window?.close() }
        first.showLibrary(.spaces); second.showLibrary(.spaces)
        await first.session.waitForPendingCommands(); await second.session.waitForPendingCommands()
        let presentation = first.library.presentationID
        try await environment.settings.updateSpace(other) { $0.iconSelection = .systemSymbol("heart.fill"); $0.palette = .lavender }
        let untouched = environment.settings.document.space(other)
        for choice in [BrowserSpaceIcon.systemSymbol("star.fill"), .grapheme("🇯🇵"), .none] {
            let model = BrowserSettingsModel(environment: environment, profileID: firstProfile, shortcuts: [])
            model.queueSpaceIconEdit(spaceID: id, profileID: firstProfile, icon: choice)
            await model.waitForPendingActions()
            #expect(first.sidebar.footer.spaceButtons.first { $0.space.id == id }?.iconSelection == choice)
            #expect(second.sidebar.footer.spaceButtons.first { $0.space.id == other }?.iconSelection == .systemSymbol("heart.fill"))
            for controller in [first, second] {
                let library = controller.library.spacesView
                let index = try #require(library.rows.firstIndex { $0.space.id == id })
                #expect(library.rows[index].iconSelection == choice)
                let row = try #require(library.tableView(library.table, viewFor: nil, row: index) as? NSStackView)
                let image = try #require(row.arrangedSubviews.first as? NSImageView)
                let settings = try #require(BrowserSettingsIconPreview.projection(choice) as? NSImageView)
                #expect(image.image === settings.image)
                #expect(image.accessibilityLabel() == SpaceIconImages.label(choice))
                #expect(controller.window?.isVisible == false)
            }
            #expect(environment.settings.document.space(other) == untouched)
            #expect(first.library.presentationID == presentation)
        }
    }

    @Test("Search ABA and disabled mouse authority cannot select a replacement typed grid")
    func mouseAndAccessibilityGenerations() throws {
        let picker = SpaceIconPicker(currentChoice: .systemSymbol("star.fill"), accent: .defaultSpace)
        picker.setSearch("star")
        let window = SymbolReviewHiddenWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = picker.view
        defer { window.close() }
        var choices: [BrowserSpaceIcon] = []
        picker.onChooseIcon = { choices.append($0) }
        let old = try #require((picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        let point = picker.grid.convert(NSPoint(x: 25, y: 17), to: nil)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        picker.grid.mouseDown(with: try mouse(.leftMouseDown))
        picker.setSearch("heart"); picker.setSearch("star")
        picker.grid.mouseUp(with: try mouse(.leftMouseUp))
        #expect(!old.accessibilityPerformPress() && choices.isEmpty)
        picker.grid.mouseDown(with: try mouse(.leftMouseDown))
        picker.grid.choicesEnabled = false; picker.grid.choicesEnabled = true
        picker.grid.mouseUp(with: try mouse(.leftMouseUp))
        #expect(choices.isEmpty)
        let fresh = try #require((picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        #expect(fresh.accessibilityPerformPress())
        #expect(choices == [.systemSymbol("star.fill")])
        #expect(!fresh.accessibilityPerformPress())
    }

    @Test("Unavailable valid symbols degrade visually without erasing typed data; malformed names never create images")
    func unavailableAndCacheIdentity() throws {
        let unknown = BrowserSpaceIcon.systemSymbol("future.unavailable.symbol.922337")
        #expect(unknown.isValid)
        let view = try #require(SpaceIconImages.view(unknown) as? NSImageView)
        #expect(view.image === SpaceIconImages.template("circle", pointSize: 22))
        for invalid in ["../star", "star/../../file", "star\0fill", "star..fill", "Star.fill"] {
            #expect(SpaceIconImages.template(invalid, pointSize: 22) == nil)
        }
        let light = try #require(NSAppearance(named: .aqua)), dark = try #require(NSAppearance(named: .darkAqua))
        let dynamic = NSColor(name: "synthetic-symbol-accent") { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .green : .red
        }
        let a = try #require(SpaceIconImages.symbol("star.fill", pointSize: 15, tint: dynamic, active: true, appearance: light))
        #expect(a === SpaceIconImages.symbol("star.fill", pointSize: 15, tint: dynamic, active: true, appearance: light))
        #expect(a !== SpaceIconImages.symbol("star.fill", pointSize: 15, tint: dynamic, active: true, appearance: dark))
        #expect(a !== SpaceIconImages.symbol("star.fill", pointSize: 22, tint: dynamic, active: true, appearance: light))
        #expect(a !== SpaceIconImages.symbol("star.fill", pointSize: 15, tint: dynamic, active: false, appearance: light))
    }
}
}

/// This gate holds only the synthetic settings actor; it never touches a GUI or personal path.
private final class SymbolSettingsActorGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false
    private let release = DispatchSemaphore(value: 0)
    var entered: Bool { lock.withLock { didEnter } }
    func hold() { lock.withLock { didEnter = true }; _ = release.wait(timeout: .now() + 5) }
    func resume() { release.signal() }
}

extension NativeWebKitTests {
@Suite("Independent Space symbol adverse authority", .serialized)
@MainActor
struct SpaceSymbolAuthorityAdverseTests {
    init() { NSApplication.shared.setActivationPolicy(.prohibited) }

    @Test("A Settings icon write suspended after catalog admission must reject a Space reassigned before publication")
    func reprofileDuringSettingsActorWait() async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let profile = try #require(controller.session.activeProfileID)
        let other = await environment.store.createProfile(name: "Synthetic adverse profile")
        let target = try await environment.store.createSpace(name: "Synthetic adverse target", profileID: profile)
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        let gate = SymbolSettingsActorGate(), settings = environment.settings.store, blockerID = SpaceID()
        let holder = Task.detached { try await settings.updateSpace(blockerID) { _ in gate.hold() } }
        defer { gate.resume() }
        try await withNativeTestDeadline("Synthetic settings actor entered", timeout: 3) {
            while !gate.entered { try await Task.sleep(for: .milliseconds(2)) }
        }
        model.queueSpaceIconEdit(spaceID: target, profileID: profile, icon: .systemSymbol("star.fill"))
        // Give the free MainActor/catalog actor time to pass both guards and suspend on settings.
        // The adverse mutation itself is awaited, not a racing fire-and-forget operation.
        try await Task.sleep(for: .milliseconds(100))
        try await environment.store.assignSettingsSpace(target, to: other)
        gate.resume(); try await holder.value
        await model.waitForPendingActions()
        let catalog = await environment.store.catalogSnapshot()
        #expect(catalog.spaces.first { $0.id == target }?.profileID == other)
        #expect(environment.settings.document.space(target).iconSelection == .none,
            "Captured old-profile action must not mutate the reassigned Space")
        #expect(controller.window?.isVisible == false)
    }
}
}
