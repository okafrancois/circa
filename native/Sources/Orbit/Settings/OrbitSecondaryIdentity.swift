import AppKit
import BrowserCore
import BrowserShell
import SwiftUI

/// Secondary-screen tokens only; never use these in the browser chrome or Space renderer.
enum OrbitSecondaryIdentity {
    static let ivory = Color(red: 243 / 255, green: 240 / 255, blue: 232 / 255)
    static let ink = Color(red: 32 / 255, green: 37 / 255, blue: 34 / 255)
    static let outremer = Color(red: 48 / 255, green: 75 / 255, blue: 206 / 255)
    static let clay = Color(red: 183 / 255, green: 111 / 255, blue: 85 / 255)

    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 32 / 255, green: 37 / 255, blue: 34 / 255, alpha: 1)
            : NSColor(srgbRed: 243 / 255, green: 240 / 255, blue: 232 / 255, alpha: 1)
    })
    static let foreground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 243 / 255, green: 240 / 255, blue: 232 / 255, alpha: 1)
            : NSColor(srgbRed: 32 / 255, green: 37 / 255, blue: 34 / 255, alpha: 1)
    })
    static let selection = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 243 / 255, green: 240 / 255, blue: 232 / 255, alpha: 1)
            : NSColor(srgbRed: 48 / 255, green: 75 / 255, blue: 206 / 255, alpha: 1)
    })

    /// Secondary controls only: ivory on ink in dark mode, outremer on ivory in light mode.
    /// Native controls retain their own glyph, focus-ring and disabled-state semantics.
    static let controlTint = selection
    static let categorySelectionBackground = outremer.opacity(0.09)

    @MainActor static func image(_ name: String) -> NSImage? {
        BrowserText.secondaryBrandResource(name, extension: "pdf").flatMap { NSImage(contentsOf: $0) }
    }
}

struct OrbitSecondaryMark: View {
    var wordmark = false
    var body: some View {
        if wordmark {
            Text(ProductIdentity.displayName).font(.system(size: 32, weight: .semibold, design: .rounded))
                .accessibilityLabel(ProductIdentity.displayName)
        } else if let image = OrbitSecondaryIdentity.image("sign-color") {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                .accessibilityLabel("Orbit")
        } else {
            Color.clear.accessibilityLabel("Orbit")
        }
    }
}

struct OrbitSecondaryAbout: View {
    var body: some View {
        VStack(spacing: 18) {
            OrbitSecondaryMark().frame(width: 92, height: 92)
            OrbitSecondaryMark(wordmark: true).frame(height: 44)
            Text(uiText("A little clarity in your browsing.")).font(Font(BrandFonts.ui(16, weight: .medium)))
            Text(version).font(.caption).foregroundStyle(.secondary)
            Rectangle().fill(OrbitSecondaryIdentity.clay).frame(width: 32, height: 2)
            Text(uiText("Built for macOS. Your profiles and browsing data stay on this Mac."))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
        .accessibilityIdentifier("settings-about-orbit")
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? uiText("Development build")
        let build = info["CFBundleVersion"] as? String
        return build.map { version + " (" + $0 + ")" } ?? version
    }
}
