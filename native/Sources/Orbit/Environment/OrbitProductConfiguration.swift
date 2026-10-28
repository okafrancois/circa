import BrowserCore
import Foundation

/// Where an Orbit product build keeps its local data and which secure storage its engine uses
/// (CHROMIUM-APP). Engine-independent; the Chromium composition root reads it before starting
/// the runtime.
/// - Product (no option): data root `~/Library/Application Support/Orbit/`, the real Keychain item
///   `Orbit Safe Storage` / `Orbit`. Live uses `Orbit Live Chromium/` and its separate real item
///   `Orbit Live Safe Storage` / `Orbit Live`; it cannot redirect its data root or session.
/// - Automated runs: `--use-mock-keychain` together with an explicit synthetic
///   `--orbit-data-root=<absolute path>` outside the personal data root. A run is never both: the
///   mock never names the real item, and the real item is never used with the mock switch.
/// Layout below the data root: `session.json` (Orbit's session graph) and `Chromium/` (CEF
/// `root_cache_path`; one `profile-<uuid>` directory per Orbit profile, each a direct child).
/// A bundle launched by LaunchServices gets no arguments: the same two settings can come from
/// its Info.plist (`OrbitDataRoot`, `OrbitUseMockKeychain`, for packaged synthetic test bundles
/// only), under the same rules. Packaged test defaults allow an explicit synthetic run root;
/// legacy plist settings and arguments for the same option refuse.
/// Product mode is reserved to the packaged daily and Live product identities with a valid signature anchored
/// on the stable local identity (`OrbitBuildIdentity.productRefusal`): a bare executable, an ad hoc
/// or unsigned copy, the inert `io.github.okatech.orbit.test.orbit.unpackaged` or a test bundle refuses to start in
/// product mode, before anything is created. Synthetic runs do not depend on the bundle.
/// A synthetic run never reaches personal data through a derived path either (CHROMIUM-APP-R2):
/// `syntheticGuard` refuses roots inside `~/Library` in any spelling, and `prepareDirectories`
/// refuses a `Chromium/`, cache or session entry that is a link or lies outside the root.
struct OrbitProductConfiguration: Equatable {
    enum SecureStorage: Equatable {
        case keychain(service: String, account: String)
        case mockKeychain
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case unpackagedBundle
        case testBundleNeedsIsolation
        case productBundleHasSyntheticSettings
        case dataRootNotAbsolute
        case repeatedOption(String)
        case mockKeychainNeedsSyntheticRoot
        case mockKeychainOnPersonalRoot
        case retiredOption(String)
        case productBuildRefused(String)

        var description: String {
            switch self {
            case .unpackagedBundle: "Unpackaged build cannot start; package Orbit first"
            case .testBundleNeedsIsolation: "Test bundle requires a baked synthetic root and mock Keychain"
            case .productBundleHasSyntheticSettings: "Product bundle refuses synthetic Info.plist settings"
            case .dataRootNotAbsolute: "--orbit-data-root needs an absolute path"
            case .repeatedOption(let name): "\(name) is given more than once"
            case .mockKeychainNeedsSyntheticRoot: "--use-mock-keychain requires an explicit synthetic --orbit-data-root"
            case .mockKeychainOnPersonalRoot: "--use-mock-keychain refuses the personal Orbit data root and ~/Library"
            case .retiredOption(let name): "\(name) is retired; use --orbit-data-root (the engine root is its Chromium/ child)"
            case .productBuildRefused(let reason): "this build cannot run as the Orbit product (\(reason)); synthetic runs need --use-mock-keychain and --orbit-data-root"
            }
        }
    }

    static let keychainService = ProductIdentity.keychainService
    static let keychainAccount = ProductIdentity.keychainAccount
    static let dataRootOption = "--orbit-data-root="
    static let mockKeychainOption = "--use-mock-keychain"

    let dataRoot: URL
    let secureStorage: SecureStorage
    /// Locations a synthetic run must never touch: `~/Library` and the personal data root.
    let personalLocations: [URL]

    var sessionFile: URL { dataRoot.appendingPathComponent("session.json") }
    /// CEF `root_cache_path`.
    var engineRoot: URL { dataRoot.appendingPathComponent("Chromium", isDirectory: true) }
    var usesMockKeychain: Bool { secureStorage == .mockKeychain }
    /// Chromium's product network services (component updater, extension updates) for the signed
    /// daily build only; every synthetic run stays hermetic (CHROMIUM-APP-R2, PM decision).
    var usesProductNetwork: Bool { !usesMockKeychain }

    static func personalDataRoot(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(ProductIdentity.dataDirectoryName, isDirectory: true)
    }

    static func personalLocations(applicationSupport: URL) -> [URL] {
        [applicationSupport.deletingLastPathComponent(), personalDataRoot(applicationSupport: applicationSupport)]
    }

    init(dataRoot: URL, secureStorage: SecureStorage, personalLocations: [URL] = []) {
        let normalized = dataRoot.standardizedFileURL
        // Foundation shortens /private/tmp and /private/var to their system aliases. The
        // session store and Chromium anchor require a physical path without symbolic links.
        // Expand only these exact macOS aliases; user-created links still reach admission.
        let alias = normalized.pathComponents.dropFirst().first
        if let alias, ["tmp", "var"].contains(alias),
           let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/" + alias),
           ["private/" + alias, "/private/" + alias].contains(target) {
            self.dataRoot = URL(fileURLWithPath: "/private" + normalized.path, isDirectory: true)
        } else { self.dataRoot = normalized }
        self.secureStorage = secureStorage
        self.personalLocations = personalLocations.map(\.standardizedFileURL)
    }

    /// Confinement of a synthetic (mock Keychain) run; nil for the product.
    var syntheticGuard: SyntheticDataGuard? {
        usesMockKeychain ? SyntheticDataGuard(syntheticRoot: dataRoot, personalLocations: personalLocations) : nil
    }

    static let dataRootInfoKey = "OrbitDataRoot"
    static let mockKeychainInfoKey = "OrbitUseMockKeychain"

    /// Arguments first, then the bundle's Info.plist settings expressed as the same options.
    init(arguments: [String], infoDictionary: [String: Any], applicationSupport: URL, build: OrbitBuildIdentity) throws {
        let identifier = infoDictionary["CFBundleIdentifier"] as? String
        guard identifier != "io.github.okatech.orbit.test.orbit.unpackaged" else { throw Failure.unpackagedBundle }
        let isProduct = identifier.map { OrbitBuildIdentity.productBundleIdentifiers.contains($0) } ?? false
        let testBundle = identifier != nil && !isProduct
        if testBundle {
            guard let root = infoDictionary[Self.dataRootInfoKey] as? String, root.hasPrefix("/"),
                  infoDictionary[Self.mockKeychainInfoKey] as? Bool == true else {
                throw Failure.testBundleNeedsIsolation
            }
            guard !Self.isInside(URL(fileURLWithPath: root), Self.personalDataRoot(applicationSupport: applicationSupport)) else {
                throw Failure.mockKeychainOnPersonalRoot
            }
        } else if isProduct &&
                    (infoDictionary[Self.dataRootInfoKey] != nil || infoDictionary[Self.mockKeychainInfoKey] != nil || infoDictionary["OrbitSyntheticBundle"] != nil) {
            throw Failure.productBundleHasSyntheticSettings
        }
        // Baked test defaults remain safe when a lab runner supplies its own synthetic run root.
        // The normal parser below still rejects personal roots and repeated command-line options.
        let bakedTest = testBundle && infoDictionary["OrbitSyntheticBundle"] as? Bool == true
        var effective = arguments
        if let root = infoDictionary[Self.dataRootInfoKey] as? String,
           !(bakedTest && arguments.contains(where: { $0.hasPrefix(Self.dataRootOption) })) {
            effective.append(Self.dataRootOption + root)
        }
        if infoDictionary[Self.mockKeychainInfoKey] as? Bool == true,
           !(bakedTest && arguments.contains(where: { $0 == Self.mockKeychainOption || $0.hasPrefix(Self.mockKeychainOption + "=") })) {
            effective.append(Self.mockKeychainOption)
        }
        try self.init(arguments: effective, applicationSupport: applicationSupport, build: build)
    }

    init(arguments: [String], applicationSupport: URL, build: OrbitBuildIdentity) throws {
        if let retired = arguments.first(where: { $0.hasPrefix("--orbit-chromium-root=") }) {
            throw Failure.retiredOption(String(retired.prefix { $0 != "=" }))
        }
        let roots = arguments.filter { $0.hasPrefix(Self.dataRootOption) }.map { String($0.dropFirst(Self.dataRootOption.count)) }
        guard roots.count <= 1 else { throw Failure.repeatedOption("--orbit-data-root") }
        let mock = arguments.filter { $0 == Self.mockKeychainOption || $0.hasPrefix(Self.mockKeychainOption + "=") }
        guard mock.count <= 1 else { throw Failure.repeatedOption(Self.mockKeychainOption) }
        let personal = Self.personalDataRoot(applicationSupport: applicationSupport)
        let locations = Self.personalLocations(applicationSupport: applicationSupport)
        let isLive = build.bundleIdentifier == OrbitBuildIdentity.liveBundleIdentifier
        let liveRoot = applicationSupport.appendingPathComponent("Orbit Live Chromium", isDirectory: true)
        var root = isLive ? liveRoot : personal
        if let path = roots.first {
            guard path.hasPrefix("/") else { throw Failure.dataRootNotAbsolute }
            root = URL(fileURLWithPath: path, isDirectory: true)
        }
        if mock.isEmpty {
            if let refusal = build.productRefusal { throw Failure.productBuildRefused(refusal) }
            if isLive {
                // A Live product cannot be redirected into daily Orbit or the retired WebKit session.
                guard roots.isEmpty, !arguments.contains(where: { $0 == "--session-file" || $0.hasPrefix("--session-file=") }) else {
                    throw Failure.productBuildRefused("Live product uses its own fixed data root and session")
                }
                let resolved = liveRoot.standardizedFileURL.resolvingSymlinksInPath()
                guard resolved == liveRoot.standardizedFileURL else {
                    throw Failure.productBuildRefused("Live product data root contains a symbolic link")
                }
            }
            self.init(dataRoot: root, secureStorage: .keychain(service: isLive ? "Orbit Live Safe Storage" : Self.keychainService,
                                                            account: isLive ? "Orbit Live" : Self.keychainAccount),
                      personalLocations: locations)
            return
        }
        guard !roots.isEmpty else { throw Failure.mockKeychainNeedsSyntheticRoot }
        guard !Self.isInside(root, personal),
              (try? SyntheticDataGuard(syntheticRoot: root, personalLocations: locations).checkRoot()) != nil else {
            throw Failure.mockKeychainOnPersonalRoot
        }
        self.init(dataRoot: root, secureStorage: .mockKeychain, personalLocations: locations)
    }

    /// Case-insensitively and through symlinks (APFS default volumes are case-insensitive).
    static func isInside(_ candidate: URL, _ root: URL) -> Bool {
        func components(_ url: URL) -> [String] {
            url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
        }
        let child = components(candidate), parent = components(root)
        return child.count >= parent.count && Array(child.prefix(parent.count)) == parent
    }

    /// Creates the data and engine roots, private to the user (0700). An existing `Chromium/` or
    /// `session.json` that is a symlink is refused in every mode (CEF and the session store would
    /// follow it). A synthetic run also validates its whole layout before and after creating it:
    /// every derived path inside the root, outside personal locations, no link anywhere below it.
    func prepareDirectories() throws {
        let manager = FileManager.default
        let syntheticGuard = syntheticGuard
        try syntheticGuard?.checkLayout(engineRoot: engineRoot, sessionFile: sessionFile)
        for entry in [engineRoot, sessionFile] {
            var info = stat()
            if lstat(entry.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                throw SyntheticDataGuard.Violation.symbolicLink(entry.path)
            }
        }
        for directory in [dataRoot, engineRoot] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        try syntheticGuard?.checkLayout(engineRoot: engineRoot, sessionFile: sessionFile)
    }
}
