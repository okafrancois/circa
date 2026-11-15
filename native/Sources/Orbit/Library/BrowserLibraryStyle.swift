import AppKit

@MainActor
enum BrowserLibraryStyle {
    /// Resolve against the containing Library, never a process-wide active Space. The weak
    /// view also lets recycled rows and fields created before attachment inherit their window.
    static func foreground(in view: NSView, secondary: Bool = false) -> NSColor {
        NSColor(name: nil) { [weak view] appearance in
            MainActor.assumeIsolated {
                var ancestor = view
                while let current = ancestor {
                    if let library = current as? BrowserLibraryView {
                        let ink = secondary ? library.accent.sidebarSecondaryText : library.accent.sidebarText
                        return ink.resolved(for: appearance)
                    }
                    ancestor = current.superview
                }
                // Unthemed chrome keeps its daylight ink, independent of system dark mode.
                return NSColor(srgbRed: 0, green: 0, blue: 0.092, alpha: 1)
            }
        }
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
