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
    /// Global diagnostic; unavailable outside a synthetic performance probe or before v13.
    func memoryDump() async -> BrowserMemoryDump
    func lifecycle() -> BrowserPageLifecycle?
    func changes() -> AsyncStream<BrowserPageLifecycleChange>
    func capture(_ request: BrowserNativeCaptureRequest) async -> BrowserNativeCapture
    /// Call after host attachment, activation and final geometry. Supersedes an older request.
    func activationFrame(activationID: UInt64) async -> BrowserActivationFrame
}

public extension BrowserPagePerformance {
    func memoryDump() async -> BrowserMemoryDump { .init(status: .unavailable) }
}

/// Background native memory attribution. Parent/child allocators overlap; do not sum them.
/// Metrics retain Chromium names (size/effective_size are bytes; counts are counts).
public struct BrowserMemoryDump: Sendable, Equatable {
    public enum Status: Int32, Sendable { case complete = 1, partial = 2, unavailable = -1 }
    public struct Allocator: Codable, Sendable, Equatable {
        public let metrics: [String: UInt64]
        public let children: [String: Allocator]
    }
    public struct Process: Codable, Sendable, Equatable {
        public enum Kind: Int, Sendable { case other, browser, renderer, gpu, utility, plugin, androidRuntime }
        public let pid: Int32
        public let processType: Int
        public var kind: Kind { Kind(rawValue: processType) ?? .other }
        public let privateFootprintKB: UInt64?
        /// Missing nodes/metrics mean unknown, rather than a measured zero.
        public let allocators: [String: Allocator]
    }
    public let status: Status
    /// Native RequestOutcome; zero is success. Partial results preserve their outcome.
    public let outcome: Int?
    public let processes: [Process]
    public init(status: Status, outcome: Int? = nil, processes: [Process] = []) {
        self.status = status; self.outcome = outcome; self.processes = processes
    }
    public static func decode(_ data: Data, status: Int32) -> Self {
        struct Payload: Decodable { let outcome: Int; let processes: [Process] }
        guard let status = Status(rawValue: status), status != .unavailable,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.processes.allSatisfy({ $0.pid > 0 }),
              status != .complete || payload.outcome == 0 else { return .init(status: .unavailable) }
        return .init(status: status, outcome: payload.outcome, processes: payload.processes)
    }
}
