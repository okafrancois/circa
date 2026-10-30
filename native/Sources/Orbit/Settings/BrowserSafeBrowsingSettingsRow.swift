import BrowserCore
import BrowserEngine
import BrowserShell
import SwiftUI

/// Uses the existing Settings card, checkbox, secure field and bordered button controls.
@MainActor
struct BrowserSafeBrowsingSettingsRow<Engine: BrowserEngine>: View {
    @ObservedObject var model: BrowserSettingsModel<Engine>
    @ObservedObject private var runtime: BrowserSettingsRuntime
    @ObservedObject private var browsing: BrowserSafeBrowsing
    @State private var key = ""
    @State private var keyError: String?

    init(model: BrowserSettingsModel<Engine>) {
        self.model = model
        runtime = model.runtime
        browsing = model.safeBrowsing
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(uiText("Safe Browsing"), isOn: Binding(get: { runtime.document.safeBrowsingEnabled }, set: { enabled in
                model.perform { try await model.setSafeBrowsingEnabled(enabled) }
            })).toggleStyle(.checkbox).fontWeight(.medium)
                .accessibilityIdentifier("settings-safe-browsing")
                .disabled(model.environment.engine.kind != .chromium)
            Text(BrowserSafeBrowsing.requirement).font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(BrowserSafeBrowsing.state(enabled: runtime.document.safeBrowsingEnabled, hasKey: browsing.hasKey, configuredAtLaunch: browsing.enabledAtLaunch))
                .font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-safe-browsing-state")
            if runtime.document.safeBrowsingEnabled {
                HStack(spacing: 8) {
                    SecureField(browsing.hasKey ? uiText("Saved key: ••••••••") : uiText("Paste your Google API key"), text: $key)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(uiText("Google API key"))
                        .accessibilityIdentifier("settings-safe-browsing-key")
                    Button(uiText("Save Key")) {
                        do { try browsing.saveKey(key); key = ""; keyError = nil }
                        catch { keyError = uiText("Could not save the API key. Check the key and Keychain access.") }
                    }.disabled(BrowserSafeBrowsingLaunch.normalized(key) == nil)
                        .accessibilityIdentifier("settings-safe-browsing-save")
                    if browsing.hasKey {
                        Button(uiText("Remove Key")) {
                            do { try browsing.removeKey(); key = ""; keyError = nil }
                            catch { keyError = uiText("Could not remove the API key from Keychain.") }
                        }.accessibilityIdentifier("settings-safe-browsing-remove")
                    }
                }
            }
            if let keyError { Text(keyError).font(Font(BrandFonts.ui(12))).foregroundStyle(.red) }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onDisappear { key = "" }
            .onChange(of: runtime.document.safeBrowsingEnabled) { _, _ in key = "" }
    }
}
