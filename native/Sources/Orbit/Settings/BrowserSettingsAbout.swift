import AppKit
import BrowserCore
import BrowserShell
import SwiftUI

struct BrowserSettingsAbout: View {
    @ObservedObject var updater: OrbitUpdater
    var body: some View {
        VStack(spacing: 12) {
            SettingsAppIcon()
                .frame(width: 112, height: 112).accessibilityLabel(uiText("App Icon"))
            Text(ProductIdentity.displayName).font(Font(BrandTextStyle.title.font(size: 36)))
            Text(uiText("A little clarity in your browsing.")).foregroundStyle(.secondary)
            Text(version).font(Font(BrandFonts.mono(11))).foregroundStyle(.secondary)
            Group {
                if updater.canCheckForUpdates {
                    updateButton.keyboardShortcut(.defaultAction)
                } else {
                    updateButton.disabled(true)
                }
            }
            Text(uiText("Built for macOS. Your profiles and browsing data stay on this Mac."))
                .font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.top, 6).accessibilityIdentifier("settings-about-orbit")
    }
    private var updateButton: some View {
        Button(uiText("Check for Updates…")) { updater.checkForUpdates() }
            .accessibilityIdentifier("settings-check-updates")
    }
    private var version: String { Self.versionDescription(info: Bundle.main.infoDictionary ?? [:]) }

    static func versionDescription(info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? uiText("Development build")
        let build = info["CFBundleVersion"] as? String ?? uiText("Development build")
        return uiFormat("Version %@ (%@)", version, build)
    }
}
