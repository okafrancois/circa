import BrowserCore
import CryptoKit
import Foundation

/// Loading an existing run never queries the source browser. Synthetic launches cannot construct
/// a system Keychain provider and accept only their confined, explicitly generated fixture key.
enum ChromiumAuthenticationStartup {
    static func recoveryKey(_ configuration: OrbitProductConfiguration) throws -> SymmetricKey {
        if let guardRoot = configuration.syntheticGuard {
            try guardRoot.checkRoot()
            let file = configuration.dataRoot.appendingPathComponent("import-auth-fixture-key")
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw BrowserAuthenticationImportError.invalidState }
            let bytes = try Data(contentsOf: file)
            guard bytes.count == 32 else { throw BrowserAuthenticationImportError.invalidState }
            return SymmetricKey(data: bytes)
        }
        let product: OrbitNativeRecoveryKeyProvider.Product
        switch configuration.secureStorage {
        case .mockKeychain: throw BrowserAuthenticationImportError.invalidState
        case .keychain(let service, _): product = service == "Orbit Live Safe Storage" ? .live : .daily
        }
        return try BrowserAuthenticationRunKey.load(dataRoot: configuration.dataRoot, product: product, backend: OrbitSystemRecoverySecItems())
    }
}
