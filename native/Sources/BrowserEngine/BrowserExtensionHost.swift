import AppKit
import BrowserCore

/// Effective action values for a tab, or the extension's default values. ARGB uses sRGB bytes.
public struct BrowserExtensionActionState: Sendable, Equatable, Codable {
    public var title: String
    public var badgeText: String
    public var badgeBackgroundColor: UInt32
    public var isEnabled: Bool
    public var iconPNGBase64: String?
    public init(title: String, badgeText: String, badgeBackgroundColor: UInt32,
                isEnabled: Bool, iconPNGBase64: String? = nil) {
        self.title = title; self.badgeText = badgeText; self.badgeBackgroundColor = badgeBackgroundColor
        self.isEnabled = isEnabled; self.iconPNGBase64 = iconPNGBase64
    }
}

/// A Chrome Web Store compatible extension visible in one profile.
public struct BrowserExtensionSummary: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var version: String
    public var isEnabled: Bool
    public var hasAction: Bool
    public var isPinned: Bool?
    public var iconPNGBase64: String?
    /// Global action badge when supplied by the engine; nil means unavailable, never a count of zero.
    public var actionState: BrowserExtensionActionState?
    public var defaultActionState: BrowserExtensionActionState?
    public var actionBadgeText: String?

    public init(id: String, name: String, version: String, isEnabled: Bool, hasAction: Bool,
                isPinned: Bool? = nil, iconPNGBase64: String? = nil, actionBadgeText: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.isEnabled = isEnabled
        self.hasAction = hasAction
        self.isPinned = isPinned
        self.iconPNGBase64 = iconPNGBase64
        self.actionBadgeText = actionBadgeText
    }
}

/// Manager-only engine service; no inventory, mutation, action or Store capability is implied.
@MainActor
public protocol BrowserExtensionManagement: AnyObject {
    /// Opens only the genuine manager in the exact originating live surface/profile.
    func openManagement(on surface: any BrowserEngineSurface) throws
    /// (EXT-OUTCOME-R2) The genuine manager's details of one installed extension (permissions,
    /// site access, options, source), same authority as `openManagement`. Default: unsupported.
    func openDetails(extensionID: String, on surface: any BrowserEngineSurface) throws
    /// (EXT-OUTCOME-R2) The genuine manager's keyboard-shortcut page. Default: unsupported.
    func openShortcuts(on surface: any BrowserEngineSurface) throws
}

public extension BrowserExtensionManagement {
    func openDetails(extensionID: String, on surface: any BrowserEngineSurface) throws {
        throw BrowserEngineError.unsupportedOperation
    }
    func openShortcuts(on surface: any BrowserEngineSurface) throws {
        throw BrowserEngineError.unsupportedOperation
    }
}

/// Engine-owned extension services. Individual services may be unavailable.
/// The final contract must let extensions see the shell's own windows and tabs as real
/// `chrome.windows`/`chrome.tabs` objects, host action popups and side panels in shell views,
/// route permission and install prompts to native UI, and keep everything per profile. Window
/// and tab identities follow each surface's `BrowserSurfacePlacement`. See
/// `docs/native-port/engine-decision-2026-10-25.md`. Callers must treat a nil host as
/// "native inventory/actions unavailable", never emulate extension APIs with page scripts.
@MainActor
public protocol BrowserExtensionHost: BrowserExtensionManagement {
    func installedExtensions(on surface: any BrowserEngineSurface) throws -> [BrowserExtensionSummary]
    func installedExtensions(in profileID: ProfileID) throws -> [BrowserExtensionSummary]
    func observeChanges(in profileID: ProfileID, handler: @escaping () -> Void) throws -> BrowserExtensionObservation
    var onExtensionsChange: ((ProfileID) -> Void)? { get set }
    /// Runs the extension action for a surface, presenting its popup anchored to `anchor`.
    func performAction(extensionID: String, on surface: any BrowserEngineSurface, anchor: NSView) throws
    func setEnabled(_ enabled: Bool, extensionID: String, in profileID: ProfileID) throws
    /// Call only after native user confirmation. Acceptance is not data-removal completion.
    func remove(extensionID: String, in profileID: ProfileID) throws
    /// True only when the backend can run genuine actions, including native anchored popups.
    var supportsActions: Bool { get }
    var supportsPinning: Bool { get }
    func setPinned(_ pinned: Bool, extensionID: String, in profileID: ProfileID) throws
    func setActionAnchor(_ anchor: NSView, on surface: any BrowserEngineSurface)
}

/// A separately owned subscription; controllers cancel when their presentation closes.
@MainActor
public final class BrowserExtensionObservation {
    private var handler: (() -> Void)?
    private var cancellation: (() -> Void)?
    init(handler: @escaping () -> Void, cancellation: @escaping () -> Void) {
        self.handler = handler
        self.cancellation = cancellation
    }
    fileprivate func deliver() { handler?() }
    public func cancel() {
        let callback = cancellation
        handler = nil
        cancellation = nil
        callback?()
    }
}

/// Service-owned fanout. The service weakly holds each subscription, so even
/// omitted close teardown cannot retain a closed presentation or its handler.
@MainActor
public final class BrowserExtensionChangeHub {
    private final class Entry {
        let profile: ProfileID
        weak var observation: BrowserExtensionObservation?
        init(_ profile: ProfileID, _ observation: BrowserExtensionObservation) {
            self.profile = profile; self.observation = observation
        }
    }
    private var observers: [UUID: Entry] = [:]
    public init() {}
    public func observe(in profileID: ProfileID, handler: @escaping () -> Void) -> BrowserExtensionObservation {
        observers = observers.filter { $0.value.observation != nil }
        let id = UUID()
        let observation = BrowserExtensionObservation(handler: handler) { [weak self] in self?.observers[id] = nil }
        observers[id] = Entry(profileID, observation)
        return observation
    }
    public func emit(_ profileID: ProfileID) {
        for (id, entry) in observers where entry.profile == profileID {
            guard let token = entry.observation else { observers[id] = nil; continue }
            guard observers[id]?.observation === token else { continue }
            token.deliver()
        }
    }
    public func remove(in profileID: ProfileID? = nil) {
        let cancelled = observers.filter { profileID == nil || $0.value.profile == profileID }
        for (id, _) in cancelled { observers[id] = nil }
        for entry in cancelled.values { entry.observation?.cancel() }
    }
}

public extension BrowserExtensionHost {
    func installedExtensions(on surface: any BrowserEngineSurface) throws -> [BrowserExtensionSummary] {
        try installedExtensions(in: surface.profileID)
    }
    var supportsPinning: Bool { false }
    func setPinned(_ pinned: Bool, extensionID: String, in profileID: ProfileID) throws {
        throw BrowserEngineError.unsupportedOperation
    }
    func setActionAnchor(_ anchor: NSView, on surface: any BrowserEngineSurface) {}
    func observeChanges(in profileID: ProfileID, handler: @escaping () -> Void) throws -> BrowserExtensionObservation {
        throw BrowserEngineError.unsupportedOperation
    }
}
