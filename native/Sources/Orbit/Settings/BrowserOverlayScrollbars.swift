import BrowserCore
import BrowserEngine
import BrowserShell
import SwiftUI

/// The page scrollbar style is fixed when the engine starts, so the setting applies at launch.
@MainActor
enum BrowserOverlayScrollbars {
    static let title = "Overlay scrollbars on web pages"
    /// What the running engine was started with; nil before a Chromium runtime starts.
    static var enabledAtLaunch: Bool?

    static var explanation: String {
        uiText("Shows thin scrollbars over page content instead of beside it. Sites that style their own scrollbars keep their design.")
    }

    static func state(enabled: Bool, atLaunch: Bool?) -> String? {
        guard let atLaunch, atLaunch != enabled else { return nil }
        return enabled ? uiText("Restart Circa to show overlay scrollbars.")
            : uiText("Restart Circa to restore classic scrollbars.")
    }
}

/// Uses the existing Settings switch row layout with a secondary caption.
@MainActor
struct BrowserOverlayScrollbarsSettingsRow<Engine: BrowserEngine>: View {
    @ObservedObject var model: BrowserSettingsModel<Engine>
    @ObservedObject private var runtime: BrowserSettingsRuntime

    init(model: BrowserSettingsModel<Engine>) {
        self.model = model
        runtime = model.runtime
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                OrbitIcon.view(sfName: "scroll", pointSize: 20).font(.system(size: 20)).frame(width: 20, height: 20)
                Text(uiText(BrowserOverlayScrollbars.title)).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Toggle(uiText(BrowserOverlayScrollbars.title), isOn: Binding(get: { runtime.document.overlayScrollbars }, set: { next in
                    model.perform { try await model.setOverlayScrollbars(next) }
                })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityIdentifier("settings-overlay-scrollbars")
                    .disabled(model.environment.engine.kind != .chromium)
            }
            Text(BrowserOverlayScrollbars.explanation).font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 32)
            if let state = BrowserOverlayScrollbars.state(enabled: runtime.document.overlayScrollbars,
                                                          atLaunch: BrowserOverlayScrollbars.enabledAtLaunch) {
                Text(state).font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 32)
                    .accessibilityIdentifier("settings-overlay-scrollbars-state")
            }
        }.padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}
