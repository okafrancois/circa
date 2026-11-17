import AppKit
import BrowserShell
import Combine

/// Complete ICNS files retain the independently drawn small and medium representations.
enum OrbitAppIcon: String, CaseIterable, Identifiable {
    case stage, paper, sunset, afterglow, frost, riso, ink
    static let defaultIcon = Self.stage
    var id: String { rawValue }
    // Keep persisted identifiers compatible with earlier icon selections.
    static let allCases: [Self] = [.stage, .frost, .sunset, .riso, .afterglow, .ink]
    var name: String {
        switch self {
        case .stage, .paper: uiText("Day")
        case .frost: uiText("Cobalt")
        case .sunset: uiText("Mandarine")
        case .riso: uiText("Soleil")
        case .afterglow: uiText("Aurore")
        case .ink: uiText("Night")
        }
    }
    var description: String { name }
    var iconURL: URL? { BrowserText.appIconResource(rawValue, extension: "icns") }
    var previewURL: URL? { BrowserText.appIconResource(rawValue, extension: "png") }
    var image: NSImage? { iconURL.flatMap { NSImage(contentsOf: $0) } }
    var preview: NSImage? { previewURL.flatMap { NSImage(contentsOf: $0) } }
}

@MainActor
final class OrbitAppIconController: ObservableObject {
    /// Read by the Dock tile plug-in (native/OrbitChromium/DockTile) from the preferences of the
    /// application that contains it, so keep the key and the notification name in step with it.
    static let preferenceKey = "orbit.applicationIcon"
    static let changeNotificationSuffix = ".applicationIconChanged"

    /// Scoped to the bundle identifier: test bundles never notify the product's plug-in.
    static func changeNotificationName(applicationIdentifier: String) -> Notification.Name {
        Notification.Name(applicationIdentifier + changeNotificationSuffix)
    }

    private static var isOrbitApplication: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "Orbit.icns"
            && Bundle.main.bundleURL.pathExtension == "app"
    }

    static let shared = OrbitAppIconController(defaults: .standard,
        setDockIcon: { NSApplication.shared.applicationIconImage = $0 },
        notifyDockTile: {
            // The Dock tile plug-in draws the chosen icon while the app is not running.
            guard isOrbitApplication, let identifier = Bundle.main.bundleIdentifier else { return }
            UserDefaults.standard.synchronize()
            DistributedNotificationCenter.default().postNotificationName(
                changeNotificationName(applicationIdentifier: identifier), object: nil, userInfo: nil,
                deliverImmediately: true)
        },
        setBundleIcon: { image in
            // Never modify a test runner or an unrelated host application.
            guard isOrbitApplication else { return false }
            // The signed bundle is never written: a custom Finder icon adds a file inside it and
            // breaks code signature verification. The choice applies to the Dock: the app sets it
            // while running and the Dock tile plug-in draws it while the app is not running.
            // A custom icon left by an earlier version is removed once, which restores the seal.
            if FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Icon\r").path) {
                _ = NSWorkspace.shared.setIcon(nil, forFile: Bundle.main.bundlePath, options: [])
            }
            return image == nil
        })

    @Published private(set) var current: OrbitAppIcon
    private(set) var finderIconApplied: Bool?
    private let defaults: UserDefaults
    private let setDockIcon: (NSImage) -> Void
    private let setBundleIcon: (NSImage?) -> Bool
    private let notifyDockTile: () -> Void

    init(defaults: UserDefaults, setDockIcon: @escaping (NSImage) -> Void,
         notifyDockTile: @escaping () -> Void = {}, setBundleIcon: @escaping (NSImage?) -> Bool) {
        self.defaults = defaults
        self.setDockIcon = setDockIcon
        self.notifyDockTile = notifyDockTile
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
        notifyDockTile()
        // A nil image removes Finder's custom icon; the shipped default then supplies every size.
        finderIconApplied = setBundleIcon(icon == .defaultIcon ? nil : image)
        current = icon
        return true
    }

    func restoreDefault() { apply(.defaultIcon) }
    func reapplyAtLaunch() { apply(current) }
}
