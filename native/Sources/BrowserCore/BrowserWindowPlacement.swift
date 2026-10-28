import Foundation

/// Optional native window state. Older session documents omit it and use the default layout.
public struct BrowserWindowPlacement: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let sidebarWidth: Double

    public init(x: Double, y: Double, width: Double, height: Double, sidebarWidth: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.sidebarWidth = sidebarWidth
    }

    public var isUsable: Bool {
        [x, y, width, height, sidebarWidth].allSatisfy(\.isFinite)
            && abs(x) <= 100_000 && abs(y) <= 100_000
            && width >= 600 && width <= 100_000 && height >= 400 && height <= 100_000
            && sidebarWidth >= 164 && sidebarWidth <= 500
    }
}
