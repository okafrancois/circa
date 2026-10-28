import AppKit
import OrbitChromiumBridge
import BrowserCore
import BrowserEngine
import Foundation

/// Process-wide owner of the CEF message loop and the bridge callbacks. CEF's UI thread is the
/// main thread on macOS, so every callback is delivered on the main actor.
@MainActor
public final class ChromiumRuntime {
    public struct Options {
        /// Where Chromium's OSCrypt keeps its key (ABI 7). A run is one or the other, never both.
        public enum SecureStorage: Equatable, Sendable {
            /// `--use-mock-keychain`: every automated run.
            case mockKeychain
            /// The real macOS Keychain item of a product build.
            case keychain(service: String, account: String)
        }

        /// Chromium's background network services (ABI 8, `ACRNetworkPolicy`).
        public enum NetworkPolicy: Equatable, Sendable {
            /// No background networking, component updater or network time: every automated run.
            case hermetic
            /// The signed daily build: component updater and extension updates on; sync, metrics,
            /// crash upload, variations, sign-in and autofill crowdsourcing off.
            case product
        }

        /// Existing private directory. Persistent profiles live below it.
        public var rootCachePath: String
        /// Kept for laboratory callers; used only through `secureStorage`.
        public var keychainServiceName: String
        public var keychainAccountName: String
        public var secureStorage: SecureStorage
        /// Routes page-first key downs through surface delegates (ABI 7 keyboard callbacks).
        public var pageFirstKeyboard: Bool
        /// Appended verbatim to the browser command line, for example `--load-extension=...`.
        public var extraSwitches: [String]
        /// Prohibited activation policy: no Dock icon, no activation. Laboratory runs only.
        public var hiddenApplication: Bool
        /// Laboratory measurement of `OnBeforeResourceLoad` holds; see the bridge header.
        public var asyncNavigationHold: Bool
        public var networkPolicy: NetworkPolicy

        public init(rootCachePath: String, keychainServiceName: String, keychainAccountName: String,
                    extraSwitches: [String] = [], hiddenApplication: Bool = false,
                    asyncNavigationHold: Bool = false, secureStorage: SecureStorage = .mockKeychain,
                    pageFirstKeyboard: Bool = false, networkPolicy: NetworkPolicy = .hermetic) {
            self.networkPolicy = networkPolicy
            self.rootCachePath = rootCachePath
            self.keychainServiceName = keychainServiceName
            self.keychainAccountName = keychainAccountName
            self.secureStorage = secureStorage
            self.pageFirstKeyboard = pageFirstKeyboard
            self.extraSwitches = extraSwitches
            self.hiddenApplication = hiddenApplication
            self.asyncNavigationHold = asyncNavigationHold
        }
    }

    public static let shared = ChromiumRuntime()

    public private(set) var isReady = false
    public private(set) var isQuitting = false
    public private(set) var rootCachePath = ""
    /// Diagnostic tap for the laboratory. Never receives page content beyond URLs and titles.
    public var trace: ((String, [String: String]) -> Void)?
    /// Laboratory hold handler; nil allows immediately.
    public var asyncNavigationHold: ((ChromiumSurface, URL?) async -> BrowserNavigationActionPolicy)?

    private var onReady: (() -> Void)?
    private var surfaces: [UInt64: WeakSurface] = [:]
    // CEF stops download callbacks when its source browser dies, although the file keeps
    // downloading. Keep that browser independently of the shell tab until its transfers end.
    private var downloadSurfaces: [UInt64: ChromiumSurface] = [:]
    private var profileWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
    private var refusedProfiles: Set<UInt64> = []
    private var readyProfiles: Set<UInt64> = []
    var extensionListeners: [UInt64: () -> Void] = [:]
    private var nextToken: UInt64 = 1
    private var cookieWaiters: [UInt64: CheckedContinuation<(success: Bool, value: String?), Never>] = [:]
    private var cookieResults: [UInt64: (success: Bool, value: String?)] = [:]

    private final class WeakSurface {
        weak var surface: ChromiumSurface?
        init(_ surface: ChromiumSurface) { self.surface = surface }
    }
    private final class WeakEngine {
        weak var engine: ChromiumBrowserEngine?
        init(_ engine: ChromiumBrowserEngine) { self.engine = engine }
    }
    /// Engine that requested each live browser, kept until `OnBeforeClose` or a creation abort.
    private var nativeOwners: [UInt64: WeakEngine] = [:]
    /// Engine that registered each shell window token (EXT-OUTCOME-R1 tab adoption).
    private var windowOwners: [UInt64: WeakEngine] = [:]
    /// Whether the quit watchdog reported a stall (the loop then exits with status 75).
    public private(set) var quitStalls = 0
    /// The bounded quit ended the loop before every browser confirmed its close (status 77).
    public private(set) var quitForced = false

    private init() {}

    func makeToken() -> UInt64 {
        defer { nextToken += 1 }
        return nextToken
    }

    func register(_ surface: ChromiumSurface) { surfaces[surface.token] = WeakSurface(surface) }
    func unregister(_ token: UInt64) { surfaces[token] = nil; downloadSurfaces[token] = nil }
    func retainDownloadSource(_ surface: ChromiumSurface) { downloadSurfaces[surface.token] = surface }
    func releaseDownloadSource(_ token: UInt64) { downloadSurfaces[token] = nil }
    func surface(_ token: UInt64) -> ChromiumSurface? { surfaces[token]?.surface }
    /// Registered surfaces still alive in Swift.
    var registeredSurfaces: [ChromiumSurface] { surfaces.values.compactMap(\.surface) }
    /// A removed profile's token is never ready again.
    func forgetProfile(_ token: UInt64) {
        extensionListeners[token] = nil
        readyProfiles.remove(token)
        refusedProfiles.remove(token)
    }
    func setNativeOwner(_ engine: ChromiumBrowserEngine, for token: UInt64) { nativeOwners[token] = WeakEngine(engine) }
    func clearNativeOwner(_ token: UInt64) { nativeOwners[token] = nil }
    func setWindowOwner(_ engine: ChromiumBrowserEngine, for token: UInt64) { windowOwners[token] = WeakEngine(engine) }
    func clearWindowOwner(_ token: UInt64) { windowOwners[token] = nil }
    func windowOwner(_ token: UInt64) -> ChromiumBrowserEngine? { windowOwners[token]?.engine }

    /// Blocks in CEF's message loop until shutdown. Call before `NSApplication.shared` is touched.
    public func run(options: Options, onReady: @escaping () -> Void) -> Int32 {
        self.onReady = onReady
        rootCachePath = options.rootCachePath
        var callbacks = ACRCallbacks()
        callbacks.abi_version = ACR_ABI_VERSION
        callbacks.struct_size = UInt32(MemoryLayout<ACRCallbacks>.size)
        callbacks.event = { context, event in
            guard let context, let event else { return }
            let copy = ChromiumEvent(event.pointee)
            let runtimeAddress = UInt(bitPattern: context)
            MainActor.assumeIsolated {
                Unmanaged<ChromiumRuntime>.fromOpaque(UnsafeRawPointer(bitPattern: runtimeAddress)!)
                    .takeUnretainedValue().receive(copy)
            }
        }
        callbacks.decide_new_surface = { context, source, url, disposition, gesture, kind, token in
            guard let context, let token else { return nil }
            let target = url.map { String(cString: $0) }
            let runtimeAddress = UInt(bitPattern: context)
            let decision: (UInt64, UInt) = MainActor.assumeIsolated {
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(UnsafeRawPointer(bitPattern: runtimeAddress)!)
                    .takeUnretainedValue()
                guard let created = runtime.surface(source)?.decideNewSurface(
                    url: target, disposition: disposition, userGesture: gesture != 0, keepsOpener: kind == 1) else { return (0, 0) }
                return (created.token, UInt(bitPattern: Unmanaged.passUnretained(created.hostView).toOpaque()))
            }
            guard decision.0 != 0 else { return nil }
            token.pointee = decision.0
            return UnsafeMutableRawPointer(bitPattern: decision.1)
        }
        // ABI 11 (EXT-OUTCOME-R1): a Chrome-created tab of a registered shell window.
        callbacks.adopt_engine_tab = { context, window, profile, url, foreground, token in
            guard let context, let token else { return nil }
            let target = url.map { String(cString: $0) }
            let runtimeAddress = UInt(bitPattern: context)
            let decision: (UInt64, UInt) = MainActor.assumeIsolated {
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(UnsafeRawPointer(bitPattern: runtimeAddress)!)
                    .takeUnretainedValue()
                guard let created = runtime.windowOwner(window)?.adoptEngineCreatedTab(
                    windowToken: window, profileToken: profile, url: target, foreground: foreground != 0) else { return (0, 0) }
                return (created.token, UInt(bitPattern: Unmanaged.passUnretained(created.hostView).toOpaque()))
            }
            guard decision.0 != 0 else { return nil }
            token.pointee = decision.0
            return UnsafeMutableRawPointer(bitPattern: decision.1)
        }
        callbacks.decide_navigation = { context, surface, info in
            guard let context, let info else { return Int32(ACR_POLICY_CANCEL.rawValue) }
            let request = ChromiumNavigationRequest(info.pointee)
            let runtimeAddress = UInt(bitPattern: context)
            return MainActor.assumeIsolated {
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(UnsafeRawPointer(bitPattern: runtimeAddress)!)
                    .takeUnretainedValue()
                guard let surface = runtime.surface(surface) else { return Int32(ACR_POLICY_CANCEL.rawValue) }
                return Int32(surface.decideNavigation(request).rawValue)
            }
        }
        if options.pageFirstKeyboard {
            callbacks.decide_key = { context, event, track in
                guard let context, let event, let track else { return 0 }
                let key = ChromiumKeyEvent(event.pointee)
                let runtimeAddress = UInt(bitPattern: context)
                let decision: (consume: Bool, track: Bool) = MainActor.assumeIsolated {
                    let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(UnsafeRawPointer(bitPattern: runtimeAddress)!)
                        .takeUnretainedValue()
                    return runtime.surface(key.surfaceToken)?.decideKey(key) ?? (false, false)
                }
                track.pointee = decision.track ? 1 : 0
                return decision.consume ? 1 : 0
            }
            callbacks.unhandled_key = { context, event in
                guard let context, let event else { return 0 }
                let key = ChromiumKeyEvent(event.pointee)
                let runtimeAddress = UInt(bitPattern: context)
                return MainActor.assumeIsolated {
                    let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(UnsafeRawPointer(bitPattern: runtimeAddress)!)
                        .takeUnretainedValue()
                    return runtime.surface(key.surfaceToken)?.pageDidNotHandleKey(key) == true ? 1 : 0
                }
            }
        }
        let switches = options.extraSwitches.map { strdup($0) }
        defer { switches.forEach { free($0) } }
        let root = strdup(options.rootCachePath)
        let keychain: (service: String, account: String)? = switch options.secureStorage {
        case .mockKeychain: nil
        case .keychain(let service, let account): (service, account)
        }
        let service = keychain.map { strdup($0.service) } ?? nil
        let account = keychain.map { strdup($0.account) } ?? nil
        defer { free(root); free(service); free(account) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        return switches.withUnsafeBufferPointer { buffer -> Int32 in
            buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { pointers in
                var runOptions = ACRRunOptions()
                runOptions.struct_size = UInt32(MemoryLayout<ACRRunOptions>.size)
                runOptions.root_cache_path = UnsafePointer(root)
                runOptions.keychain_service_name = UnsafePointer(service)
                runOptions.keychain_account_name = UnsafePointer(account)
                runOptions.extra_switches = pointers.baseAddress
                runOptions.extra_switch_count = pointers.count
                runOptions.hidden_accessory_app = options.hiddenApplication ? 1 : 0
                runOptions.async_navigation_hold = options.asyncNavigationHold ? 1 : 0
                runOptions.secure_storage = Int32(keychain == nil ? ACR_SECURE_STORAGE_MOCK.rawValue
                                                                  : ACR_SECURE_STORAGE_KEYCHAIN.rawValue)
                runOptions.network_policy = Int32(options.networkPolicy == .product ? ACR_NETWORK_PRODUCT.rawValue
                                                                                    : ACR_NETWORK_HERMETIC.rawValue)
                return ACRRun(CommandLine.argc, CommandLine.unsafeArgv, &runOptions, &callbacks, context)
            }
        }
    }

    /// Closes every browser, then leaves the message loop.
    public func requestQuit() {
        isQuitting = true
        _ = ACRRequestQuit()
    }

    /// A refused profile never becomes ready; its waiters return at once.
    func refuseProfile(_ token: UInt64) {
        refusedProfiles.insert(token)
        for waiter in profileWaiters.removeValue(forKey: token) ?? [] { waiter.resume() }
    }

    func isProfileRefused(_ token: UInt64) -> Bool { refusedProfiles.contains(token) }

    func profileReady(_ token: UInt64) async {
        if readyProfiles.contains(token) || refusedProfiles.contains(token) { return }
        await withCheckedContinuation { profileWaiters[token, default: []].append($0) }
    }

    func isProfileReady(_ token: UInt64) -> Bool { readyProfiles.contains(token) }

    func cookieResult(_ request: UInt64) async -> (success: Bool, value: String?) {
        if let result = cookieResults.removeValue(forKey: request) { return result }
        return await withCheckedContinuation { cookieWaiters[request] = $0 }
    }

    private func receive(_ event: ChromiumEvent) {
        if event.kind == ACR_EVENT_DOWNLOAD {
            trace?("download", ["id": String(event.downloadID), "request": String(event.requestID),
                                "status": String(event.downloadStatus.rawValue), "reason": String(event.interruptReason),
                                "bytes": String(event.receivedBytes)])
        }
        switch event.kind {
        case ACR_EVENT_READY:
            isReady = true
            trace?("ready", [:])
            let ready = onReady
            onReady = nil
            ready?()
        case ACR_EVENT_PROFILE_READY:
            readyProfiles.insert(event.profileToken)
            trace?("profile-ready", ["profile": String(event.profileToken), "sharesGlobal": String(event.value == 2)])
            for waiter in profileWaiters.removeValue(forKey: event.profileToken) ?? [] { waiter.resume() }
        case ACR_EVENT_EXTENSIONS_CHANGED:
            extensionListeners[event.profileToken]?()
        case ACR_EVENT_NAVIGATION_POLICY:
            let surface = surface(event.surfaceToken)
            let request = event.requestID
            guard let surface, let hold = asyncNavigationHold else {
                _ = ACRResolveNavigationPolicy(request, surface == nil ? ACR_POLICY_CANCEL : ACR_POLICY_ALLOW)
                return
            }
            let url = event.url.flatMap(URL.init(string:))
            Task { @MainActor in
                let policy = await hold(surface, url)
                _ = ACRResolveNavigationPolicy(request, policy == .allow ? ACR_POLICY_ALLOW : ACR_POLICY_CANCEL)
            }
        case ACR_EVENT_COOKIE_RESULT:
            let result = (success: event.value == 1, value: event.detail)
            if let waiter = cookieWaiters.removeValue(forKey: event.requestID) { waiter.resume(returning: result) }
            else { cookieResults[event.requestID] = result }
        case ACR_EVENT_SHUTDOWN:
            trace?("shutdown", [:])
        case ACR_EVENT_FAILURE:
            if event.detail?.hasPrefix("quit-stalled") == true { quitStalls += 1 }
            if event.detail?.hasPrefix("quit-forced") == true { quitStalls += 1; quitForced = true }
            trace?("failure", ["detail": event.detail ?? ""])
        default:
            if event.kind == ACR_EVENT_CLOSED || event.kind == ACR_EVENT_CREATE_ABORTED {
                // Native lifetime ends here whether or not a Swift surface still exists.
                nativeOwners.removeValue(forKey: event.surfaceToken)?.engine?.nativeEnded(event.surfaceToken)
                trace?(event.kind == ACR_EVENT_CLOSED ? "native-closed" : "native-create-aborted",
                       ["token": String(event.surfaceToken), "reason": event.detail ?? ""])
            }
            guard let surface = surface(event.surfaceToken) else {
                // A browser outliving its Swift surface (released without dispose) is closed.
                if event.kind == ACR_EVENT_CREATED || event.kind == ACR_EVENT_CLOSE_REQUEST {
                    trace?("orphan-closed", ["token": String(event.surfaceToken)])
                    _ = ACRCloseSurface(event.surfaceToken)
                }
                // Permission or destination requests for a vanished surface must not hang.
                if event.kind == ACR_EVENT_PERMISSION { _ = ACRResolvePermission(event.requestID, ACR_PERMISSION_DENY) }
                if event.kind == ACR_EVENT_DOWNLOAD, event.requestID != 0 {
                    _ = ACRResolveDownloadDestination(event.requestID, nil)
                }
                // ABI 9 dialogs, credentials, choosers and menus never stay pending in CEF.
                ChromiumSurface.refuseUnanswered(event)
                return
            }
            surface.receive(event)
        }
    }
}

/// Owned copy of a borrowed `ACRNavigationInfo` (ABI 7).
struct ChromiumNavigationRequest {
    let url: String?
    let isMainFrame: Bool
    let userGesture: Bool
    let isRedirect: Bool
    let transitionType: UInt32
    let method: String?
    let hasBody: Bool

    init(_ info: ACRNavigationInfo) {
        url = info.url.map { String(cString: $0) }
        isMainFrame = info.is_main_frame != 0
        userGesture = info.user_gesture != 0
        isRedirect = info.is_redirect != 0
        transitionType = info.transition_type
        method = info.method.map { String(cString: $0).uppercased() }
        hasBody = info.has_body == 1
    }

    init(url: String?, isMainFrame: Bool, userGesture: Bool, isRedirect: Bool,
         transitionType: UInt32 = 0, method: String? = nil, hasBody: Bool = false) {
        self.url = url
        self.isMainFrame = isMainFrame
        self.userGesture = userGesture
        self.isRedirect = isRedirect
        self.transitionType = transitionType
        self.method = method
        self.hasBody = hasBody
    }
}

/// Copy of a borrowed `ACRKeyEvent` (ABI 7). The NSEvent stays valid for the callback only.
struct ChromiumKeyEvent {
    let surfaceToken: UInt64
    let keyID: UInt64
    let event: NSEvent?
    let modifiers: UInt32
    let windowsKeyCode: Int32
    let isEditableFieldFocused: Bool

    init(_ key: ACRKeyEvent) {
        surfaceToken = key.surface_token
        keyID = key.key_id
        event = key.ns_event.map { Unmanaged<NSEvent>.fromOpaque($0).takeUnretainedValue() }
        modifiers = key.modifiers
        windowsKeyCode = key.windows_key_code
        isEditableFieldFocused = key.focus_on_editable_field != 0
    }
}

/// Owned copy of a borrowed `ACREvent`.
struct ChromiumEvent {
    let kind: ACREventKind
    let surfaceToken: UInt64
    let profileToken: UInt64
    let browserID: Int32
    let value: Int32
    let flags: Int32
    let detailCode: Int32
    let requestID: UInt64
    let documentGeneration: UInt64
    let url: String?
    let title: String?
    let detail: String?
    let isMainFrame: Bool
    let userGesture: Int32
    let permissionMask: UInt32
    let downloadID: UInt32
    let downloadStatus: ACRDownloadStatus
    let downloadPaused: Bool
    let interruptReason: Int32
    let receivedBytes: Int64
    let totalBytes: Int64
    let downloadPath: String?
    let suggestedName: String?
    let payload: Data?
    let faviconPayloadWasRejected: Bool

    init(_ event: ACREvent) {
        kind = event.kind
        surfaceToken = event.surface_token
        profileToken = event.profile_token
        browserID = event.browser_id
        value = event.value
        flags = event.flags
        detailCode = event.detail_code
        requestID = event.request_id
        documentGeneration = event.document_generation
        url = event.url.map { String(cString: $0) }
        title = event.title.map { String(cString: $0) }
        detail = event.detail.map { String(cString: $0) }
        isMainFrame = event.is_main_frame != 0
        userGesture = event.user_gesture
        permissionMask = event.permission_mask
        downloadID = event.download_id
        downloadStatus = event.download_status
        downloadPaused = event.download_paused != 0
        interruptReason = event.download_interrupt_reason
        receivedBytes = event.received_bytes
        totalBytes = event.total_bytes
        downloadPath = event.download_path.map { String(cString: $0) }
        suggestedName = event.suggested_name.map { String(cString: $0) }
        faviconPayloadWasRejected = event.kind == ACR_EVENT_FAVICON && event.payload_size > BrowserFaviconImage.maximumBytes
        if faviconPayloadWasRejected {
            payload = nil
        } else {
            payload = event.payload.map { Data(bytes: $0, count: event.payload_size) }
        }
    }
}

public extension String {
    /// Decodes a NUL-terminated C buffer filled by the bridge.
    init(nulTerminated buffer: [CChar]) {
        self = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
