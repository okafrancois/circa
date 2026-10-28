import AppKit

public struct BrowserLinkGeometry: Sendable {
    public let bounds: NSRect
    public let cornerRadius: CGFloat

    public init(bounds: NSRect, cornerRadius: CGFloat) {
        self.bounds = bounds
        self.cornerRadius = cornerRadius
    }
}

/// Geometry of a user-activated link in the visible document, in flipped viewport points.
/// Engines return geometry only; no page object or script bridge is exposed to the shell.
@MainActor
public protocol BrowserLinkGeometrySource: AnyObject {
    func linkGeometry(at point: NSPoint) async -> BrowserLinkGeometry?
}
