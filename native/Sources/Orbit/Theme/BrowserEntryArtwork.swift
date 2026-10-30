import AppKit

/// Small outline artwork in a 28 pt, top-left coordinate system.
@MainActor
enum BrowserEntryArtwork {
    private static func path(_ points: [NSPoint], closed: Bool = false) -> NSBezierPath {
        let path = NSBezierPath()
        if let first = points.first { path.move(to: first) }
        for point in points.dropFirst() { path.line(to: point) }
        if closed { path.close() }
        path.lineWidth = 1.7
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    private static func stroke(_ points: [(CGFloat, CGFloat)], closed: Bool = false) {
        path(points.map { NSPoint(x: $0.0, y: $0.1) }, closed: closed).stroke()
    }

    private static func star(x: CGFloat, y: CGFloat, radius: CGFloat) {
        path([NSPoint(x: x, y: y - radius), NSPoint(x: x + radius * 0.24, y: y - radius * 0.24),
              NSPoint(x: x + radius, y: y), NSPoint(x: x + radius * 0.24, y: y + radius * 0.24),
              NSPoint(x: x, y: y + radius), NSPoint(x: x - radius * 0.24, y: y + radius * 0.24),
              NSPoint(x: x - radius, y: y), NSPoint(x: x - radius * 0.24, y: y - radius * 0.24)], closed: true).fill()
    }

    /// The same angled brush is used in the small action and the destination badge.
    private static func brush(fill: NSColor?) {
        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: 8.9, y: 14.9))
        handle.line(to: NSPoint(x: 4.2, y: 18.4))
        handle.curve(to: NSPoint(x: 2.9, y: 23.9), controlPoint1: NSPoint(x: 0.6, y: 20.3), controlPoint2: NSPoint(x: 0.4, y: 22.7))
        handle.curve(to: NSPoint(x: 6.9, y: 23.0), controlPoint1: NSPoint(x: 4.2, y: 25.4), controlPoint2: NSPoint(x: 5.8, y: 24.7))
        handle.line(to: NSPoint(x: 10.9, y: 17.7))
        handle.line(to: NSPoint(x: 13.4, y: 20.0))
        handle.curve(to: NSPoint(x: 15.5, y: 19.8), controlPoint1: NSPoint(x: 14.2, y: 20.9), controlPoint2: NSPoint(x: 14.9, y: 20.7))
        handle.line(to: NSPoint(x: 16.7, y: 18.3))
        handle.curve(to: NSPoint(x: 16.5, y: 16.5), controlPoint1: NSPoint(x: 17.3, y: 17.6), controlPoint2: NSPoint(x: 17.3, y: 17.2))
        handle.line(to: NSPoint(x: 9.2, y: 9.1))
        handle.curve(to: NSPoint(x: 7.3, y: 9.0), controlPoint1: NSPoint(x: 8.5, y: 8.4), controlPoint2: NSPoint(x: 8.0, y: 8.4))
        handle.line(to: NSPoint(x: 5.8, y: 10.6))
        handle.curve(to: NSPoint(x: 5.9, y: 12.4), controlPoint1: NSPoint(x: 5.1, y: 11.2), controlPoint2: NSPoint(x: 5.2, y: 11.8))
        handle.close()
        if let fill {
            NSGraphicsContext.saveGraphicsState()
            fill.setFill(); handle.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        handle.lineWidth = 1.7; handle.lineCapStyle = .round; handle.lineJoinStyle = .round
        handle.stroke()
        let head = path([.init(x: 8.7, y: 9.0), .init(x: 10.8, y: 2.8), .init(x: 11.7, y: 2.5),
                         .init(x: 20.0, y: 10.3), .init(x: 20.1, y: 11.4), .init(x: 15.9, y: 15.9)], closed: false)
        head.stroke()
        stroke([(17, 7.6), (15.5, 10.2), (18.8, 8.9)])
        NSBezierPath(ovalIn: NSRect(x: 3.6, y: 21.1, width: 1.7, height: 1.7)).fill()
    }

    static func drawLibrary(_ category: BrowserLibraryCategory, in rect: NSRect, foreground: NSColor, selected: Bool, flipped: Bool) {
        let name: String
        switch category {
        case .media: name = "photo.on.rectangle"
        case .downloads: name = "arrow.down.circle"
        case .spaces: name = "rectangle.on.rectangle"
        case .boosts: name = "paintbrush.pointed.fill"
        case .archive: name = "archivebox"
        case .history: name = "clock"
        }
        OrbitIcon.draw(OrbitIcon.image(sfName: name, pointSize: rect.width), in: rect, tint: foreground)
    }

    static var boostAction: NSImage {
        let image = NSImage(size: NSSize(width: 19, height: 19), flipped: true) { _ in
            let transform = NSAffineTransform()
            transform.scaleX(by: 19 / 24, yBy: 19 / 28)
            transform.translateX(by: 1, yBy: 2)
            transform.concat()
            NSColor.black.setStroke(); NSColor.black.setFill()
            brush(fill: nil)
            star(x: 3.2, y: 4.2, radius: 3.3)
            return true
        }
        image.isTemplate = true
        return image
    }

    static var fullPageCapture: NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 19), flipped: true) { _ in
            NSColor.black.setStroke()
            stroke([(5.5, 1.5), (2.5, 1.5), (1.5, 2.5), (1.5, 5.5)])
            stroke([(10.5, 1.5), (13.5, 1.5), (14.5, 2.5), (14.5, 5.5)])
            stroke([(1.5, 13.5), (1.5, 16.5), (2.5, 17.5), (5.5, 17.5)])
            stroke([(10.5, 17.5), (13.5, 17.5), (14.5, 16.5), (14.5, 13.5)])
            stroke([(4.8, 7), (11.2, 7)])
            stroke([(4.8, 9.7), (11.2, 9.7)])
            stroke([(4.8, 12.4), (9.3, 12.4)])
            return true
        }
        image.isTemplate = true
        return image
    }
}
