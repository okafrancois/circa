import AppKit
import OrbitChromiumBridge
import BrowserCore
import BrowserEngine
import Foundation
import OSLog

@MainActor
public final class ChromiumBrowserEngine: BrowserPrivateEngine {
    private static let transferSignposter = OSSignposter(subsystem: "local.orbit", category: "surface-transfer")
    /// How `makeSurface` creates native browsers.
    public enum SurfaceMode: Equatable, Sendable {
        /// Alloy browsers parented to `hostView` (stock SDK behaviour, laboratory default).
        case alloy
        /// Chrome-style tabs: a surface's tab is created in the logical Browser of the shell
        /// window named by its `placement` (`shellWindowDidOpen`), at its first placement there or
        /// at its first command. A surface commanded while no shell window shows it gets its tab in
        /// the engine's never-shown holding window (windowless callers such as conformance).
        case hosted
    }

    /// The mode in use. `.hosted` requires the patched CEF (`patchLevel >= 1`).
    public let surfaceMode: SurfaceMode
    public let kind = BrowserEngineKind.chromium
    /// Unavailable until the native profile/renderer registration API is implemented.
    /// Existing diagnostic script evaluation is not a Boost injection mechanism.
    public var boosts: (any BrowserBoostHost)? { nil }
    /// Claimed only for implemented paths. `chromeWebStoreExtensions` is absent;
    /// `liveSurfaceTransfer` only in `.hosted` mode on side API v2 (`move_tab`, CHROMIUM-APP-R2),
    /// never on the stock SDK.
    public var capabilities: BrowserEngineCapabilities {
        var capabilities: BrowserEngineCapabilities = [.cacheBypassingReload,
            .exactFindCount, .nativeSiteZoom, .downloadPause, .downloadResume, .snapshots,
            .mediaCaptureState, .audioMuting, .favicons, .mediaCapturePermissions, .persistentProfiles,
            // CH-ESSENTIALS (ABI 9): context menus reported to the shell (CefContextMenuHandler),
            // DevTools in Chrome's undocked window, the system print panel.
            .pageContextMenus, .devTools, .printing, .fullPageSnapshots
        ]
        // beforeunload before a shell close: TryCloseBrowser on Chrome-style tabs. Chrome-style tabs
        // also render extension documents under the extension system's own access checks.
        if surfaceMode == .hosted { capabilities.formUnion([.beforeUnloadOnClose, .extensionDocuments, .pageSaving]) }
        if ACRBrowserStateAvailable() == 1 { capabilities.insert(.audibleState) }
        if supportsLiveTabMoves { capabilities.insert(.liveSurfaceTransfer) }
        if patchLevel >= 2 { capabilities.insert(.profileRemoval) }
        return capabilities
    }
    private lazy var extensionManager = ChromiumExtensionManagement(engine: self)
    public var extensionManagement: (any BrowserExtensionManagement)? {
        guard !isShutDown, surfaceMode == .hosted, persistence == .persistent,
              ACRExtensionManagementAvailable() == 1 else { return nil }
        return extensionManager
    }
    private lazy var extensionHost = ChromiumExtensionHost(engine: self)
    public var extensions: (any BrowserExtensionHost)? {
        guard !isShutDown, surfaceMode == .hosted, persistence == .persistent,
              ACRExtensionsAvailable() == 1 else { return nil }
        return extensionHost
    }

    public let persistence: BrowserWebsiteDataPersistence
    let runtime = ChromiumRuntime.shared
    private var profiles: [ProfileID: (token: UInt64, profile: BrowserEngineProfile)] = [:]
    // Hosted mode bookkeeping (see the `Hosted mode` extension).
    var shellWindows: [WindowID: ChromiumEngineWindow] = [:]
    /// Shell handlers for Chrome-created tabs, by shell window (`setEngineTabAdoption`).
    var tabAdoption: [WindowID: @MainActor (BrowserEngineTabRequest, () -> ChromiumSurface) -> ChromiumSurface?] = [:]
    /// Registration generation per window: a replaced or removed handler is never trusted after
    /// its callback returns (EXT-OUTCOME-R2).
    var tabAdoptionGenerations: [WindowID: UInt64] = [:]
    var tabAdoptionGeneration: UInt64 = 0
    var awaitingHostedCreation: [UInt64: WeakSurface] = [:]
    var activeHostedTabs: [UInt64: WeakSurface] = [:]
    var holdingWindow: (window: NSWindow, engineWindow: ChromiumEngineWindow)?
    var holdingWindowTabs = 0
    /// Native moves the shell has not settled yet, by surface token (CHROMIUM-APP-R3).
    var pendingNativeMoves: [UInt64: PendingNativeMove] = [:]

    /// Requires a ready runtime (`ChromiumRuntime.run` reported ready). `hostedWhenAvailable`
    /// selects `.hosted` on the patched CEF and `.alloy` on the stock SDK.
    public init(persistence: BrowserWebsiteDataPersistence = .persistent, hostedWhenAvailable: Bool = false) {
        precondition(runtime.isReady, "Create the Chromium engine after the runtime is ready")
        self.persistence = persistence
        surfaceMode = hostedWhenAvailable && ACRPatchLevel() >= 1 ? .hosted : .alloy
    }

    /// A profile whose request context the bridge refuses (alias guard, unusable directory,
    /// shutdown) is recorded as refused instead of stopping the process: its surfaces fail their
    /// creation and report their navigations as failed, `profileReady` returns at once, and
    /// launch goes on for every other profile.
    public func profile(for profileID: ProfileID) -> BrowserEngineProfile {
        if let existing = profiles[profileID] { return existing.profile }
        let token = runtime.makeToken()
        let path = persistence == .persistent ? profileDirectory(profileID) : ""
        let created = !isShutDown && ACRCreateProfile(token, path, persistence == .persistent ? 1 : 0) == 1
        let profile = BrowserEngineProfile(profileID: profileID, persistence: persistence)
        profiles[profileID] = (token, profile)
        if !created {
            refusedProfiles.insert(profileID)
            runtime.refuseProfile(token)
            runtime.trace?("profile-refused", ["profile": profileID.rawValue.uuidString, "shutDown": String(isShutDown)])
            FileHandle.standardError.write(Data("orbit: the Chromium profile request context was refused; its tabs stay unavailable\n".utf8))
        }
        return profile
    }

    /// Profiles whose request context was refused (see `profile(for:)`).
    public private(set) var refusedProfiles: Set<ProfileID> = []

    /// Level of the CEF essentials patch (`orbit_cef_essentials_level`): 1 fixes leaving element
    /// fullscreen, the sad tab and the hosted folder upload confirmation. 0 on frameworks without it.
    public var essentialsLevel: UInt32 { ACREssentialsLevel() }

    /// SETTINGS contract (`profileRemoval`, CHROMIUM-APP-R2). Refuses while a surface of the
    /// profile is not disposed; waits (bounded) for the native close of disposed ones; releases the
    /// request context; then removes the whole `profile-<uuid>` directory (Preferences,
    /// extensions, cookies and Login Data protected by "Orbit Safe Storage", caches) once Chrome
    /// unloaded the Profile, through the bridge's direct-child and alias guard, never by a path
    /// computed in Swift alone. Idempotent: an absent profile, or one this run never opened, is
    /// removed from disk the same way. Chrome's `Local State` keeps a profile metadata entry (no
    /// browsing data) until Chrome rewrites it.
    public func removeProfile(_ profileID: ProfileID) async throws {
        guard patchLevel >= 2 else { throw BrowserEngineError.unsupportedOperation }
        guard !isShutDown else { throw BrowserEngineError.unsupportedOperation }
        if runtime.registeredSurfaces.contains(where: { $0.engine === self && $0.profileID == profileID && !$0.isDisposed }) {
            throw BrowserEngineError.profileInUse
        }
        let deadline = ContinuousClock.now + .seconds(12)
        var released = false
        if let entry = profiles[profileID] {
            while ACRProfileBrowserCount(entry.token) != 0 {
                guard ContinuousClock.now < deadline else { throw BrowserEngineError.profileInUse }
                try? await Task.sleep(for: .milliseconds(20))
            }
            extensionHost.stopObserving(profileID)
            guard ACRReleaseProfile(entry.token) == 1 else { throw BrowserEngineError.profileInUse }
            profiles[profileID] = nil
            refusedProfiles.remove(profileID)
            runtime.forgetProfile(entry.token)
            released = true
        }
        guard persistence == .persistent else { return }
        let path = profileDirectory(profileID)
        let quiet = Duration.seconds(2)
        var absentSince: ContinuousClock.Instant?
        var attempts = 0
        var deletions = 0
        while true {
            attempts += 1
            let result = ACRRemoveProfileDirectory(path)
            let now = ContinuousClock.now
            switch result {
            case 2:
                // Something was deleted now (also a directory Chrome recreated): the quiet period
                // starts again (CHROMIUM-APP-R3, review MEDIUM 5).
                deletions += 1
                absentSince = nil
            case 1:
                // Unknown in this run and already absent: nothing of Chrome's can be writing there.
                if attempts == 1 && !released { return }
                if absentSince == nil { absentSince = now }
                if let absentSince, absentSince.duration(to: now) >= quiet {
                    runtime.trace?("profile-removed", ["profile": profileID.rawValue.uuidString,
                                                        "attempts": String(attempts), "deletions": String(deletions)])
                    return
                }
            case 0:
                absentSince = nil  // Still loaded, or in use.
            default:
                runtime.trace?("profile-removal-failed", ["code": String(result), "loaded": String(ACRProfileLoaded(path))])
                throw BrowserEngineError.profileRemovalIncomplete
            }
            guard now < deadline else {
                runtime.trace?("profile-removal-timeout", ["code": String(result), "deletions": String(deletions)])
                throw result == 0 ? BrowserEngineError.profileInUse : BrowserEngineError.profileRemovalIncomplete
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func profileDirectory(_ profileID: ProfileID) -> String {
        runtime.rootCachePath + "/profile-" + profileID.rawValue.uuidString.lowercased()
    }

    /// Laboratory only: binds a profile to CEF's global request context, where the stock SDK
    /// applies command-line extensions. Products must not share stores between profiles.
    public func laboratoryProfileUsingGlobalContext(_ profileID: ProfileID) -> BrowserEngineProfile {
        if let existing = profiles[profileID] { return existing.profile }
        let token = runtime.makeToken()
        precondition(ACRCreateProfile(token, "@global", 1) == 1)
        let profile = BrowserEngineProfile(profileID: profileID, persistence: .persistent)
        profiles[profileID] = (token, profile)
        return profile
    }

    /// Profiles resolved by this engine (one CEF request context each), for diagnostics.
    public var profileCount: Int { profiles.count }

    /// The bridge token of a profile, for laboratory introspection.
    public func profileToken(for profileID: ProfileID) -> UInt64 {
        _ = profile(for: profileID)
        return profiles[profileID]!.token
    }

    public func profileReady(_ profileID: ProfileID) async {
        await runtime.profileReady(profileToken(for: profileID))
    }

    public func preparePrivateProfile(_ profileID: ProfileID) async throws {
        guard persistence == .ephemeral, !isShutDown, !runtime.isQuitting,
              capabilities.contains(.profileRemoval), extensions == nil else {
            throw BrowserEngineError.unsupportedOperation
        }
        let token = profileToken(for: profileID)
        let deadline = ContinuousClock.now + .seconds(5)
        while !runtime.isProfileReady(token) {
            guard !refusedProfiles.contains(profileID), !isShutDown, !runtime.isQuitting,
                  ContinuousClock.now < deadline else { throw BrowserEngineError.unsupportedOperation }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    public func releasePrivateProfile(_ profileID: ProfileID) async throws {
        guard persistence == .ephemeral, !isShutDown,
              profiles.keys.allSatisfy({ $0 == profileID }) else { throw BrowserEngineError.profileInUse }
        guard !runtime.registeredSurfaces.contains(where: { $0.engine === self && !$0.isDisposed }) else {
            throw BrowserEngineError.profileInUse
        }
        let deadline = ContinuousClock.now + .seconds(12)
        // OnBeforeClose can precede deletion of an empty logical Chrome Browser. Use the
        // existing v3 counter; this wrapper leaves ordinary per-profile removal unchanged.
        let windows = Array(shellWindows.values) + (holdingWindow.map { [$0.engineWindow] } ?? [])
        while !liveNativeTokens.isEmpty || windows.contains(where: { $0.logicalBrowserCount != 0 }) {
            guard ContinuousClock.now < deadline else { throw BrowserEngineError.profileInUse }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard profiles.keys.allSatisfy({ $0 == profileID }),
              !runtime.registeredSurfaces.contains(where: { $0.engine === self && !$0.isDisposed }) else {
            throw BrowserEngineError.profileInUse
        }
        for window in windows { window.close() }
        shellWindows.removeAll()
        holdingWindow = nil
        holdingWindowTabs = 0
        try await removeProfile(profileID)
    }

    /// Creates the browser with no URL; no request and no delegate event before `navigate(to:)`.
    /// `isReady` turns true at `OnAfterCreated` (synchronously when the profile's request context
    /// is already initialized, since `CreateBrowserSync` is tried first).
    public func makeSurface(
        profileID: ProfileID,
        delegate: any BrowserEngineSurfaceDelegate<ChromiumSurface>
    ) -> ChromiumSurface {
        precondition(!isShutDown, "The Chromium engine is unusable after shutdown()")
        let surface = makePendingSurface(profileID: profileID)
        surface.delegate = delegate
        if surfaceMode == .hosted {
            surface.awaitsHostedCreation = true
            awaitingHostedCreation[surface.token] = WeakSurface(surface)
            // The shell places its surfaces in the turn that creates them; one never placed is a
            // windowless surface (conformance, probes) and gets its tab in the holding window, so
            // that it becomes ready like any other surface.
            Task { @MainActor [weak self, weak surface] in
                guard let self, let surface, surface.placement.windowID == nil else { return }
                self.createHostedBrowserIfPossible(surface, commanded: true)
            }
        } else {
            surface.createBrowser()
        }
        return surface
    }

    /// A surface whose browser will be created by CEF itself (popup or new-tab target).
    func makePendingSurface(profileID: ProfileID) -> ChromiumSurface {
        let surface = ChromiumSurface(engine: self, profileID: profileID, token: runtime.makeToken(),
                                      profileToken: profileToken(for: profileID))
        surface.onEngineEvent = onSurfaceEvent
        runtime.register(surface)
        return surface
    }

    public var conformanceProbe: (any BrowserEngineConformanceProbe<ChromiumSurface>)? { probe }
    private lazy var probe = ChromiumConformanceProbe(runtime: runtime)

    // MARK: Native lifetime

    /// Laboratory observation of raw engine events of every surface created from now on (the
    /// hidden smoke records the engine side of its scenarios). Never page content beyond URLs.
    public var onSurfaceEvent: ((String, [String: String]) -> Void)?

    /// Bridge tokens whose browser was requested and has not reported `OnBeforeClose` or a
    /// creation abort. Independent of Swift ownership: a surface the shell disposed and released
    /// stays here until CEF confirms the close.
    public private(set) var liveNativeTokens: Set<UInt64> = []
    /// True from the first `shutdown()` call: the engine refuses new profiles and surfaces.
    public private(set) var isShutDown = false
    /// Result of the latest `shutdown()`; nil before the first call.
    public private(set) var shutdownOutcome: ChromiumShutdownOutcome?
    /// Called when a shutdown ends without every close confirmed.
    public var onShutdownFailure: ((ChromiumShutdownOutcome) -> Void)?

    func nativeCreationStarted(_ token: UInt64) {
        liveNativeTokens.insert(token)
        runtime.setNativeOwner(self, for: token)
    }

    func nativeEnded(_ token: UInt64) {
        liveNativeTokens.remove(token)
        runtime.clearNativeOwner(token)
    }

    /// Contract entry point: bounded at 10 s; see `shutdown(timeout:)` for the outcome.
    public func shutdown() async {
        await shutdown(timeout: .seconds(10))
    }

    /// Marks the engine unusable, disposes surfaces the shell left live, closes browsers whose
    /// Swift surface is gone, then waits for every `OnBeforeClose` or creation abort. On timeout
    /// or cancellation by the application's earlier deadline, the outcome lists the tokens still
    /// alive and `onShutdownFailure` is called; it never
    /// reports completion while a browser of this engine exists.
    @discardableResult
    public func shutdown(timeout: Duration) async -> ChromiumShutdownOutcome {
        extensionHost.stopObserving()
        isShutDown = true
        awaitingHostedCreation.removeAll()
        var undisposed = 0
        for token in liveNativeTokens.sorted() {
            if let surface = runtime.surface(token) {
                if !surface.isDisposed { undisposed += 1; surface.dispose() }
            } else {
                _ = ACRCloseSurface(token)  // Orphan: no Swift owner left to dispose it.
            }
        }
        let deadline = ContinuousClock.now + timeout
        while !liveNativeTokens.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Hosted windows are released after their tabs closed (ABI 6: close tabs first).
        if liveNativeTokens.isEmpty {
            for window in shellWindows.values { window.close() }
            shellWindows.removeAll()
            holdingWindow?.engineWindow.close()
            holdingWindow = nil
        }
        let outcome: ChromiumShutdownOutcome = liveNativeTokens.isEmpty
            ? .completed(undisposedSurfaces: undisposed)
            : .timedOut(liveTokens: liveNativeTokens.sorted(), undisposedSurfaces: undisposed)
        shutdownOutcome = outcome
        if case .timedOut(let tokens, _) = outcome {
            runtime.trace?("engine-shutdown-timeout", ["live": tokens.map(String.init).joined(separator: ",")])
            onShutdownFailure?(outcome)
        }
        return outcome
    }
}

// MARK: Hosted mode (CHROMIUM-APP)

final class WeakSurface {
    weak var surface: ChromiumSurface?
    init(_ surface: ChromiumSurface) { self.surface = surface }
}

extension ChromiumBrowserEngine {
    /// Registers the shell window of `windowID` (`.hosted` mode; ignored in `.alloy` mode). The
    /// same NSWindow again is ignored; another NSWindow replaces the registration for new tabs.
    public func shellWindowDidOpen(_ windowID: WindowID, window: NSWindow) {
        guard surfaceMode == .hosted, !isShutDown else { return }
        if let existing = shellWindows[windowID], !existing.isClosed, existing.window === window { return }
        if let replaced = shellWindows[windowID] {
            runtime.clearWindowOwner(replaced.token)
            replaced.close(reason: "replaced")
        }
        guard let engineWindow = makeWindow(for: window) else {
            runtime.trace?("hosted-window-refused", ["window": windowID.rawValue.uuidString])
            shellWindows[windowID] = nil
            return
        }
        shellWindows[windowID] = engineWindow
        runtime.trace?("hosted-window-open", ["token": String(engineWindow.token), "window": windowID.rawValue.uuidString])
        // Surfaces placed in this window before it registered get their tabs now.
        for entry in awaitingHostedCreation.values {
            guard let surface = entry.surface, surface.placement.windowID == windowID,
                  surface.placement.container != .none else { continue }
            createHostedBrowserIfPossible(surface, commanded: false)
        }
    }

    /// Unregisters the shell window of `windowID` after the shell disposed or moved its surfaces.
    public func shellWindowWillClose(_ windowID: WindowID) {
        tabAdoption[windowID] = nil
        tabAdoptionGenerations[windowID] = nil
        guard let engineWindow = shellWindows.removeValue(forKey: windowID) else { return }
        runtime.clearWindowOwner(engineWindow.token)
        engineWindow.close(reason: "shell-window-will-close")
    }

    // MARK: Chrome-created tabs (EXT-OUTCOME-R1)

    public func setEngineTabAdoption(for windowID: WindowID,
                                     _ adopt: (@MainActor (BrowserEngineTabRequest, () -> ChromiumSurface) -> ChromiumSurface?)?) {
        tabAdoption[windowID] = adopt
        tabAdoptionGeneration &+= 1
        tabAdoptionGenerations[windowID] = tabAdoptionGeneration
    }

    /// A tab Chrome is creating by itself in the logical Browser of (`windowToken`,
    /// `profileToken`), offered by a patched framework before its CEF browser exists. The shell
    /// window that registered the token records it like a new target; the returned pending
    /// surface receives the tab's browser (OnAfterCreated or a creation abort follows). Nil leaves
    /// the tab without client or view, as before.
    func adoptEngineCreatedTab(windowToken: UInt64, profileToken: UInt64, url: String?,
                               foreground: Bool) -> ChromiumSurface? {
        guard !isShutDown, surfaceMode == .hosted,
              let (windowID, engineWindow) = shellWindows.first(where: { $0.value.token == windowToken && !$0.value.isClosed }),
              let adopt = tabAdoption[windowID], let generation = tabAdoptionGenerations[windowID],
              let profileID = profiles.first(where: { $0.value.token == profileToken })?.key,
              runtime.isProfileReady(profileToken) else { return nil }
        let nativeWindow = engineWindow.window
        let request = BrowserEngineTabRequest(url: url.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                                              profileID: profileID, isForeground: foreground)
        var created: ChromiumSurface?
        let accepted = adopt(request) {
            precondition(created == nil, "An engine-created tab can be made only once")
            let child = makePendingSurface(profileID: profileID)
            child.markCreationPending()
            created = child
            return child
        }
        guard let accepted, accepted === created else {
            created?.abandonUnstartedCreation()
            return nil
        }
        // The shell callback can close or replace the window, remove its handler, remove or
        // unready the profile, dispose the surface or shut the engine down: verify everything
        // again. A refusal now aborts the surface the shell recorded, exactly once; the bridge
        // receives no view and sends no second abort.
        let hostWindow = accepted.hostView.window
        guard !isShutDown, !accepted.isDisposed, accepted.isCreationPending,
              let current = shellWindows[windowID], current === engineWindow, !current.isClosed,
              current.token == windowToken, let window = current.window, window === nativeWindow,
              hostWindow == nil || hostWindow === window,
              runtime.windowOwner(windowToken) === self,
              tabAdoption[windowID] != nil, tabAdoptionGenerations[windowID] == generation,
              profiles[profileID]?.token == profileToken, runtime.isProfileReady(profileToken) else {
            if !accepted.isDisposed { accepted.creationAborted(reason: "engine-tab-authority-revoked") }
            return nil
        }
        // CEF creates the browser right after the bridge returns this surface's client.
        nativeCreationStarted(accepted.token)
        runtime.trace?("engine-tab-adopted", ["token": String(accepted.token), "foreground": String(foreground)])
        return accepted
    }

    /// Live shell window registrations, for diagnostics.
    public var hostedWindowCount: Int { shellWindows.values.filter { !$0.isClosed }.count }
    /// Every shell window registration (model window, token, closed), for diagnostics.
    public var hostedWindowRegistrations: [[String: String]] {
        shellWindows.map { ["window": $0.key.rawValue.uuidString, "token": String($0.value.token),
                            "closed": String($0.value.isClosed)] }
    }
    /// `safebrowsing.enabled` of a profile's context (nil: the global context), for diagnostics.
    /// The bridge turns it off (no Google API key: Safe Browsing cannot work, CHROMIUM-APP-R3).
    public func safeBrowsingPreference(for profileID: ProfileID?) -> Bool? {
        let token = profileID.flatMap { profiles[$0]?.token } ?? 0
        switch ACRSafeBrowsingEnabled(token) {
        case 1: return true
        case 0: return false
        default: return nil
        }
    }

    /// Live logical Browsers of a shell window's engine registration (-1 when unknown).
    public func logicalBrowserCount(for windowID: WindowID) -> Int {
        shellWindows[windowID].map { $0.logicalBrowserCount } ?? -1
    }

    /// The engine window token registered for a shell window, for diagnostics.
    public func hostedWindowToken(for windowID: WindowID) -> UInt64? {
        shellWindows[windowID].flatMap { $0.isClosed ? nil : $0.token }
    }
    /// Tabs created in the holding window (never shown) because no shell window showed their
    /// surface at their first command. Zero in the product composition.
    public var holdingWindowTabCount: Int { holdingWindowTabs }

    func surfacePlacementDidChange(_ surface: ChromiumSurface) {
        guard surfaceMode == .hosted, !surface.isDisposed else { return }
        if surface.awaitsHostedCreation {
            createHostedBrowserIfPossible(surface, commanded: false)
            return
        }
        followPlacementWindow(surface)
    }

    /// A tab whose placement names another registered window than its logical Browser's moves
    /// there (side API v2): a returned transfer, a Peek or container promoted into another window.
    /// Without v2 (or on failure) the tab stays in its Browser and the mismatch is traced; its view
    /// still moves with `hostView`.
    func followPlacementWindow(_ surface: ChromiumSurface) {
        guard surface.isBrowserCreated, surface.hostedWindowToken != 0, let windowID = surface.placement.windowID,
              let window = shellWindows[windowID], !window.isClosed, window.token != surface.hostedWindowToken else { return }
        // Back to the source of an unsettled move: at its original index (CHROMIUM-APP-R3).
        let origin = pendingNativeMoves[surface.token]
        let index = origin.flatMap { $0.sourceToken == window.token && $0.sourceIndex >= 0 ? Int($0.sourceIndex) : nil }
        guard supportsLiveTabMoves, moveHostedTab(surface, to: window.token, index: index) else {
            runtime.trace?("hosted-placement-window-mismatch", ["token": String(surface.token)])
            return
        }
        runtime.trace?("hosted-tab-followed-placement", ["token": String(surface.token)])
    }

    /// Where the native tab of a surface came from, until the shell settles its move.
    struct PendingNativeMove {
        let sourceToken: UInt64
        let sourceIndex: Int32
        /// A transfer hold taken on the source window (side API v3).
        let held: Bool
    }

    /// Side API v2 in hosted mode: tabs move between logical Browsers without reloading.
    var supportsLiveTabMoves: Bool { surfaceMode == .hosted && patchLevel >= 2 }

    /// Moves the native tab of `surface` to `index` (nil appends) of the logical Browser of the
    /// window `token`, or reorders it there. Keeps the activation bookkeeping of both windows.
    @discardableResult
    func moveHostedTab(_ surface: ChromiumSurface, to token: UInt64, index: Int? = nil) -> Bool {
        let interval = Self.transferSignposter.beginInterval("ChromiumTabMove", id: Self.transferSignposter.makeSignpostID())
        defer { Self.transferSignposter.endInterval("ChromiumTabMove", interval) }
        let source = surface.hostedWindowToken
        guard surface.isBrowserCreated, !surface.isDisposed, source != 0,
              ACRMoveSurfaceToWindow(surface.token, token, index.map { Int32(clamping: $0) } ?? -1,
                                     Unmanaged.passUnretained(surface.hostView).toOpaque()) == 1 else { return false }
        guard source != token else { return true }
        surface.hostedWindowToken = token
        if activeHostedTabs[source]?.surface === surface { activeHostedTabs[source] = nil }
        // The tab the destination shows stays its active tab (Chrome inserts in the background).
        if surface.hostView.window != nil, !surface.hostView.isHiddenOrHasHiddenAncestor { activateHostedTab(surface) }
        runtime.trace?("hosted-tab-moved", ["token": String(surface.token), "from": String(source), "to": String(token)])
        return true
    }

    public func shellWillMoveSurfaces(_ surfaces: [ChromiumSurface], toWindow windowID: WindowID) -> Bool {
        guard surfaceMode == .hosted else { return true }  // Alloy views move with `hostView`.
        guard supportsLiveTabMoves, !isShutDown, let window = shellWindows[windowID], !window.isClosed else { return false }
        var moved: [(surface: ChromiumSurface, origin: PendingNativeMove)] = []
        func rollBack() {
            var restored = true
            for entry in moved.reversed() {
                restored = restoreOrigin(entry.surface, entry.origin) && restored
                if entry.origin.held { _ = ACRReleaseWindow(entry.origin.sourceToken) }
            }
            runtime.trace?("hosted-move-refused", ["surfaces": String(surfaces.count), "rolledBack": String(moved.count),
                                                   "restored": String(restored)])
        }
        for surface in surfaces {
            if surface.isDisposed || (surface.isCreationPending && !surface.isBrowserCreated) || pendingNativeMoves[surface.token] != nil {
                rollBack()
                return false
            }
            guard surface.isBrowserCreated, surface.hostedWindowToken != window.token else { continue }
            let source = surface.hostedWindowToken
            let held = ACRHoldWindow(source) > 0
            let origin = PendingNativeMove(sourceToken: source, sourceIndex: surface.tabIdentity?.index ?? -1, held: held)
            guard moveHostedTab(surface, to: window.token) else {
                if held { _ = ACRReleaseWindow(source) }
                rollBack()
                return false
            }
            moved.append((surface, origin))
        }
        for entry in moved { pendingNativeMoves[entry.surface.token] = entry.origin }
        return true
    }

    /// Contract hook (CHROMIUM-APP-R3): the shell settled a move. Not committed, each tab returns
    /// to its source window at its original index (normally already done by following its
    /// placement back); then the source holds are released, which closes a source Browser left
    /// empty by a committed move. A failed restoration is traced and retried by the next
    /// placement change, never silently dropped.
    public func shellDidFinishMovingSurfaces(_ surfaces: [ChromiumSurface], toWindow windowID: WindowID, committed: Bool) {
        for surface in surfaces {
            guard let origin = pendingNativeMoves.removeValue(forKey: surface.token) else { continue }
            if !committed, !surface.isDisposed, !restoreOrigin(surface, origin) {
                runtime.trace?("hosted-move-rollback-failed", ["token": String(surface.token)])
            }
            if origin.held { _ = ACRReleaseWindow(origin.sourceToken) }
        }
    }

    /// The tab back in its source window's Browser, at its original index.
    private func restoreOrigin(_ surface: ChromiumSurface, _ origin: PendingNativeMove) -> Bool {
        guard surface.isBrowserCreated, !surface.isDisposed else { return true }
        let index = origin.sourceIndex >= 0 ? Int(origin.sourceIndex) : nil
        if surface.hostedWindowToken == origin.sourceToken, surface.tabIdentity?.index == origin.sourceIndex { return true }
        return moveHostedTab(surface, to: origin.sourceToken, index: index)
    }

    /// Contract hook (CHROMIUM-APP-R2, review M2): mirrors the sidebar order of a window into the
    /// tab strips of its logical Browsers, one per profile, so that extension indices follow it.
    public func shellWindowTabOrderDidChange(_ windowID: WindowID, surfaces: [ChromiumSurface]) {
        guard supportsLiveTabMoves, let window = shellWindows[windowID], !window.isClosed else { return }
        var next: [ProfileID: Int] = [:]
        for surface in surfaces where surface.isBrowserCreated && surface.hostedWindowToken == window.token {
            let index = next[surface.profileID, default: 0]
            next[surface.profileID] = index + 1
            if surface.tabIdentity?.index != Int32(index) { moveHostedTab(surface, to: window.token, index: index) }
        }
    }

    /// Creates the hosted tab of `surface` in the shell window its placement names, or, for a
    /// command while no shell window shows it, in the holding window.
    func createHostedBrowserIfPossible(_ surface: ChromiumSurface, commanded: Bool) {
        guard surface.awaitsHostedCreation, !surface.isDisposed, !isShutDown else { return }
        let window: ChromiumEngineWindow
        if let windowID = surface.placement.windowID, surface.placement.container != .none {
            guard let registered = shellWindows[windowID], !registered.isClosed else { return }  // Waits for it.
            window = registered
        } else {
            guard commanded, let holding = holdingEngineWindow() else { return }
            window = holding
            holdingWindowTabs += 1
            runtime.trace?("hosted-holding-window-tab", ["token": String(surface.token)])
        }
        awaitingHostedCreation[surface.token] = nil
        surface.createTabBrowser(window: window.token, index: -1)
    }

    func hostedSurfaceDisposedBeforeCreation(_ surface: ChromiumSurface) {
        awaitingHostedCreation[surface.token] = nil
    }

    /// Chrome inserts new tabs as the active tab of their Browser. The tab the shell shows keeps
    /// being the active one: a tab created in the background gives the activation back.
    func hostedTabDidCreate(_ surface: ChromiumSurface) {
        // Moved by the shell while its creation was in flight: it follows its placement now.
        followPlacementWindow(surface)
        let window = surface.hostedWindowToken
        if surface.hostView.window != nil, !surface.hostView.isHiddenOrHasHiddenAncestor {
            // Publishing native shell selection must precede the activation cache:
            // Chrome already reports a newly inserted tab active, even in a new profile.
            if surface.activateTab() { activeHostedTabs[window] = WeakSurface(surface) }
        } else if let active = activeHostedTabs[window]?.surface, active !== surface, !active.isDisposed,
                  active.profileID == surface.profileID {
            _ = active.activateTab()
        }
    }

    /// Makes `surface` the active tab of its logical Browser (`tabs.onActivated`), once per change.
    func activateHostedTab(_ surface: ChromiumSurface) {
        let window = surface.hostedWindowToken
        guard window != 0 else { return }
        if activeHostedTabs[window]?.surface === surface, surface.tabIdentity?.isActive == true { return }
        if surface.activateTab() { activeHostedTabs[window] = WeakSurface(surface) }
    }

    private func holdingEngineWindow() -> ChromiumEngineWindow? {
        if let holdingWindow, !holdingWindow.engineWindow.isClosed { return holdingWindow.engineWindow }
        // Never ordered on screen; it only gives windowless tabs a logical Browser.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        guard let engineWindow = makeWindow(for: window) else { return nil }
        holdingWindow = (window, engineWindow)
        return engineWindow
    }
}

public enum ChromiumShutdownOutcome: Equatable, Sendable {
    /// Every browser of the engine reported `OnBeforeClose` (or its creation was aborted).
    /// `undisposedSurfaces` counts surfaces the shell had not disposed before `shutdown()`.
    case completed(undisposedSurfaces: Int)
    /// Some browsers were still alive at the deadline; the engine stays unusable.
    case timedOut(liveTokens: [UInt64], undisposedSurfaces: Int)

    public var isCompleted: Bool { if case .completed = self { true } else { false } }
}

/// Site-data isolation probe through each browser's own request context cookie manager.
@MainActor
final class ChromiumConformanceProbe: BrowserEngineConformanceProbe {
    typealias Surface = ChromiumSurface
    enum ProbeError: Error { case surfaceNotReady, cookieManagerUnavailable, cookieWriteFailed, scriptFailed }
    private let runtime: ChromiumRuntime
    private static let name = "orbit_conformance_marker"

    init(runtime: ChromiumRuntime) { self.runtime = runtime }

    private func ready(_ surface: ChromiumSurface) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !surface.isReady {
            guard ContinuousClock.now < deadline, !surface.isDisposed else { throw ProbeError.surfaceNotReady }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func writeSiteDataMarker(_ value: String, for origin: URL, through surface: ChromiumSurface) async throws {
        try await ready(surface)
        let request = ACRCookieSet(surface.token, origin.absoluteString, Self.name, value)
        guard request != 0 else { throw ProbeError.cookieManagerUnavailable }
        guard await runtime.cookieResult(request).success else { throw ProbeError.cookieWriteFailed }
    }

    func readSiteDataMarker(for origin: URL, through surface: ChromiumSurface) async throws -> String? {
        try await ready(surface)
        let request = ACRCookieRead(surface.token, origin.absoluteString, Self.name)
        guard request != 0 else { throw ProbeError.cookieManagerUnavailable }
        return await runtime.cookieResult(request).value
    }

    /// DevTools `Runtime.evaluate` in the main frame, as a user gesture (CONTRACT-R2 probe).
    func evaluateScript(_ script: String, in surface: ChromiumSurface) async throws -> String? {
        try await ready(surface)
        let source = String(data: try JSONEncoder().encode(script), encoding: .utf8)!
        let expression = "(() => { const v = (0, eval)(\(source)); return (v === undefined || v === null) ? null : String(v); })()"
        let params = try JSONSerialization.data(withJSONObject: [
            "expression": expression, "userGesture": true, "returnByValue": true, "awaitPromise": true
        ])
        let (success, data) = await surface.devToolsCall("Runtime.evaluate", params: String(decoding: params, as: UTF8.self))
        guard success, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["exceptionDetails"] == nil, let result = object["result"] as? [String: Any] else {
            throw ProbeError.scriptFailed
        }
        return result["value"] as? String
    }
}

// The optional printing service is shared by browser windows and Little Orbit.
extension ChromiumBrowserEngine: BrowserPagePrinting {
    public func printPage(_ surface: ChromiumSurface) throws {
        try surface.perform(.print)
    }
}
