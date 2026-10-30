import Foundation

/// English is the development language, matching Orbit's English interface.
/// SwiftPM processes this target's Resources into OrbitLabNative_BrowserShell.bundle.
public enum BrowserText {
    private final class ResourceAnchor: NSObject {}
    // Locate both SwiftPM's adjacent bundle and an installed app's Resources bundle.
    // Older independent packagers may omit resources: retain English instead of crashing
    // in SwiftPM's generated Bundle.module accessor in that case.
    static let resourceBundle: Bundle? = {
        let name = "OrbitLabNative_BrowserShell.bundle"
        let roots = [Bundle(for: ResourceAnchor.self).resourceURL,
                     Bundle.main.resourceURL, Bundle.main.bundleURL,
                     Bundle.main.executableURL?.deletingLastPathComponent()]
        return roots.compactMap { $0 }.compactMap { Bundle(url: $0.appendingPathComponent(name)) }.first
    }()

    /// Resources shared by SwiftPM and the Chromium CMake product.
    public static func secondaryBrandResource(_ name: String, extension fileExtension: String) -> URL? {
        resourceBundle?.url(forResource: name, withExtension: fileExtension, subdirectory: "Orbit")
            ?? resourceBundle?.url(forResource: name, withExtension: fileExtension)
    }

    /// Interface icon resources retain their optical-size directories in every build system.
    public static func iconResource(_ name: String, extension fileExtension: String) -> URL? {
        resourceBundle?.url(forResource: name, withExtension: fileExtension, subdirectory: "Icons")
    }

    public static func appIconResource(_ name: String, extension fileExtension: String) -> URL? {
        resourceBundle?.url(forResource: name, withExtension: fileExtension, subdirectory: "AppIcons")
    }

    public static func string(_ english: String) -> String {
        guard let bundle = resourceBundle else { return english }
        return NSLocalizedString(english, bundle: bundle, value: english, comment: "Browser interface")
    }
}
