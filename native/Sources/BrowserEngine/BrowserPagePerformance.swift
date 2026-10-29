import Foundation

/// Browser-side page state. A missing snapshot means unavailable, never safe to discard.
public struct BrowserPageLifecycle: Sendable, Equatable {
    public enum State: Int32, Sendable { case running, frozen, discarded }
    public var playingMedia = false
    public var playingVideo = false
    public var audioContextRunning = false
    public var audible = false
    public var pictureInPicture = false
    /// Video, audio, mirror, tab, window, display, in bits 0 through 5.
    public var capturing: UInt32 = 0
    public var hadFormInteraction = false
    public var hadUserEdits = false
    public var webLock = false
    public var indexedDBLock = false
    public var webRTC = false
    public var state: State = .running
    /// Chromium CannotDiscardReason values, bits 0 through 29. The shell chooses its vetoes.
    public var cannotDiscardMask: UInt64 = 0
    public var footprintKB: UInt64 = 0
    public var rendererPID: Int32 = 0
    /// Opaque native document identity; separate from the surface's document generation.
    public var documentID: UInt64 = 0
    public init() {}
}

public struct BrowserPageLifecycleChange: Sendable, Equatable {
    public enum Event: Int32, Sendable { case changed, aboutToDiscard, discarded, closed }
    public enum Initiator: Int32, Sendable { case none, embedder, nativePolicy }
    public let event: Event
    public let initiator: Initiator
    public let state: BrowserPageLifecycle?
    public init(event: Event, initiator: Initiator = .none, state: BrowserPageLifecycle? = nil) {
        self.event = event; self.initiator = initiator; self.state = state
    }
}

public struct BrowserNativeCaptureRequest: Sendable, Equatable {
    /// Source rectangle in view DIP; all zero selects the viewport.
    public var x: Int32 = 0, y: Int32 = 0, width: Int32 = 0, height: Int32 = 0
    public var outputWidth: Int32, outputHeight: Int32
    public var timeoutMS: Int32
    public init(outputWidth: Int32, outputHeight: Int32, timeoutMS: Int32 = 1000) {
        self.outputWidth = outputWidth; self.outputHeight = outputHeight; self.timeoutMS = timeoutMS
    }
}

public struct BrowserNativeCapture: Sendable, Equatable {
    public enum Status: Int32, Sendable {
        case captured = 1, unavailable = -1, closed = -2, timedOut = -3, documentChanged = -4
    }
    public let status: Status
    public let width: Int32, height: Int32
    public let rowBytes: UInt32
    /// Owned premultiplied BGRA bytes in sRGB. Empty on failure. At most 4096 × 4096 × 4.
    public let pixels: Data
    public init(status: Status, width: Int32 = 0, height: Int32 = 0, rowBytes: UInt32 = 0, pixels: Data = Data()) {
        self.status = status; self.width = width; self.height = height; self.rowBytes = rowBytes; self.pixels = pixels
    }
}

public struct BrowserActivationFrame: Sendable, Equatable {
    public enum Status: Int32, Sendable {
        case submitted = 1, documentChanged, hidden, closed, timedOut
    }
    public let browserID: Int32
    public let activationID: UInt64
    public let documentID: UInt64
    public let status: Status
    /// Monotonic submission completion time; zero for other statuses. This is not scanout.
    public let submittedTicksUS: Int64
    public init(browserID: Int32, activationID: UInt64, documentID: UInt64, status: Status, submittedTicksUS: Int64 = 0) {
        self.browserID = browserID; self.activationID = activationID; self.documentID = documentID
        self.status = status; self.submittedTicksUS = submittedTicksUS
    }
}

@MainActor
public protocol BrowserPagePerformance: AnyObject {
    func lifecycle() -> BrowserPageLifecycle?
    func changes() -> AsyncStream<BrowserPageLifecycleChange>
    func capture(_ request: BrowserNativeCaptureRequest) async -> BrowserNativeCapture
    /// Call after host attachment, activation and final geometry. Supersedes an older request.
    func activationFrame(activationID: UInt64) async -> BrowserActivationFrame
}
