import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import SwiftUI

/// Timing shared by the window, content, and category indicator.
enum BrowserSettingsMotion {
    static let resizeDuration = 0.38
    static let exitDuration = 0.09
    static let enterDelay = 0.10
    static let enterDuration = 0.32
    static let pillDuration = 0.42
    static let rise: CGFloat = 6
    static let controlPoints: [Float] = [0.19, 1, 0.22, 1]
    static var timingFunction: CAMediaTimingFunction { .init(controlPoints: 0.19, 1, 0.22, 1) }
}

@MainActor
final class BrowserSettingsSelectionPill: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = OrbitSettingsStyle.selectionColor.resolved(for: effectiveAppearance).cgColor
    }
}

@MainActor
final class BrowserSettingsToolbarButton: NSButton {
    // Reserve the native text line height as well as the icon, gap and bottom padding.
    // A fixed 46 pt canvas clipped the category label against the selection indicator.
    private static func contentSize(for title: String) -> NSSize {
        let label = (title as NSString).size(withAttributes: [.font: BrandFonts.ui(11, weight: .medium)])
        return NSSize(width: max(66, ceil(label.width) + 16), height: ceil(5 + 24 + 4 + label.height + 4))
    }
    override var alignmentRectInsets: NSEdgeInsets { .init() }
    let section: BrowserSettingsSection
    init(section: BrowserSettingsSection) {
        self.section = section
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize(for: section.toolbarTitle)))
        isBordered = false
        title = section.toolbarTitle
        setAccessibilityLabel(section.title)
        setAccessibilityIdentifier(section.toolbarIdentifier.rawValue)
        // Toolbar layout otherwise compresses custom views to its default 44 pt slot.
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: intrinsicContentSize.height).isActive = true
    }
    override var intrinsicContentSize: NSSize { Self.contentSize(for: section.toolbarTitle) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        OrbitIcon.image(sfName: section.symbol, pointSize: 24, variant: .color)?.draw(
            in: NSRect(x: (bounds.width - 24) / 2, y: 5, width: 24, height: 24),
            from: .zero, operation: .sourceOver, fraction: isHighlighted ? 0.6 : 1, respectFlipped: true, hints: nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: BrandFonts.ui(11, weight: .medium), .foregroundColor: NSColor.labelColor]
        let text = NSAttributedString(string: title, attributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2, y: 33))
    }
}

private extension NSFont {
    func width(of string: String) -> CGFloat { (string as NSString).size(withAttributes: [.font: self]).width }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OrbitSettingsStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OrbitSettingsStyle.border, lineWidth: 1))
    }
}

private final class SettingsFrostHost: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isOpaque = true
        window?.backgroundColor = OrbitSettingsStyle.windowColor
    }
}

private struct SettingsFrost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = SettingsFrostHost()
        OrbitFloatingMaterial.install(in: view, blending: .behindWindow, radius: 14)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        view.window?.isOpaque = true
        view.window?.backgroundColor = OrbitSettingsStyle.windowColor
    }
}

extension View {
    func settingsFrost() -> some View { settingsPopupChrome().background(SettingsFrost()).foregroundStyle(Color(nsColor: OrbitFloatingMaterial.body)) }
}

@MainActor
struct BrowserSettingsGradientPicker<Engine: BrowserEngine>: View {
    @ObservedObject var model: BrowserSettingsModel<Engine>
    let space: BrowserSpace
    @State private var isPresented = false

    func select(_ gradient: BrandPalette.SpaceGradient) {
        model.perform {
            var theme = gradient.theme(mode: space.theme?.mode ?? .automatic)
            theme.noise = space.theme?.noise ?? 0
            theme.frost = space.theme?.frost ?? false
            try await model.environment.store.setSpaceTheme(theme, for: space.id, profileID: space.profileID)
            model.environment.scheduleSave()
            await model.reload()
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(BrandPalette.spaceGradients.enumerated()), id: \.element.id) { index, gradient in
                Button { select(gradient) } label: {
                    Circle().fill(Color(nsColor: [BrandPalette.coral, BrandPalette.cobalt, BrandPalette.sun, BrandPalette.violet][index]))
                        .frame(width: 20, height: 20).padding(3)
                        .overlay(Circle().strokeBorder(space.theme?.presetID == "brand." + gradient.id ? Color(nsColor: BrandPalette.ink) : .clear, lineWidth: 2))
                }.buttonStyle(.plain).accessibilityLabel(uiText(gradient.name))
            }
            Button { model.presentThemeEditor?(space.id) } label: {
                Image(systemName: "slider.horizontal.3")
            }.buttonStyle(.plain).accessibilityLabel(uiText("Edit Theme Color…"))
        }
    }
}

struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 12)
            Toggle(isOn: configuration.$isOn) { EmptyView() }.labelsHidden().toggleStyle(SettingsSwitchControlStyle()).controlSize(.small)
        }.frame(maxWidth: .infinity)
    }
}

struct SettingsAppIcon: View {
    var body: some View {
        Group {
            if let image = OrbitAppIcon.defaultIcon.image { Image(nsImage: image).resizable().scaledToFit() }
        }.accessibilityLabel(uiText("App Icon"))
    }
}

/// Explicit ink is needed for destructive bordered buttons on macOS.
extension View {
    func settingsDestructive() -> some View {
        buttonStyle(.bordered)
            .tint(Color(nsColor: OrbitSettingsStyle.destructiveColor))
            .foregroundStyle(Color(nsColor: OrbitSettingsStyle.destructiveColor))
    }
}

struct SettingsDetailRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 12) {
            Text(title).fontWeight(.medium)
            Spacer(minLength: 8)
            content
        }.padding(.horizontal, 13).padding(.vertical, 9).frame(minHeight: 38)
    }
}

struct SettingsRule: View {
    var body: some View { Rectangle().fill(OrbitSettingsStyle.border).frame(height: 1) }
}

/// Compact app-icon choices share the same persistent selection as the icon sheet.
struct BrowserSettingsIconGrid: View {
    @ObservedObject var icons = OrbitAppIconController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(uiText("App Icon").uppercased()).font(Font(BrandFonts.mono(9.5))).tracking(1.14).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                ForEach(OrbitAppIcon.allCases) { icon in
                    Button { _ = icons.apply(icon) } label: {
                        VStack(spacing: 3) {
                            if let image = icon.preview {
                                Image(nsImage: image).resizable().scaledToFit().aspectRatio(1, contentMode: .fit)
                                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(
                                        icons.current == icon || (icons.current == .paper && icon == .stage)
                                        ? Color(nsColor: BrandPalette.ink) : .clear, lineWidth: 2))
                            }
                            Text(icon.name).font(Font(BrandFonts.ui(8.5, weight: .medium))).opacity(0.8)
                        }.padding(3)
                    }.buttonStyle(.plain).accessibilityIdentifier("settings-icon-" + icon.id)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(OrbitSettingsStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OrbitSettingsStyle.border, lineWidth: 1))
            Text(uiText("Choose how Circa looks in the Dock and the Finder.")).font(Font(BrandFonts.ui(10.5))).foregroundStyle(.secondary)
        }.padding(.top, 8)
    }
}

/// Coloured printed navigation marks share the pane's heading artwork.
struct SettingsPaneIcon: View {
    let section: BrowserSettingsSection
    var body: some View {
        if let url = BrowserText.secondaryBrandResource("settings-nav-" + section.rawValue, extension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit().accessibilityHidden(true)
        }
    }
}

struct OrbitPrintButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Font(BrandFonts.ui(12, weight: .semibold)))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(Color(nsColor: primary ? BrandPalette.pageWhite : BrandPalette.ink))
            .background(primary ? Color(nsColor: BrandPalette.coral) : Color(nsColor: BrandPalette.paper), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: BrandPalette.ink), lineWidth: 1.5))
            .compositingGroup()
            .shadow(color: Color(nsColor: BrandPalette.ink), radius: 0, x: 0, y: configuration.isPressed ? 0 : 2)
            .offset(y: configuration.isPressed ? 2 : 0)
    }
}

/// Painted track with native Toggle binding, focus, disabled state and accessibility semantics.
struct SettingsSwitchControlStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: configuration.isOn ? BrandPalette.cobalt : BrandPalette.ink.withAlphaComponent(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                    Color(nsColor: BrandPalette.ink.withAlphaComponent(configuration.isOn ? 1 : 0.13)), lineWidth: 1.5))
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(Color(nsColor: BrandPalette.paper)).frame(width: 15, height: 15).padding(2)
                }.frame(width: 32, height: 19)
        }.buttonStyle(.plain).opacity(isEnabled ? 1 : 0.45)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
            }
    }
}

struct SettingsGroupLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(Font(BrandFonts.mono(9.5))).tracking(1.14)
            .foregroundStyle(Color(nsColor: BrandPalette.cobalt.withAlphaComponent(0.6)))
            .padding(.horizontal, 2).padding(.top, 4)
    }
}

/// Menu-based pickers retain their native menu interaction with an ink-tinted pill label.
struct SettingsPopupStyle: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration).menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.plain)
            .font(Font(BrandFonts.ui(12, weight: .medium)))
            .foregroundStyle(OrbitSettingsStyle.foreground)
            .padding(.leading, 8).padding(.trailing, 23).padding(.vertical, 4)
            .background(OrbitSettingsStyle.foreground.opacity(0.063), in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(OrbitSettingsStyle.foreground).padding(.trailing, 8).allowsHitTesting(false)
            }
    }
}

/// A menu label can be painted independently while its Picker retains native tags and binding.
struct SettingsPopupPicker<Selection: Hashable, Options: View>: View {
    let title: String
    let selectedTitle: String
    @Binding var selection: Selection
    let options: Options
    init(_ title: String, selectedTitle: String, selection: Binding<Selection>, @ViewBuilder content: () -> Options) {
        self.title = title; self.selectedTitle = selectedTitle; self._selection = selection; self.options = content()
    }
    var body: some View {
        Menu {
            Picker(title, selection: $selection) { options }.labelsHidden().pickerStyle(.inline)
        } label: { Text(selectedTitle).lineLimit(1).foregroundStyle(OrbitSettingsStyle.foreground) }
        .menuStyle(SettingsPopupStyle()).tint(OrbitSettingsStyle.foreground).accessibilityLabel(title).accessibilityValue(selectedTitle)
    }
}

extension View {
    func settingsPopupChrome() -> some View { menuStyle(SettingsPopupStyle()) }
}

/// Labels use the same options and localized copy as the existing selectors.
enum SettingsPopupLabels {
    static func search(_ value: SearchEngine) -> String {
        switch value {
        case .google: uiText("Google")
        case .duckDuckGo: uiText("DuckDuckGo")
        case .bing: uiText("Bing")
        case .perplexity: uiText("Perplexity")
        }
    }
    static func memory(_ value: BrowserMemorySaverSetting) -> String {
        switch value {
        case .fiveMinutes: uiText("5 minutes")
        case .fifteenMinutes: uiText("15 minutes")
        case .thirtyMinutes: uiText("30 minutes")
        case .oneHour: uiText("1 hour")
        case .twoHours: uiText("2 hours")
        case .fourHours: uiText("4 hours")
        case .sixHours: uiText("6 hours")
        case .never: uiText("Never")
        }
    }
    static func motion(_ value: BrowserReducedMotionSetting) -> String {
        switch value {
        case .system: uiText("Follow System")
        case .reduce: uiText("Reduce Motion")
        case .full: uiText("Full Motion")
        }
    }
}
