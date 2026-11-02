import AppKit
import BrowserCore
import BrowserShell
import SwiftUI
import Testing
@testable import Orbit

@MainActor
struct BrowserAssistantSheetTests {
    @Test func modalCommandsRemainBlockedUntilEditorIsRemoved() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.session.close(); controller.window?.close() }
        let window = try #require(controller.window)
        let sheet = BrowserAssistantSheet()
        var admitted = true
        var dismissed = 0
        sheet.onDismiss = { dismissed += 1 }
        sheet.show(in: window, content: AnyView(Text("Synthetic editor").frame(width: 400, height: 260)), valid: { admitted })
        #expect(controller.commandState.isModal)
        #expect(sheet.overlay?.superview === window.contentView)
        #expect(sheet.overlay?.subviews.first?.frame.size == NSSize(width: 400, height: 260))
        admitted = false
        sheet.close(animated: false)
        #expect(sheet.overlay == nil)
        #expect(!controller.commandState.isModal)
        #expect(dismissed == 1)
        sheet.show(in: window, content: AnyView(Text("Synthetic editor")), valid: { admitted })
        #expect(sheet.overlay == nil)
        admitted = true
        sheet.show(in: window, content: AnyView(Text("Synthetic editor")), valid: { admitted })
        admitted = false
        sheet.show(in: window, content: AnyView(Text("Replacement context")), valid: { true })
        #expect(sheet.overlay == nil)
        #expect(dismissed == 2)
    }
}
