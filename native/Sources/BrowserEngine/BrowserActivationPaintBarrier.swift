import AppKit

/// Submission readiness for an attached live host. Failure leaves the card's timeout in charge.
@MainActor
public enum BrowserActivationPaintBarrier {
    public static func wait(performance: any BrowserPagePerformance, host: NSView,
                            browserID: Int32, activationID: UInt64,
                            isCurrent: @MainActor () -> Bool) async -> Bool {
        guard !Task.isCancelled, isCurrent(), activationID != 0,
              let window = host.window, !host.isHiddenOrHasHiddenAncestor,
              host.bounds.width > 0, host.bounds.height > 0,
              let document = performance.lifecycle(), document.documentID != 0,
              document.state == .running else { return false }
        let parent = host.superview
        let bounds = host.bounds
        let frame = host.convert(bounds, to: nil)
        let scale = window.backingScaleFactor
        let result = await performance.activationFrame(activationID: activationID)
        let currentDocument = performance.lifecycle()
        return !Task.isCancelled && isCurrent()
            && host.window === window && host.superview === parent
            && !host.isHiddenOrHasHiddenAncestor && host.bounds == bounds
            && host.convert(host.bounds, to: nil) == frame && window.backingScaleFactor == scale
            && result.status == .submitted && result.activationID == activationID
            && result.browserID == browserID && result.documentID == document.documentID
            && result.submittedTicksUS > 0
            && currentDocument?.documentID == document.documentID
            && currentDocument?.state == .running
    }
}
