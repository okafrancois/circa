import AppKit

/// Thin vector glyphs of the sidebar toolbar: back/forward chevrons, the circular reload arrow and the
/// sidebar toggle. The chevrons and the toggle are exactly their ink box (stroke included), so a frame
/// centred on the glyph places the visible edge where the geometry expects it. Images are template and
/// redraw at the backing scale; sizes stay on the 2x pixel grid.
@MainActor
enum OrbitToolbarGlyphs {
    /// 1.05 pt round-capped stroke shared by every toolbar glyph.
    nonisolated static let lineWidth: CGFloat = 1.05
    /// Ink box of the full-size chevrons and of the reload arrow.
    nonisolated static let chevronSize = NSSize(width: 5.5, height: 9.5)
    nonisolated static let reloadSize = NSSize(width: 10.5, height: 12)
    nonisolated private static let reloadRadius: CGFloat = 4.6
    nonisolated private static let reloadHeadArm: CGFloat = 2.8
    nonisolated static let sidebarToggleSize = NSSize(width: OrbitTokens.Metrics.Toolbar.sidebarToggleGlyphWidth, height: 11.5)
    /// The compact toolbar keeps the same silhouette, smaller.
    nonisolated static let compactChevronSize = NSSize(width: 4.5, height: 8)

    static let back = chevron(pointingLeft: true, size: chevronSize)
    static let forward = chevron(pointingLeft: false, size: chevronSize)
    static let backCompact = chevron(pointingLeft: true, size: compactChevronSize)
    static let forwardCompact = chevron(pointingLeft: false, size: compactChevronSize)
    static let reload = image(size: reloadSize) { rect in
        let radius = reloadRadius
        let center = NSPoint(x: rect.midX, y: rect.minY + lineWidth / 2 + radius)
        // Open circle running clockwise from the right side down, round and up into the arrowhead.
        let start: CGFloat = 14, end: CGFloat = 68
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        stroke(arc)
        let angle = end * .pi / 180
        let tip = NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        // Arms fold back along the tangent of the clockwise motion, 45° either side.
        let backward = atan2(cos(angle), -sin(angle))
        let head = NSBezierPath()
        head.move(to: NSPoint(x: tip.x + reloadHeadArm * cos(backward + .pi / 4),
                              y: tip.y + reloadHeadArm * sin(backward + .pi / 4)))
        head.line(to: tip)
        head.line(to: NSPoint(x: tip.x + reloadHeadArm * cos(backward - .pi / 4),
                              y: tip.y + reloadHeadArm * sin(backward - .pi / 4)))
        stroke(head)
    }
    static let sidebarToggle = image(size: sidebarToggleSize) { rect in
        let frame = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        stroke(NSBezierPath(roundedRect: frame, xRadius: 2.6, yRadius: 2.6))
        let divider = NSBezierPath()
        let x = frame.minX + 5
        divider.move(to: NSPoint(x: x, y: frame.minY))
        divider.line(to: NSPoint(x: x, y: frame.maxY))
        stroke(divider)
    }

    private static func chevron(pointingLeft: Bool, size: NSSize) -> NSImage {
        return image(size: size) { rect in
            let inset = lineWidth / 2
            let path = NSBezierPath()
            let outer = pointingLeft ? rect.maxX - inset : rect.minX + inset
            let point = pointingLeft ? rect.minX + inset : rect.maxX - inset
            path.move(to: NSPoint(x: outer, y: rect.maxY - inset))
            path.line(to: NSPoint(x: point, y: rect.midY))
            path.line(to: NSPoint(x: outer, y: rect.minY + inset))
            stroke(path)
        }
    }

    nonisolated private static func stroke(_ path: NSBezierPath) {
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.black.setStroke()
        path.stroke()
    }

    private static func image(size: NSSize, draw: @escaping @Sendable (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in draw(rect); return true }
        image.isTemplate = true
        return image
    }
}
