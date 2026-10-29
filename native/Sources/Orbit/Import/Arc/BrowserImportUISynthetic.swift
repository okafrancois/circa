import AppKit
import BrowserCore
import CryptoKit
import Darwin
import Foundation
import Security

/// Explicitly signed fixture bundle only. A mock run never falls through to real discovery or
/// system Keychain queries. Inventory is confined to its baked data root.
enum BrowserImportUISynthetic {
    struct Inventory: Codable { var browsers: [String]; var keyStatus: String? }
    @MainActor static func applyAppearance() {
        guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.import-ui", activeSiteSessionConfiguration()?.usesMockKeychain == true else { return }
        _ = (NSClassFromString("ACRApplication") as? NSApplication.Type)?.shared
        NSApplication.shared.appearance = NSAppearance(named: CommandLine.arguments.contains("--import-ui-dark") ? .darkAqua : .aqua)
    }
    static func sourceRoot(_ configuration: OrbitProductConfiguration) -> URL {
        configuration.dataRoot.deletingLastPathComponent().appendingPathComponent("Sources")
    }
    static func checkSource(_ file: URL, configuration: OrbitProductConfiguration) throws {
        guard configuration.usesMockKeychain, Bundle.main.bundleIdentifier == "lab.orbit.orbit.import-ui" else {
            throw BrowserAuthenticationImportError.invalidState
        }
        let guardRoot = SyntheticDataGuard(syntheticRoot: sourceRoot(configuration), personalLocations: configuration.personalLocations)
        try guardRoot.checkRoot()
        try guardRoot.checkSessionFile(file)
    }
    static func checkDirectory(_ folder: URL, configuration: OrbitProductConfiguration) throws {
        let confinement = SyntheticDataGuard(syntheticRoot: sourceRoot(configuration), personalLocations: configuration.personalLocations)
        try confinement.checkInside(folder)
        try SyntheticDataGuard(syntheticRoot: folder, personalLocations: configuration.personalLocations).checkRoot()
    }
    static func choices(_ configuration: OrbitProductConfiguration) throws -> [BrowserImportChoice] {
        guard let confinement = configuration.syntheticGuard else { return [] }
        try confinement.checkRoot()
        guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.import-ui" else { return [] }
        let file = configuration.dataRoot.appendingPathComponent("import-ui-inventory.json")
        try confinement.checkInside(file)
        let inventory = try JSONDecoder().decode(Inventory.self, from: Data(contentsOf: file))
        let safari = SafariBrowserImportAdapter(installationID: UUID(), profile: .init(directory: "Default", name: ""),
            placement: .init(importedSpace: "", bookmarkFolder: "", windowName: ""), includeSharedData: true).descriptor
        let descriptors = (ChromiumImportRegistry.descriptors + FirefoxImportRegistry.descriptors + [safari]).filter { inventory.browsers.contains($0.id) }
        return BrowserImportInventory.choices(descriptors: descriptors, support: sourceRoot(configuration))
    }
    static func sourcePassword(_ configuration: OrbitProductConfiguration) throws -> Data {
        guard configuration.usesMockKeychain, Bundle.main.bundleIdentifier == "lab.orbit.orbit.import-ui",
              let confinement = configuration.syntheticGuard else { throw BrowserAuthenticationImportError.invalidState }
        try confinement.checkRoot()
        let inventory = try JSONDecoder().decode(Inventory.self, from: Data(contentsOf: configuration.dataRoot.appendingPathComponent("import-ui-inventory.json")))
        struct Boundary: OrbitRecoverySecItemBoundary {
            let configuration: OrbitProductConfiguration
            let status: String?
            func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
                guard !Thread.isMainThread else { return (errSecParam, nil) }
                // Record only the worker/prompt decision, never query values or secrets.
                try? Data("worker-source-query".utf8).write(to: configuration.dataRoot.appendingPathComponent("import-ui-keychain-probe"))
                switch status {
                case "denied": return (errSecUserCanceled, nil)
                case "missing": return (errSecItemNotFound, nil)
                case "failed": return (errSecParam, nil)
                default:
                    return (errSecSuccess, try? Data(contentsOf: configuration.dataRoot.appendingPathComponent("arc-session-source-password")))
                }
            }
            func add(_ attributes: [String: Any]) -> (OSStatus, Any?) { (errSecParam, nil) }
        }
        return try ChromiumImportKeychain(boundary: Boundary(configuration: configuration, status: inventory.keyStatus))
            .readSource(sourceID: "chrome", userConsented: true)
    }

    static func recordFailure(_ error: any Error, configuration: OrbitProductConfiguration) {
        guard configuration.usesMockKeychain, Bundle.main.bundleIdentifier == "lab.orbit.orbit.import-ui" else { return }
        let description: String
        if let value = error as? ArcImportError { description = String(describing: value) }
        else if let value = error as? BrowserAuthenticationImportError { description = String(describing: value) }
        else if let value = error as? OrbitRecoveryFailure { description = String(describing: value) }
        else { description = "unclassified" }
        try? Data(description.utf8).write(to: configuration.dataRoot.appendingPathComponent("import-ui-failure"))
    }
    static func checkpoint(_ point: String, configuration: OrbitProductConfiguration) throws {
        guard configuration.usesMockKeychain, Bundle.main.bundleIdentifier == "lab.orbit.orbit.import-ui",
              let confinement = configuration.syntheticGuard else { return }
        try confinement.checkRoot()
        if ProcessInfo.processInfo.environment["ORBIT_IMPORT_UI_PAUSE"] == point { Thread.sleep(forTimeInterval: 3) }
        if ProcessInfo.processInfo.environment["ORBIT_IMPORT_UI_KILL"] == point { kill(getpid(), SIGKILL) }
    }
}
