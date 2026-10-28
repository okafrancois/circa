import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// Explicitly suspended snapshots exercise completion races without WebKit or a keychain.
@MainActor
final class SwitcherSnapshotSurface: BrowserEngineSurface {
    let profileID = ProfileID()
    let hostView = NSView()
    var isDisposed = false
    weak var delegate: (any BrowserEngineSurfaceDelegate<SwitcherSnapshotSurface>)?
    var placement = BrowserSurfacePlacement.detached
    var onChange: (() -> Void)?
    var onDispose: (() -> Void)?
    var findDocumentGeneration: UInt64 = 1
    var pageZoom: Double = 1
    var currentURL: URL? { nil }
    var navigationState = BrowserNavigationState()
    var requests: [BrowserSnapshotRequest] = []
    var continuations: [CheckedContinuation<BrowserSurfaceSnapshot, any Error>] = []
    func navigate(to url: URL) {}
    func goBack() -> URL? { nil }
    func goForward() -> URL? { nil }
    func reload() {}
    func stopLoading() {}
    func cancelStoppedNavigationTracking() {}
    func focusDocument() -> Bool { false }
    func performZoom(_ command: BrowserPageZoomCommand) {}
    func performFind(_ request: BrowserFindRequest, update: @escaping @MainActor (BrowserFindUpdate) -> Void) {}
    func stopFinding(clearSelection: Bool) {}
    func captureSnapshot(_ request: BrowserSnapshotRequest) async throws -> BrowserSurfaceSnapshot {
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func requestMediaState() async -> BrowserMediaState { .init() }
    func setAudioMuted(_ muted: Bool) throws {}
    func dispose() { isDisposed = true; onDispose?() }
    func complete(generation: UInt64, blank: Bool = false) {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !blank {
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 2))
            context.setFillColor(NSColor.blue.cgColor)
            context.fill(CGRect(x: 1, y: 0, width: 1, height: 2))
        }
        continuations.removeFirst().resume(returning: .init(image: context.makeImage()!, documentGeneration: generation))
    }
}
