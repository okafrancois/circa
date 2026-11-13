import AppKit
import BrowserEngineConformance
import SwiftUI
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized) @MainActor
struct SettingsDetailTransitionTests {
    @Test("Pane changes retain a detail-only native boundary and leave navigation outside it")
    func stableDetailBoundary() async throws {
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let model = BrowserSettingsModel(environment: environment, profileID: nil, shortcuts: [])
        let controller = BrowserSettingsWindowController(model: model)
        let window = try #require(controller.window)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        let root = try #require(window.contentView)
        let detail = try #require(controller.detailView)
        #expect(detail !== root)
        for section in [BrowserSettingsSection.general, .ai, .about] {
            #expect(controller.selectSection(section))
            root.layoutSubtreeIfNeeded()
            #expect(controller.detailView === detail)
            let frame = detail.convert(detail.bounds, to: root)
            #expect(abs(frame.minX - 186) < 1)
            #expect(abs(frame.width - (root.bounds.width - 186)) < 1)
            #expect(root.alphaValue == 1 && root.layer?.animation(forKey: "pane-entry") == nil)
            #expect(detail.layer?.animation(forKey: "pane-entry") == nil, "Hidden windows do not animate")
        }
    }

    private struct EnabledProbe: NSViewRepresentable {
        let report: (Bool) -> Void
        func makeNSView(context: Context) -> NSView { report(context.environment.isEnabled); return NSView() }
        func updateNSView(_ view: NSView, context: Context) { report(context.environment.isEnabled) }
    }

    @Test("The native detail boundary preserves the parent's disabled environment")
    func detailEnvironment() {
        var reports: [Bool] = []
        let host = NSHostingView(rootView: BrowserSettingsDetailHost { EnabledProbe { reports.append($0) } }.disabled(true))
        host.setFrameSize(NSSize(width: 900, height: 400))
        host.layoutSubtreeIfNeeded()
        #expect(!reports.isEmpty && reports.allSatisfy { !$0 })
    }

    @Test("AI off removes its detail sections rather than reserving disabled content")
    func aiOffContainsOnlyMasterRow() async throws {
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop(); environment.ai.terminateNow() }
        let model = BrowserSettingsModel(environment: environment, profileID: nil, shortcuts: [])
        func measuredHeight() -> CGFloat {
            let host = NSHostingView(rootView: BrowserSettingsAIPane(model: model, runtime: model.runtime, ai: environment.ai).frame(width: 650))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        #expect(!model.runtime.document.ai.isEnabled)
        let off = measuredHeight()
        #expect(off < 150)
        try await model.runtime.updateAI { $0.isEnabled = true }
        let on = measuredHeight()
        #expect(on > off + 300)
        try await model.runtime.updateAI { $0.isEnabled = false }
        #expect(abs(measuredHeight() - off) < 1)
    }
}
}
