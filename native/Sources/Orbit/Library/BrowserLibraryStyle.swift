import AppKit

@MainActor
enum BrowserLibraryStyle {
    static let foreground = NSColor(name: "Library.foreground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .white : NSColor(srgbRed: 0, green: 0, blue: 0.092, alpha: 1)
    }

    static let railTint = NSColor.white.withAlphaComponent(0.025)

    /// Scrolling remains native; there is no reserved gutter or transient scroller.
    static func configure(_ scroll: NSScrollView) {
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
    }
}
