import AppKit
import BrowserShell
import Combine

/// Complete ICNS files retain the independently drawn small and medium representations.
enum OrbitAppIcon: String, CaseIterable, Identifiable {
    case stage, paper, sunset, afterglow, frost, riso, ink
    static let defaultIcon = Self.stage
    var id: String { rawValue }
    var name: String {
        switch self {
        case .stage: uiText("Bow")
        case .paper: uiText("Paper")
        case .sunset: uiText("Sunset")
        case .afterglow: uiText("Afterglow")
        case .frost: uiText("Frost")
        case .riso: uiText("Riso")
        case .ink: uiText("Ink")
        }
    }
    var description: String {
        switch self {
        case .stage: uiText("The default: the sticker on the dark stage.")
        case .paper: uiText("The sticker on warm paper.")
        case .sunset: uiText("White bands on the Sunset gradient.")
        case .afterglow: uiText("Lit outlines over a night horizon.")
        case .frost: uiText("White bands on frosted glass.")
        case .riso: uiText("Two inks printed slightly off register.")
        case .ink: uiText("One colour, paper on ink.")
        }
    }
    var iconURL: URL? { BrowserText.appIconResource(rawValue, extension: "icns") }
    var previewURL: URL? { BrowserText.appIconResource(rawValue, extension: "png") }
    var image: NSImage? { iconURL.flatMap { NSImage(contentsOf: $0) } }
    var preview: NSImage? { previewURL.flatMap { NSImage(contentsOf: $0) } }
}

@MainActor
final class OrbitAppIconController: ObservableObject {
    static let preferenceKey = "orbit.applicationIcon"
    static let shared = OrbitAppIconController(defaults: .standard,
        setDockIcon: { NSApplication.shared.applicationIconImage = $0 },
        setBundleIcon: { image in
            // Never modify a test runner or an unrelated host application.
            guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "Orbit.icns",
                  Bundle.main.bundleURL.pathExtension == "app" else { return false }
            return NSWorkspace.shared.setIcon(image, forFile: Bundle.main.bundlePath, options: [])
        })

    @Published private(set) var current: OrbitAppIcon
    private(set) var finderIconApplied: Bool?
    private let defaults: UserDefaults
    private let setDockIcon: (NSImage) -> Void
    private let setBundleIcon: (NSImage?) -> Bool

    init(defaults: UserDefaults, setDockIcon: @escaping (NSImage) -> Void,
         setBundleIcon: @escaping (NSImage?) -> Bool) {
        self.defaults = defaults
        self.setDockIcon = setDockIcon
        self.setBundleIcon = setBundleIcon
        current = defaults.string(forKey: Self.preferenceKey).flatMap(OrbitAppIcon.init(rawValue:)) ?? .defaultIcon
    }

    /// Sparkle replaces the app directory. Reapply on every launch, even if the version is unchanged.
    static func reapplyForCurrentApplication() {
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "Orbit.icns" else { return }
        shared.reapplyAtLaunch()
    }

    @discardableResult
    func apply(_ icon: OrbitAppIcon) -> Bool {
        guard let image = icon.image else { return false }
        if icon == .defaultIcon { defaults.removeObject(forKey: Self.preferenceKey) }
        else { defaults.set(icon.rawValue, forKey: Self.preferenceKey) }
        setDockIcon(image)
        // A nil image removes Finder's custom icon; the shipped default then supplies every size.
        finderIconApplied = setBundleIcon(icon == .defaultIcon ? nil : image)
        current = icon
        return true
    }

    func restoreDefault() { apply(.defaultIcon) }
    func reapplyAtLaunch() { apply(current) }
}
