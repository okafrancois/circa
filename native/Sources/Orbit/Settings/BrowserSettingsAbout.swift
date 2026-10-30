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
            Button(uiText("Check for Updates…")) { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates).accessibilityIdentifier("settings-check-updates")
            Text(uiText("Built for macOS. Your profiles and browsing data stay on this Mac."))
                .font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.top, 6).accessibilityIdentifier("settings-about-orbit")
    }
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? uiText("Development build")
        return (info["CFBundleVersion"] as? String).map { version + " (" + $0 + ")" } ?? version
    }
}
