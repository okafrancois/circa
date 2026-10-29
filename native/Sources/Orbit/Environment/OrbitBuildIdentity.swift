import BrowserCore
import Darwin
import Foundation
import Security

/// The code signature of the running process, as the product admission reads it (CHROMIUM-APP-R2).
struct OrbitCodeSignature: Equatable {
    /// Signing identifier (`codesign -d`: Identifier).
    var identifier: String?
    /// Ad hoc or linker-signed: no certificate chain.
    var isAdHoc: Bool
    /// The running code satisfies its signature (`SecCodeCheckValidity`).
    var isValid: Bool
    /// Common name of the anchor (root) certificate of the signing chain (diagnostics).
    var anchorCommonName: String?
    /// The running code satisfies the explicit requirement of the stable local identity:
    /// `identifier "<ProductIdentity.bundleIdentifier>" and certificate root = H"<SHA-1>"`
    /// (CHROMIUM-APP-R3, review MEDIUM 4). Another certificate, even with the same name, fails.
    var satisfiesStableRequirement = false
    /// Apple-issued Developer ID Application signature for future notarized distributions.
    var satisfiesDeveloperIDRequirement = false

    /// The explicit requirement for a certificate SHA-1 (40 hexadecimal digits), nil otherwise.
    static func stableRequirement(rootSHA1: String?, identifier: String = OrbitBuildIdentity.productBundleIdentifier) -> String? {
        guard OrbitBuildIdentity.productBundleIdentifiers.contains(identifier),
              let rootSHA1, rootSHA1.count == 40, rootSHA1.allSatisfy(\.isHexDigit) else { return nil }
        return "identifier \"\(identifier)\" and certificate root = H\"\(rootSHA1.uppercased())\""
    }

    /// `SecCodeCheckValidity` of `code` against a requirement in the code-signing language.
    static func satisfies(_ code: SecCode, requirement text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// Dynamic signature of this process; nil when it cannot be read. `stableRootSHA1` is the
    /// certificate fingerprint built into the product (none: the requirement is not satisfied).
    static func current(stableRootSHA1: String? = nil, developerTeamID: String? = activeDeveloperSigningTeam()) -> OrbitCodeSignature? {
        BrowserPerformance.mark(.signatureBegin)
        defer { BrowserPerformance.mark(.signatureReady) }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        let valid = SecCodeCheckValidity(code, [], nil) == errSecSuccess
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }
        let identifier = info[kSecCodeInfoIdentifier as String] as? String
        let stable = identifier.flatMap { stableRequirement(rootSHA1: stableRootSHA1, identifier: $0) }
            .map { satisfies(code, requirement: $0) } ?? false
        var developerID = false
        if let identifier, let team = developerTeamID, team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            developerID = satisfies(code, requirement: "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\"")
        }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        var name: CFString?
        if let anchor = certificates.last { SecCertificateCopyCommonName(anchor, &name) }
        return OrbitCodeSignature(identifier: info[kSecCodeInfoIdentifier as String] as? String,
                                 isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0 || certificates.isEmpty,
                                 isValid: valid, anchorCommonName: name as String?, satisfiesStableRequirement: stable, satisfiesDeveloperIDRequirement: developerID)
    }
}

/// What the running build is: its bundle and its signature. Only the packaged, stably signed
/// Orbit and the retained legacy Live bundle may run in product mode, each with its own
/// data root and real Keychain item.
struct OrbitBuildIdentity: Equatable {
    var bundleIdentifier: String?
    var signature: OrbitCodeSignature?

    /// `stableRootSHA1`: the stable certificate's fingerprint built into this product (the
    /// composition's `activeStableSigningRoot()`), nil for builds that are never the product.
    static func current(stableRootSHA1: String? = activeStableSigningRoot()) -> OrbitBuildIdentity {
        OrbitBuildIdentity(bundleIdentifier: Bundle.main.bundleIdentifier,
                          signature: OrbitCodeSignature.current(stableRootSHA1: stableRootSHA1))
    }

    static let productBundleIdentifier = ProductIdentity.bundleIdentifier
    static let liveBundleIdentifier = "io.github.okatech.orbit.test.orbit.live"
    static let productBundleIdentifiers = [productBundleIdentifier, liveBundleIdentifier]
    /// Subject of the stable local signing identity (`scripts/local_signing.py`); its designated
    /// requirement is anchored on this certificate (`certificate root = H"…"`), never on a cdhash.
    static let stableSigningCommonName = "Orbit Lab Local Development"

    /// Nil when the build may run as the product, otherwise why it may not.
    var productRefusal: String? {
        guard let bundleIdentifier, Self.productBundleIdentifiers.contains(bundleIdentifier) else {
            return "bundle identifier \(bundleIdentifier ?? "none") is not \(Self.productBundleIdentifier)"
        }
        guard let signature else { return "no readable code signature" }
        guard signature.isValid else { return "invalid code signature" }
        guard !signature.isAdHoc else { return "ad hoc code signature" }
        guard signature.identifier == bundleIdentifier else {
            return "signing identifier \(signature.identifier ?? "none") is not \(bundleIdentifier)"
        }
        if signature.satisfiesDeveloperIDRequirement { return nil }
        guard signature.satisfiesStableRequirement else {
            return "signature does not satisfy the stable local identity requirement"
        }
        guard signature.anchorCommonName == Self.stableSigningCommonName else {
            return "signature is not anchored on the stable local identity"
        }
        return nil
    }
}

/// Exclusive ownership of a data root by one running Orbit (CHROMIUM-APP-R2): an installed build
/// and a stray copy can never share a session or a Chromium root. `flock` on a lock file inside
/// the root, held for the life of the process and released by the kernel even after SIGKILL.
final class OrbitDataRootLock {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case unavailable(String)
        case alreadyInUse(String)

        var description: String {
            switch self {
            case .unavailable(let path): "cannot open the data root lock \(path)"
            case .alreadyInUse(let path): "another Orbit instance already uses the data root of \(path)"
            }
        }
    }

    static let fileName = ".orbit-instance.lock"
    private(set) var recoveryLease: OrbitRecoveryRootLock?

    init(dataRoot: URL) throws {
        do { recoveryLease = try OrbitRecoveryRootLock(root: dataRoot) }
        catch OrbitRecoveryFailure.busy { throw Failure.alreadyInUse(dataRoot.appendingPathComponent(Self.fileName).path) }
        catch { throw Failure.unavailable(dataRoot.appendingPathComponent(Self.fileName).path) }
    }

    func release() { recoveryLease = nil }

    deinit { release() }
}

/// Start-up of the Chromium product before CEF and AppKit exist, in refusal order: the
/// configuration (product admission included) before anything is created, then the directories,
/// the exclusive data root lock, and the session-file confinement of synthetic runs.
enum OrbitProductLaunch {
    static func prepare(arguments: [String], infoDictionary: [String: Any], applicationSupport: URL,
                        build: OrbitBuildIdentity) throws -> (OrbitProductConfiguration, OrbitDataRootLock) {
        let configuration = try OrbitProductConfiguration(arguments: arguments, infoDictionary: infoDictionary,
                                                         applicationSupport: applicationSupport, build: build)
        try OrbitRecoveryRootRegistration.preflightExistingRoot(configuration.dataRoot)
        try configuration.prepareDirectories()
        let lock = try OrbitDataRootLock(dataRoot: configuration.dataRoot)
        // A synthetic run never opens a personal session file.
        _ = try PreviewLaunchConfiguration(arguments: arguments, confinement: configuration.syntheticGuard,
                                           defaultSessionFile: configuration.sessionFile)
        return (configuration, lock)
    }
}

/// Shared by the actual Chromium launcher and compiled, runtime-free product seam tests.
/// This is load-only: no registration creation or key preparation is reachable here.
enum OrbitAuthenticationStartup {
    static func run<T>(configuration: OrbitProductConfiguration, lock: OrbitDataRootLock,
                       backend: (() throws -> any OrbitRecoverySecItemBoundary)? = nil,
                       now: Int64 = Int64(Date().timeIntervalSince1970),
                       beforeStructuralRecovery: () throws -> Void = {},
                       runtimeStart: () throws -> T) throws -> T {
        guard let lease = lock.recoveryLease else { throw OrbitRecoveryFailure.unsafeFilesystem }
        let product: OrbitNativeRecoveryKeyProvider.Product
        switch configuration.secureStorage {
        case .mockKeychain: product = .daily
        case .keychain(let service, let account):
            if service == OrbitProductConfiguration.keychainService && account == OrbitProductConfiguration.keychainAccount { product = .daily }
            else if service == "Orbit Live Safe Storage" && account == "Orbit Live" { product = .live }
            else { throw OrbitRecoveryFailure.invalidEvidence }
        }
        return try OrbitAuthenticationStartupGate.runRegistered(lease: lease, product: product, backend: {
            if let backend { return try backend() }
            guard !configuration.usesMockKeychain else { throw OrbitRecoveryFailure.keyUnavailable }
            // Construction is passive. Only an admitted, evidence-bearing registration can
            // reach this factory; the recovery loader calls copyMatching, never add.
            return OrbitSystemRecoverySecItems()
        }, now: now, beforeStructuralRecovery: beforeStructuralRecovery, runtimeStart: runtimeStart)
    }
}
