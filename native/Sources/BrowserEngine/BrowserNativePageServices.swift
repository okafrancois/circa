import Foundation

/// Native security information for the visible page, including error/interstitial documents.
/// `level` is Chromium's stable value: 0 neutral, 3 secure, 5 dangerous, 6 warning.
public struct BrowserPageSecurityState: Codable, Sendable, Equatable {
    public let level: Int
    public let certificateStatus: UInt32
    public let certificateError: Bool
    public let displayedMixedContent: Bool
    public let ranMixedContent: Bool
    public let displayedCertificateErrorContent: Bool
    public let ranCertificateErrorContent: Bool
    public let interstitial: Bool
}

public struct BrowserPageFullscreenChange: Sendable, Equatable {
    public let entered: Bool
    /// Serialized requesting frame origin. Opaque origins are the string "null".
    public let origin: String
    public init(entered: Bool, origin: String) { self.entered = entered; self.origin = origin }
}

public struct BrowserNavigationEntry: Codable, Sendable, Equatable {
    public let index: Int
    public let url: URL
    public let title: String
}
public struct BrowserNavigationHistory: Codable, Sendable, Equatable {
    public let currentIndex: Int
    public let entries: [BrowserNavigationEntry]
}

public enum BrowserSecuritySchemeDisplay: Int32, Sendable {
    case show = 0, omitHTTPAndHTTPS = 1, omitCryptographic = 2
}
public enum BrowserMediaAction: Int32, Sendable {
    case play = 0, pause = 1, seek = 2, next = 3, previous = 4
}
public struct BrowserMediaSessionState: Codable, Sendable, Equatable {
    public let title: String
    public let artist: String
    public let album: String
    /// Native playback enum: 0 paused, 1 playing. Session state: 0 active,
    /// 1 ducking, 2 suspended, 3 inactive. Preserve unknown future values.
    public let playbackState: Int
    public let sessionState: Int
    public let artwork: [URL]
    /// Native MediaSessionAction values, preserved without remapping.
    public let actions: [Int]
    /// Seconds at snapshot time. Missing position/duration remains unknown.
    public let position: Double?
    public let duration: Double?
    public let playbackRate: Double?
}

/// Native snapshots, UI-thread streams and explicit diagnostics never require a renderer script.
/// A closed surface returns nil/refused and finishes its streams. Callers choose when
/// to observe; no production polling is installed by the engine wrapper.
@MainActor
public protocol BrowserNativePageServices: AnyObject {
    var supportsTaskManager: Bool { get }
    var supportsTracing: Bool { get }
    @discardableResult func openTaskManager() -> Bool
    /// Process-wide diagnostic recording. One persistent profile owns the session.
    /// Await begin before end; stop on a live surface in that profile before engine shutdown.
    /// No implicit recording.
    func beginTracing(categories: String) async -> Bool
    /// A new file below the persistent profile's data root, with an existing parent.
    /// True means the native completion callback confirmed a written file.
    func endTracing(to file: URL) async -> Bool
    func securityState() -> BrowserPageSecurityState?
    func securityChanges() -> AsyncStream<BrowserPageSecurityState>
    func fullscreenChanges() -> AsyncStream<BrowserPageFullscreenChange>
    func committedURL() -> URL?
    /// Display text only: never parse it or use it as a navigation destination.
    func securityDisplay(for url: URL, scheme: BrowserSecuritySchemeDisplay) -> String?
    func navigationHistory() -> BrowserNavigationHistory?
    @discardableResult func goToEntry(index: Int) -> Bool
    func mediaState() -> BrowserMediaSessionState?
    func mediaChanges() -> AsyncStream<BrowserMediaSessionState>
    @discardableResult func mediaAction(_ action: BrowserMediaAction, seconds: Double) -> Bool
}

public extension BrowserNativePageServices {
    var supportsTaskManager: Bool { false }
    var supportsTracing: Bool { false }
    func openTaskManager() -> Bool { false }
    func beginTracing(categories: String) async -> Bool { false }
    func endTracing(to file: URL) async -> Bool { false }
}
