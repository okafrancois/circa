import Foundation

// Composition defaults are deliberately inert: this executable only exercises pre-runtime preparation.
func activeStableSigningRoot() -> String? { nil }
func activeSyntheticDataGuard() -> SyntheticDataGuard? { nil }
func activeDefaultSessionFile() -> URL { fatalError("An explicit synthetic default is required") }

let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let root = base.appendingPathComponent("root", isDirectory: true)
let support = base.appendingPathComponent("fake-home/Library/Application Support", isDirectory: true)
do {
    let product = CommandLine.arguments.dropFirst(2).contains("product")
    let identity = product ? OrbitBuildIdentity(bundleIdentifier: "io.github.okatech.orbit", signature:
        OrbitCodeSignature(identifier: "io.github.okatech.orbit", isAdHoc: false, isValid: true,
                          anchorCommonName: OrbitBuildIdentity.stableSigningCommonName,
                          satisfiesStableRequirement: true)) : OrbitBuildIdentity(bundleIdentifier: nil, signature: nil)
    let metadata: [String: Any] = product ? ["CFBundleIdentifier": "io.github.okatech.orbit"] : [
        "CFBundleIdentifier": "io.github.okatech.orbit.test.orbit.test.startup-confinement",
        "OrbitSyntheticBundle": true, "OrbitUseMockKeychain": true, "OrbitDataRoot": root.path
    ]
    let prepared = try OrbitProductLaunch.prepare(arguments: ["Orbit"], infoDictionary: metadata,
                                                applicationSupport: support, build: identity)
    if product {
        precondition(prepared.0.secureStorage == .keychain(service: "Orbit Safe Storage", account: "Orbit"))
        precondition(prepared.0.syntheticGuard == nil && prepared.0.usesProductNetwork)
    }
    prepared.1.release()
    print("preparation-accepted; runtime-not-linked")
} catch {
    // No paths or user content in the diagnostic. The supervisor retains streams before assertions.
    print("preparation-refused: \(String(describing: type(of: error)))")
    exit(64)
}
