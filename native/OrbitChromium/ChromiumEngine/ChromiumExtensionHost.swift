import AppKit
import OrbitChromiumBridge
import BrowserCore
import BrowserEngine

/// Native registry, manager and user-action adapter for side API v4.
/// Runtime acceptance is required before advertising general Store compatibility.
@MainActor
final class ChromiumExtensionHost: BrowserExtensionHost {
    weak var engine: ChromiumBrowserEngine?
    var onExtensionsChange: ((ProfileID) -> Void)?
    let supportsActions = true
    var supportsPinning: Bool { ACRExtensionPinningAvailable() == 1 }
    private let changeHub = BrowserExtensionChangeHub()
    private var observed: [ProfileID: UInt64] = [:]

    init(engine: ChromiumBrowserEngine) { self.engine = engine }

    private func profileToken(_ profileID: ProfileID) throws -> UInt64 {
        guard let engine, !engine.isShutDown, engine.persistence == .persistent,
              engine.surfaceMode == .hosted, ACRExtensionsAvailable() == 1 else {
            throw BrowserEngineError.unsupportedOperation
        }
        let token = engine.profileToken(for: profileID)
        guard !engine.refusedProfiles.contains(profileID), engine.runtime.isProfileReady(token) else {
            throw BrowserEngineError.unsupportedOperation
        }
        if observed[profileID] == nil {
            // Install ownership before entering the synchronous native observer API.
            observed[profileID] = token
            engine.runtime.extensionListeners[token] = { [weak self] in
                guard let self, self.observed[profileID] == token, self.engine?.isShutDown == false else { return }
                self.changeHub.emit(profileID)
                guard self.observed[profileID] == token, self.engine?.isShutDown == false else { return }
                self.onExtensionsChange?(profileID)
            }
            guard ACRObserveExtensions(token, 1) == 1, observed[profileID] == token, !engine.isShutDown else {
                observed[profileID] = nil
                engine.runtime.extensionListeners[token] = nil
                _ = ACRObserveExtensions(token, 0)
                throw BrowserEngineError.unsupportedOperation
            }
        }
        return token
    }

    func observeChanges(in profileID: ProfileID, handler: @escaping () -> Void) throws -> BrowserExtensionObservation {
        _ = try profileToken(profileID)
        return changeHub.observe(in: profileID, handler: handler)
    }

    func installedExtensions(in profileID: ProfileID) throws -> [BrowserExtensionSummary] {
        let token = try profileToken(profileID)
        let size = ACRExtensionsSnapshot(token, nil, 0)
        // A synchronous main-thread snapshot cannot change between these two calls.
        // Bound allocation even if an incompatible framework returns a corrupt size.
        guard size >= 0, size < 4 * 1024 * 1024 else { throw BrowserEngineError.unsupportedOperation }
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard ACRExtensionsSnapshot(token, &buffer, UInt32(buffer.count)) == size else {
            throw BrowserEngineError.unsupportedOperation
        }
        let data = Data(buffer.dropLast().map { UInt8(bitPattern: $0) })
        return try JSONDecoder().decode([BrowserExtensionSummary].self, from: data)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func installedExtensions(on surface: any BrowserEngineSurface) throws -> [BrowserExtensionSummary] {
        guard let engine, let surface = surface as? ChromiumSurface, surface.engine === engine,
              !surface.isDisposed, surface.isReady else { throw BrowserEngineError.unsupportedOperation }
        _ = try profileToken(surface.profileID)
        let size = ACRExtensionActionSnapshot(surface.token, nil, 0)
        guard size >= 0, size < 4 * 1024 * 1024 else { throw BrowserEngineError.unsupportedOperation }
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard ACRExtensionActionSnapshot(surface.token, &buffer, UInt32(buffer.count)) == size else {
            throw BrowserEngineError.unsupportedOperation
        }
        return try JSONDecoder().decode([BrowserExtensionSummary].self,
            from: Data(buffer.dropLast().map { UInt8(bitPattern: $0) }))
    }

    func setEnabled(_ enabled: Bool, extensionID: String, in profileID: ProfileID) throws {
        guard ACRExtensionSetEnabled(try profileToken(profileID), extensionID, enabled ? 1 : 0) == 1 else {
            throw BrowserEngineError.unsupportedOperation
        }
    }

    func setPinned(_ pinned: Bool, extensionID: String, in profileID: ProfileID) throws {
        guard ACRExtensionSetPinned(try profileToken(profileID), extensionID, pinned ? 1 : 0) == 1 else {
            throw BrowserEngineError.unsupportedOperation
        }
    }

    func setActionAnchor(_ anchor: NSView, on surface: any BrowserEngineSurface) {
        guard let engine, let surface = surface as? ChromiumSurface, surface.engine === engine else { return }
        _ = ACRSetExtensionActionAnchor(surface.token, Unmanaged.passUnretained(anchor).toOpaque())
    }

    func remove(extensionID: String, in profileID: ProfileID) throws {
        guard ACRExtensionRemove(try profileToken(profileID), extensionID) == 1 else {
            throw BrowserEngineError.unsupportedOperation
        }
    }

    func openManagement(on surface: any BrowserEngineSurface) throws {
        guard let manager = engine?.extensionManagement else { throw BrowserEngineError.unsupportedOperation }
        try manager.openManagement(on: surface)
    }

    func performAction(extensionID: String, on surface: any BrowserEngineSurface, anchor: NSView) throws {
        guard let engine, let surface = surface as? ChromiumSurface, surface.engine === engine,
              !surface.isDisposed, surface.isReady, surface.hostedWindowToken != 0,
              let window = surface.hostView.window, anchor.window === window,
              !surface.hostView.isHiddenOrHasHiddenAncestor else {
            throw BrowserEngineError.unsupportedOperation
        }
        // Restoring or reattaching a visible tab may have revoked the previous
        // extension lease while Chrome still reports the tab as active. Publish
        // the current selection before granting an action a new native lease.
        guard surface.activateTab() else { throw BrowserEngineError.unsupportedOperation }
        _ = try profileToken(surface.profileID)
        guard ACRPerformExtensionAction(surface.token, extensionID, Unmanaged.passUnretained(anchor).toOpaque()) == 1 else {
            throw BrowserEngineError.unsupportedOperation
        }
    }

    func stopObserving(_ profileID: ProfileID? = nil) {
        changeHub.remove(in: profileID)
        let cancelled = observed.filter { profileID == nil || $0.key == profileID }
        // Remove all Swift authority first: native unregister may synchronously reenter.
        for (id, token) in cancelled {
            observed[id] = nil
            engine?.runtime.extensionListeners[token] = nil
        }
        for token in cancelled.values { _ = ACRObserveExtensions(token, 0) }
    }
}

/// Manager-only v3 prefix adapter. Never registers a v4 observer or reads inventory.
@MainActor
final class ChromiumExtensionManagement: BrowserExtensionManagement {
    weak var engine: ChromiumBrowserEngine?
    init(engine: ChromiumBrowserEngine) { self.engine = engine }

    func openManagement(on surface: any BrowserEngineSurface) throws {
        try open(page: 0, extensionID: nil, on: surface)
    }

    func openDetails(extensionID: String, on surface: any BrowserEngineSurface) throws {
        try open(page: 1, extensionID: extensionID, on: surface)
    }

    func openShortcuts(on surface: any BrowserEngineSurface) throws {
        try open(page: 2, extensionID: nil, on: surface)
    }

    /// One exact manager document (0 manager, 1 details, 2 shortcuts) in the originating surface.
    private func open(page: Int32, extensionID: String?, on surface: any BrowserEngineSurface) throws {
        guard let engine, !engine.isShutDown, engine.persistence == .persistent,
              engine.surfaceMode == .hosted, ACRExtensionManagementAvailable() == 1,
              let surface = surface as? ChromiumSurface, surface.engine === engine,
              !surface.isDisposed, surface.isReady, surface.hostedWindowToken != 0,
              let window = surface.hostView.window,
              engine.shellWindows.values.contains(where: {
                  !$0.isClosed && $0.token == surface.hostedWindowToken && $0.window === window
              }),
              !engine.refusedProfiles.contains(surface.profileID),
              engine.runtime.isProfileReady(engine.profileToken(for: surface.profileID)) else {
            throw BrowserEngineError.unsupportedOperation
        }
        let opened = page == 0 ? ACROpenExtensionManager(surface.token)
            : ACROpenExtensionManagerPage(surface.token, page, extensionID ?? "")
        guard opened == 1 else { throw BrowserEngineError.unsupportedOperation }
    }
}
