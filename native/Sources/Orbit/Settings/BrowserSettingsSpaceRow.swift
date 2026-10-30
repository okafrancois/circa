import BrowserCore
import SwiftUI

/// The list projects the same stored icon and theme as the detail editor.
struct BrowserSettingsSpaceRow: View {
    let space: BrowserSpace
    let theme: BrowserSpaceTheme?
    let icon: BrowserSpaceIcon
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                ZStack {
                    BrowserSettingsThemeGradient(theme: theme)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(width: 18, height: 18)
                    BrowserSettingsIconPreview(choice: icon).frame(width: 14, height: 14)
                }.frame(width: 22, height: 22)
                Text(space.name).lineLimit(2)
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.vertical, 7)
                .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .foregroundStyle(isSelected ? .white : OrbitSettingsStyle.foreground)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("settings-space-" + space.id.rawValue.uuidString)
    }
}
