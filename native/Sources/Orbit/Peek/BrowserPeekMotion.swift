import AppKit

/// ModalV2HostView.performExpandedAnimation .
/// These paths use CASpringAnimation through , not Motion's CoreVideo clock.
enum BrowserPeekMotion {
    static let present = OrbitTokens.Spring(response: 0.245, dampingFraction: 0.865)
    // Full-window entry: approximately 0.35 s through its small overshoot and settling.
    static let libraryPresent = OrbitTokens.Spring(response: 0.253, dampingFraction: 0.85)
    static func librarySource(in bounds: NSRect) -> NSRect {
        let width = bounds.width * widthFraction * 0.001
        let height = max(0, bounds.height - verticalInset * 2) * 0.62 * 0.001
        return NSRect(x: bounds.minX + bounds.width * 0.352 - width / 2,
                      y: bounds.minY + bounds.height * 0.44 - height / 2, width: width, height: height)
    }
    static let dismiss = OrbitTokens.Spring(response: 0.225, dampingFraction: 0.895)
    static let promote = OrbitTokens.Spring(response: 0.18, dampingFraction: 0.885)
    static let sourcePresent = OrbitTokens.Spring(response: 0.245 * 0.5, dampingFraction: 0.95)
    static let sourceDismiss = OrbitTokens.Spring(response: 0.225 * 0.65, dampingFraction: 0.95)
    static let sourceDismissDelay = 0.225 * 0.35
    // WindowContentViewController's dim path selects ModalConstants.dismiss for entry,
    // and ModalConstants.present for restoration .
    static let dim = dismiss
    static let undim = present
    static let backgroundOpacity: CGFloat = 0.3
    static let backgroundInset: CGFloat = 9
    static let widthFraction: CGFloat = 0.8
    static let verticalInset: CGFloat = 12
    static func pointerFallback(at point: NSPoint) -> NSRect {
        NSRect(x: point.x - 60, y: point.y - 10, width: 120, height: 20)
    }

    static func sourceGeometry(source: NSRect, card: NSRect) -> (scale: CGFloat, height: CGFloat) {
        let scale = max(0.001, source.width / max(1, card.width))
        return (scale, max(0, source.height) / scale)
    }
}
