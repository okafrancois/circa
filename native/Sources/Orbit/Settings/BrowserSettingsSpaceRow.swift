import BrowserCore
import BrowserShell
import SwiftUI

/// The list projects the same stored icon and theme as the detail editor.
struct BrowserSettingsSpaceRow: View {
    let space: BrowserSpace
    let theme: BrowserSpaceTheme?
    let icon: BrowserSpaceIcon
    let isSelected: Bool
    var planetIndex: Int = 0
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Group {
                    if case .planet(let variant) = icon, let image = SpaceIconImages.planet(variant, defaultIndex: planetIndex) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        BrowserSettingsIconPreview(choice: icon)
                    }
                }.frame(width: 22, height: 22)
                Text(space.name).lineLimit(2)
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.vertical, 7)
                .background(isSelected ? Color(nsColor: BrandPalette.pageWhite) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color(nsColor: BrandPalette.ink) : .clear, lineWidth: 2))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .foregroundStyle(OrbitSettingsStyle.foreground)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("settings-space-" + space.id.rawValue.uuidString)
    }
}
