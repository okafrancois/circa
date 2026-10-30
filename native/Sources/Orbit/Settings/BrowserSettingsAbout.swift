import AppKit
import BrowserCore
import BrowserShell
import SwiftUI

struct BrowserSettingsAbout: View {
    @ObservedObject var updater: OrbitUpdater
    @ObservedObject var icons = OrbitAppIconController.shared
    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let image = icons.current.image { Image(nsImage: image).resizable().scaledToFit() }
            }.frame(width: 112, height: 112).accessibilityLabel(uiText("App Icon"))
            Text(ProductIdentity.displayName).font(Font(BrandTextStyle.title.font(size: 36))).kerning(BrandTextStyle.title.tracking(size: 36))
            Text(uiText("Everything revolves around you.")).foregroundStyle(.secondary)
            Text(version).font(Font(BrandFonts.mono(11))).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .help(uiText("Copy Version"))
            Group {
                if updater.canCheckForUpdates {
                    updateButton.keyboardShortcut(.defaultAction)
                } else {
                    updateButton.disabled(true)
                }
            }
            BrowserSettingsAppIconButton(icons: icons).fixedSize()
            Text(uiText("Built for macOS. Your profiles and browsing data stay on this Mac."))
                .font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.top, 6).accessibilityElement(children: .contain).accessibilityIdentifier("settings-about-orbit")
    }
    private var updateButton: some View {
        Button(uiText("Check for Updates…")) { updater.checkForUpdates() }
            .accessibilityIdentifier("settings-check-updates")
    }
    private var version: String { Self.versionDescription(info: Bundle.main.infoDictionary ?? [:]) }

    static func versionDescription(info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? uiText("Development build")
        let build = info["CFBundleVersion"] as? String ?? uiText("Development build")
        let app = uiFormat("Version %@ (%@)", version, build)
        guard let chromium = info["OrbitChromiumVersion"] as? String, !chromium.isEmpty else { return app }
        return app + " · " + uiFormat("Chromium %@", chromium)
    }
}
