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

/// The preview is deliberately a flat swatch, with no implied native glass implementation.
struct OrbitSecondaryAppearancePreview: View {
    let draft: BrowserSecondaryAppearanceDraft
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func sampleOpacity(_ draft: BrowserSecondaryAppearanceDraft, reduceTransparency: Bool) -> Double {
        reduceTransparency ? 1 : 1 - draft.transparency * 0.7
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                OrbitSecondaryMark().frame(width: 32, height: 32)
                Text(uiText("Settings preview")).font(.headline)
                Spacer()
            }
            RoundedRectangle(cornerRadius: 8)
                .fill(OrbitSecondaryIdentity.outremer.opacity(Self.sampleOpacity(draft, reduceTransparency: reduceTransparency)))
                .frame(height: 48)
                .accessibilityLabel(uiText("Transparency sample"))
            Text(uiText("Illustrative color sample only. No native glass effect is applied."))
                .font(.caption).foregroundStyle(.secondary)
            if reduceTransparency {
                Text(uiText("Reduce Transparency is enabled: the sample stays opaque.")).font(.caption)
            }
        }
        .padding(18)
        .background(OrbitSecondaryIdentity.ivory, in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(OrbitSecondaryIdentity.ink)
        // There is no animation, including when Reduce Motion is enabled.
        .transaction { if reduceMotion { $0.animation = nil } }
        .accessibilityIdentifier("settings-appearance-preview")
    }
}

struct OrbitSecondaryAbout: View {
    var body: some View {
        VStack(spacing: 18) {
            OrbitSecondaryMark().frame(width: 92, height: 92)
            OrbitSecondaryMark(wordmark: true).frame(height: 44)
            Text(uiText("A little clarity in your browsing.")).font(.system(size: 16, weight: .medium))
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
