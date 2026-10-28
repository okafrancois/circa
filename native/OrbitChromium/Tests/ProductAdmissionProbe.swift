import Foundation

// Non-GUI admission probe. Compile with the unchanged product admission/configuration sources
// and CMake's generated StableSigning.swift, then sign only this executable with the existing
// development identity and the exact candidate channel identifier. No CEF, AppKit, data preparation or Keychain
// runtime is invoked. Only the supplied candidate's Info.plist is read.
func activeStableSigningRoot() -> String? { OrbitStableSigning.rootSHA1 }
func activeSyntheticDataGuard() -> SyntheticDataGuard? { nil }
func activeDefaultSessionFile() -> URL { URL(fileURLWithPath: "/private/tmp/orbit-admission-unused/session.json") }

@main
struct ProductAdmissionProbe {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Supply the candidate Info.plist") }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        let identifier = info["CFBundleIdentifier"] as! String
        precondition(OrbitBuildIdentity.productBundleIdentifiers.contains(identifier))
        let isLive = identifier == OrbitBuildIdentity.liveBundleIdentifier
        let signature = OrbitCodeSignature.current(stableRootSHA1: OrbitStableSigning.rootSHA1)
        let identity = OrbitBuildIdentity(bundleIdentifier: info["CFBundleIdentifier"] as? String, signature: signature)
        precondition(identity.productRefusal == nil, identity.productRefusal ?? "")
        // Configuration construction is pure: never call prepareDirectories or start a runtime.
        let support = URL(fileURLWithPath: "/private/tmp/orbit-admission-synthetic/Library/Application Support")
        let configuration = try OrbitProductConfiguration(arguments: ["Orbit"], infoDictionary: info,
                                                         applicationSupport: support, build: identity)
        precondition(!configuration.usesMockKeychain && configuration.usesProductNetwork)
        let service = isLive ? "Orbit Live Safe Storage" : OrbitProductConfiguration.keychainService
        let account = isLive ? "Orbit Live" : OrbitProductConfiguration.keychainAccount
        precondition(configuration.secureStorage == .keychain(service: service, account: account))
        let options = productRuntimeOptions(configuration)
        precondition(options.secureStorage == .keychain(service: service, account: account))
        precondition(options.rootCachePath == configuration.engineRoot.path)
        precondition(options.extraSwitches.isEmpty && !options.hiddenApplication && options.pageFirstKeyboard)
        precondition(options.networkPolicy == .product)
        let mock = OrbitProductConfiguration(dataRoot: URL(fileURLWithPath: "/private/tmp/orbit-admission-mock"),
                                            secureStorage: .mockKeychain)
        let mockOptions = productRuntimeOptions(mock, extraSwitches: ["synthetic"], hiddenApplication: true)
        precondition(mockOptions.secureStorage == .mockKeychain && mockOptions.networkPolicy == .hermetic)
        precondition(mockOptions.hiddenApplication && mockOptions.extraSwitches == ["synthetic"])
        precondition(configuration.dataRoot == support.appendingPathComponent(isLive ? "Orbit Live Chromium" : "Orbit", isDirectory: true))
        var wrongRoot = identity
        wrongRoot.signature = OrbitCodeSignature.current(stableRootSHA1: String(repeating: "A1", count: 20))
        precondition(wrongRoot.productRefusal != nil)
        var live = identity
        live.bundleIdentifier = isLive ? "io.github.okatech.orbit.test.orbit" : "io.github.okatech.orbit.test.orbit.live"
        precondition(live.productRefusal != nil)
        print("ProductAdmissionProbe: PASS (stable certificate, product configuration, wrong certificate/channel rejected; runtime options checked; no runtime)")
    }
}
