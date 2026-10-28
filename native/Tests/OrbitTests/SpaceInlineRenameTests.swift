import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

/// Hidden source tests: the synthetic window is never ordered on screen.
extension NativeWebKitTests {
@Suite("Space header in-place rename", .serialized)
@MainActor
struct SpaceInlineRenameTests {
    private func makeController() async throws -> (BrowserEnvironment<SiteSyntheticEngine>, BrowserWindowController<SiteSyntheticEngine>) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        return (environment, try await environment.makeWindow())
    }

    @Test("Return commits a trimmed changed name once; Escape, empty and unchanged names never write")
    func commitRules() async throws {
        let (environment, controller) = try await makeController()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let page = controller.sidebar.page
        let original = page.list.subviews.compactMap { $0 as? SidebarSpaceTitleLabel }.first?.stringValue ?? ""
        var names: [String] = []
        #expect(page.beginSpaceRename { names.append($0) })
        #expect(page.isRenamingSpace && !controller.sidebar.swipeCanInteract)
        #expect(!page.beginSpaceRename { names.append("second \($0)") })
        let editor = try #require(page.list.subviews.compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "space-title-editor" })
        #expect(editor.stringValue == original)
        editor.stringValue = "  Synthetic Renamed  "
        let textView = NSTextView()
        #expect(page.control(editor, textView: textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(names == ["Synthetic Renamed"] && !page.isRenamingSpace)

        for (text, selector) in [("Escaped", #selector(NSResponder.cancelOperation(_:))),
                                 ("   ", #selector(NSResponder.insertNewline(_:))),
                                 (original, #selector(NSResponder.insertTab(_:)))] {
            #expect(page.beginSpaceRename { names.append($0) })
            let field = try #require(page.list.subviews.compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "space-title-editor" })
            field.stringValue = text
            #expect(page.control(field, textView: textView, doCommandBy: selector))
            #expect(!page.isRenamingSpace)
        }
        #expect(names == ["Synthetic Renamed"])
        #expect(controller.window?.isVisible == false)
    }

    @Test("Disabling commands or changing the displayed Space cancels without writing; hidden windows use no inline editor")
    func cancellation() async throws {
        let (environment, controller) = try await makeController()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let page = controller.sidebar.page
        var names: [String] = []
        #expect(page.beginSpaceRename { names.append($0) })
        page.setCommandsEnabled(false)
        #expect(!page.isRenamingSpace)
        page.setCommandsEnabled(true)
        #expect(page.beginSpaceRename { names.append($0) })
        page.spaceID = SpaceID()
        #expect(!page.isRenamingSpace && names.isEmpty)
        let space = try #require(controller.session.snapshot?.activeSpaceID)
        #expect(!controller.beginInlineSpaceRename(space))
        #expect(controller.window?.isVisible == false)
    }
}
}
