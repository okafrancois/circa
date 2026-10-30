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
    let section: BrowserSettingsSection
    init(section: BrowserSettingsSection) {
        self.section = section
        super.init(frame: NSRect(x: 0, y: 0, width: max(66, BrandFonts.ui(11).width(of: section.title) + 16), height: 46))
        isBordered = false
        title = section.toolbarTitle
        setAccessibilityLabel(section.title)
        setAccessibilityIdentifier(section.toolbarIdentifier.rawValue)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: max(66, BrandFonts.ui(11).width(of: section.toolbarTitle) + 16), height: 46) }
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
        window?.isOpaque = false
        window?.backgroundColor = .clear
    }
}

private struct SettingsFrost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = SettingsFrostHost()
        OrbitFloatingMaterial.install(in: view, blending: .behindWindow, radius: 14)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        view.window?.isOpaque = false
        view.window?.backgroundColor = .clear
    }
}

extension View {
    func settingsFrost() -> some View { background(SettingsFrost()).foregroundStyle(Color(nsColor: OrbitFloatingMaterial.body)) }
}

@MainActor
struct BrowserSettingsGradientPicker<Engine: BrowserEngine>: View {
    @ObservedObject var model: BrowserSettingsModel<Engine>
    let space: BrowserSpace
    @State private var isPresented = false
    var body: some View {
        Button(settingsText("editThemeColor", "Edit Theme Color…")) { isPresented.toggle() }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                HStack(spacing: 8) {
                    ForEach(BrandPalette.spaceGradients, id: \.id) { gradient in
                        Button {
                            model.perform {
                                try await model.environment.store.setSpaceTheme(gradient.theme(mode: space.theme?.mode ?? .automatic), for: space.id, profileID: space.profileID)
                                model.environment.scheduleSave()
                                await model.reload()
                            }
                        } label: {
                            Circle().fill(LinearGradient(stops: zip(gradient.stops, gradient.locations).map {
                                .init(color: Color(nsColor: OrbitSpaceThemes.color($0.0)), location: $0.1)
                            }, startPoint: .top, endPoint: .bottomTrailing))
                            .frame(width: 30, height: 30)
                            .padding(3)
                            .overlay(Circle().strokeBorder(space.theme?.presetID == "brand." + gradient.id ? Color.accentColor : .clear, lineWidth: 2))
                        }.buttonStyle(.plain).accessibilityLabel(uiText(gradient.name))
                    }
                }.padding(12).settingsFrost()
            }
    }
}

struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 12)
            Toggle(isOn: configuration.$isOn) { EmptyView() }.labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.frame(maxWidth: .infinity)
    }
}

struct SettingsAppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26).fill(Color(nsColor: BrandPalette.stage))
            RadialGradient(colors: [Color(nsColor: BrandPalette.coral).opacity(0.4), Color(nsColor: BrandPalette.violet).opacity(0.25), .clear], center: .bottom, startRadius: 0, endRadius: 90)
            if let mark = BrandFonts.mark { Image(nsImage: mark).resizable().scaledToFit().padding(22) }
        }.clipShape(RoundedRectangle(cornerRadius: 26)).accessibilityLabel(uiText("App Icon"))
    }
}
