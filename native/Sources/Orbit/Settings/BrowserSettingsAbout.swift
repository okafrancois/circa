import AppKit
import BrowserCore
import BrowserShell
import SwiftUI

struct BrowserSettingsAbout: View {
    @ObservedObject var updater: OrbitUpdater
    @ObservedObject var icons = OrbitAppIconController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) { SettingsPaneIcon(section: .about).frame(width: 22, height: 22); Text(uiText("About Circa")).font(Font(BrandTextStyle.title.font(size: 21))).kerning(-0.945) }
            VStack(spacing: 4) {
                if let image = BrandFonts.mark { Image(nsImage: image).resizable().scaledToFit().frame(width: 62, height: 62) }
                Text(ProductIdentity.displayName).font(Font(BrandTextStyle.title.font(size: 30))).kerning(-1.35)
                Text(version.uppercased()).font(Font(BrandFonts.mono(10))).foregroundStyle(.secondary).textSelection(.enabled)
                Text(uiText("Space to think.")).font(Font(BrandFonts.onboardingBody(13))).padding(.bottom, 8)
                HStack(spacing: 10) {
                    Button(uiText("Check for Updates…")) { updater.checkForUpdates() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(OrbitPrintButtonStyle(primary: true)).disabled(!updater.canCheckForUpdates)
                        .accessibilityIdentifier("settings-check-updates")
                    Button(uiText("Copy Version")) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(version, forType: .string)
                    }.buttonStyle(OrbitPrintButtonStyle()).accessibilityIdentifier("settings-copy-version")
                }
            }
            .frame(maxWidth: .infinity).padding(.top, 6).padding(.bottom, 12)
            .background(LinearGradient(stops: [.init(color: Color(nsColor: BrandPalette.rgb(0xC9D8FA)), location: 0),
                                               .init(color: Color(nsColor: BrandPalette.pageWhite), location: 0.75)],
                                       startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OrbitSettingsStyle.border, lineWidth: 1))
            Text(uiText("Free and open source, MIT license. Built with Swift, AppKit and Chromium."))
                .font(Font(BrandFonts.ui(10.5))).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .contain).accessibilityIdentifier("settings-about-orbit")
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
