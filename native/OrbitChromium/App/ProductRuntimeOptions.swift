import ChromiumEngine

/// Shared by the actual product launch and the non-launch admission probe. Creating options
/// neither starts CEF nor opens secure storage; the configured channel identity stays intact.
@MainActor
func productRuntimeOptions(_ configuration: OrbitProductConfiguration, extraSwitches: [String] = [],
                           hiddenApplication: Bool = false) -> ChromiumRuntime.Options {
    let storage: ChromiumRuntime.Options.SecureStorage = switch configuration.secureStorage {
    case .mockKeychain: .mockKeychain
    case .keychain(let service, let account): .keychain(service: service, account: account)
    }
    return ChromiumRuntime.Options(
        rootCachePath: configuration.engineRoot.path, keychainServiceName: "", keychainAccountName: "",
        extraSwitches: extraSwitches, hiddenApplication: hiddenApplication, secureStorage: storage,
        pageFirstKeyboard: true, networkPolicy: configuration.usesProductNetwork ? .product : .hermetic)
}
