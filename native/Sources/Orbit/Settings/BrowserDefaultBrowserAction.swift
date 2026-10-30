import SwiftUI

/// The status replaces the request action only after every default handler matches.
struct BrowserDefaultBrowserAction: View {
    let isDefault: Bool
    let canRequest: Bool
    let request: () -> Void

    var label: String { isDefault ? uiText("Default browser") : uiText("Make Default") }
    var body: some View {
        Group {
            if isDefault {
                Label(label, systemImage: "checkmark")
                    .foregroundStyle(Color(nsColor: OrbitFloatingMaterial.body))
                    .accessibilityIdentifier("settings-default-browser-confirmed")
            } else {
                Button(label, action: request)
                    .disabled(!canRequest)
                    .accessibilityIdentifier("settings-default-browser")
            }
        }
    }
}
