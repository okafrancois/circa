import AppKit
import BrowserCore

enum OrbitGlassRole: Sendable {
    case opaque
    case windowShell
    case floatingSidebar
}

struct OrbitGlassStyle: Equatable {
    let usesMaterial: Bool
    var requestsLiquidGlass = false
    var readabilityOpacity: Float = 0
    let tintOpacity: Float
    let emphasizesBoundary: Bool

    static func resolve(role: OrbitGlassRole, isDark: Bool, isActive: Bool,
                        reduceTransparency: Bool, increaseContrast: Bool,
                        surface: BrowserThemeSurface? = nil) -> Self {
        if let surface, !surface.isValid {
            return Self(usesMaterial: false, tintOpacity: 1, emphasizesBoundary: increaseContrast)
        }
        // Unedited Spaces use the same material shown by the editor, without writing a migration.
        // A second 65–80% neutral wash used to mask almost all of the desktop contribution.
        // AppKit already adapts the frosted backdrop; retain only a light appearance wash here.
        let surface = surface ?? BrowserThemeSurface()
        let glass = role != .opaque && !reduceTransparency && !increaseContrast
            && surface.material != .solid && surface.transparency > 0
        return Self(usesMaterial: glass, requestsLiquidGlass: glass && surface.material == .liquidGlass,
                    readabilityOpacity: glass ? (isDark ? 0.18 : 0.12) : 0,
                    tintOpacity: glass ? Float(1 - 0.88 * surface.transparency) : 1,
                    emphasizesBoundary: increaseContrast)
    }
}

/// Decorative only: controls remain ordinary, non-vibrant AppKit views above this surface.
@MainActor
final class OrbitGlassMaterialView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        isEmphasized = false
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Notification tokens retain their owning center (workspace notifications use a different one).
final class OrbitGlassObservers: @unchecked Sendable {
    var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    deinit { for (center, token) in tokens { center.removeObserver(token) } }
}

/// Public AppKit API, declared in NSGlassEffectView.h (macOS 26). No runtime lookup or private KVC.
/// Decorative glass has no interactive response; ordinary controls stay outside its content view.
@available(macOS 26.0, *)
@MainActor
final class OrbitLiquidGlassView: NSGlassEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        style = .clear
        cornerRadius = 0
        if #available(macOS 27.0, *) { effectIsInteractive = false }
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
enum OrbitThemeSurfaceText {
    static func material(_ value: BrowserThemeSurface.Material) -> String {
        switch value {
        case .solid: uiText("Solid")
        case .frosted: uiText("Frosted")
        case .liquidGlass: uiText("Liquid Glass")
        }
    }
    static var capability: String {
        if #available(macOS 26.0, *) {
            return uiText("Native Liquid Glass (macOS 26+). Accessibility may make the frame opaque.")
        }
        return uiText("Native frosted fallback on this macOS. Liquid Glass requires macOS 26.")
    }
}
