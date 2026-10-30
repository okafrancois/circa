import AppKit
import OrbitChromiumBridge
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation


/// The identity of a surface as extension APIs see it.
public struct ChromiumTabIdentity: Equatable, Sendable {
    /// Extension `tabId`, -1 when the surface is not a tab (Alloy).
    public let tabID: Int32
    /// Extension `windowId` (the logical Browser's `SessionID`), -1 when none.
    public let windowID: Int32
    /// Index in the logical Browser's tab strip, -1 when none.
    public let index: Int32
    public let isActive: Bool
    /// True for a tab surface (hosted Chrome style).
    public let isHosted: Bool
    /// Engine token of the shell window, 0 when none.
    public let windowToken: UInt64
}

/// A shell window registered with the patched engine. Key, resize and move notifications of the
/// `NSWindow` are forwarded (`windows.onFocusChanged`, `windows.onBoundsChanged`); the window is
/// unregistered when it closes or when `close()` is called. Close its tab surfaces first.
@MainActor
public final class ChromiumEngineWindow {
    public let token: UInt64
    public private(set) weak var window: NSWindow?
    public private(set) var isClosed = false
    private var observers: [NSObjectProtocol] = []

    init?(token: UInt64, window: NSWindow) {
        guard ACRCreateWindow(token, Unmanaged.passUnretained(window).toOpaque(), ACR_WINDOW_NORMAL) == 1 else {
            return nil
        }
        self.token = token
        self.window = window
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                let name = note.name
                MainActor.assumeIsolated { self?.windowNotification(name) }
            })
        }
    }

    private func windowNotification(_ name: Notification.Name) {
        guard !isClosed else { return }
        switch name {
        case NSWindow.didBecomeKeyNotification: _ = ACRWindowKeyChanged(token, 1)
        case NSWindow.didResignKeyNotification: _ = ACRWindowKeyChanged(token, 0)
        case NSWindow.willCloseNotification: close(reason: "nswindow-will-close")
        default: _ = ACRWindowBoundsChanged(token)
        }
    }

    /// Live logical Browsers of this window (one per profile with at least one tab).
    public var logicalBrowserCount: Int { Int(ACRWindowBrowserCount(token)) }

    public func close() { close(reason: "explicit") }

    func close(reason: String) {
        guard !isClosed else { return }
        ChromiumRuntime.shared.trace?("hosted-window-close", ["token": String(token), "reason": reason])
        isClosed = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        _ = ACRCloseWindow(token)
    }
}

public extension ChromiumBrowserEngine {
    /// Version of the patched CEF side API, 0 on the stock SDK.
    var patchLevel: UInt32 { ACRPatchLevel() }
    /// Tab surfaces (hosted Chrome style) are available.
    var supportsTabSurfaces: Bool { patchLevel >= 1 }

    /// Registers a shell window; nil on the stock SDK.
    func makeWindow(for window: NSWindow) -> ChromiumEngineWindow? {
        guard supportsTabSurfaces, let engineWindow = ChromiumEngineWindow(token: runtime.makeToken(), window: window)
        else { return nil }
        runtime.setWindowOwner(self, for: engineWindow.token)
        return engineWindow
    }

    /// Creates a Chrome-style tab surface in the logical Browser of (`window`, profile), at
    /// `index` (appended when nil), with no URL. Same readiness contract as `makeSurface`; the
    /// browser exists inside the call when the profile is ready. Nil on the stock SDK or for a
    /// closed window.
    func makeTabSurface(
        profileID: ProfileID,
        in window: ChromiumEngineWindow,
        at index: Int? = nil,
        delegate: any BrowserEngineSurfaceDelegate<ChromiumSurface>
    ) -> ChromiumSurface? {
        guard supportsTabSurfaces, !window.isClosed, !isShutDown else { return nil }
        let surface = makePendingSurface(profileID: profileID)
        surface.delegate = delegate
        surface.createTabBrowser(window: window.token, index: index.map { Int32(clamping: $0) } ?? -1)
        return surface
    }
}

public extension ChromiumSurface {
    /// Extension identity (patched CEF); nil on the stock SDK or before the browser exists.
    var tabIdentity: ChromiumTabIdentity? {
        guard isBrowserCreated, !isDisposed else { return nil }
        var info = ACRTabInfo()
        info.struct_size = UInt32(MemoryLayout<ACRTabInfo>.size)
        guard ACRGetTabInfo(token, &info) == 1 else { return nil }
        return ChromiumTabIdentity(tabID: info.tab_id, windowID: info.window_id, index: info.index,
                                   isActive: info.active == 1, isHosted: info.hosted == 1,
                                   windowToken: info.window_token)
    }

    /// The engine's content view inside `hostView` (Alloy: CEF's host view; tab surface: the
    /// WebContents view). Laboratory introspection.
    var engineContentView: NSView? {
        guard isBrowserCreated, !isDisposed, let view = ACRBrowserNSView(token) else { return nil }
        return Unmanaged<NSView>.fromOpaque(view).takeUnretainedValue()
    }

    /// Native accessibility tree on/off (nil restores the command-line default). Works on both
    /// builds; the shell turns it on when an assistive technology is active.
    @discardableResult
    func setNativeAccessibility(_ enabled: Bool?) -> Bool {
        guard isBrowserCreated, !isDisposed else { return false }
        return ACRSetAccessibility(token, enabled.map { $0 ? 1 : 0 } ?? -1) == 1
    }

    /// Makes this tab surface the active tab of its logical Browser (`tabs.onActivated`).
    @discardableResult
    func activateTab() -> Bool {
        guard isBrowserCreated, !isDisposed else {
            BrowserSidebarInputDiagnostics.record("native-activation", tab: sidebarInputTabID,
                reason: isDisposed ? "surface-disposed" : "browser-missing")
            return false
        }
        if let id = sidebarInputTabID {
            return id.rawValue.uuidString.withCString { ACRActivateSidebarSurface(token, $0) == 1 }
        }
        return ACRActivateSurface(token) == 1
    }

    /// Moves the content view of a tab surface under `view` (same window). Alloy surfaces are
    /// moved by moving `hostView` instead.
    @discardableResult
    func attachContent(to view: NSView) -> Bool {
        guard isBrowserCreated, !isDisposed else { return false }
        return ACRAttachSurfaceView(token, Unmanaged.passUnretained(view).toOpaque()) == 1
    }
}
