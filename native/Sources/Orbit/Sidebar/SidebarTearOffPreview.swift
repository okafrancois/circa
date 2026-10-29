import AppKit
import QuartzCore

/// Finite folding geometry for the desktop drag image. The pointer stays twelve points from
/// the leading edge, vertically centred, as the row folds into the document thumbnail.
enum SidebarTearOffPreview {
    static let duration: TimeInterval = 0.8
    static let size = NSSize(width: 228, height: 214)
    private static let samples: [(Double, CGFloat, CGFloat)] = [
        (0, 66, 250), (0.1, 104, 168), (0.2, 148, 65), (0.3, 176, 24),
        (0.4, 194, 80), (0.5, 220, 168), (0.6, 228, 210), (0.7, 228, 214), (0.8, 228, 214)
    ]

    static func tile(title: String, icon: NSImage?) -> NSImage {
        NSImage(size: NSSize(width: 66, height: 250), flipped: true) { rect in
            NSColor.white.withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24).fill()
            icon?.draw(in: NSRect(x: 26, y: 82, width: 14, height: 14), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            (title as NSString).draw(in: NSRect(x: 4, y: 120, width: 58, height: 78),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                 .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
            return true
        }
    }

    static func render(document: NSImage, row: NSImage, tile: NSImage, elapsed: TimeInterval, sourceWidth: CGFloat, background: NSColor) -> NSImage {
        let time = min(max(0, elapsed), duration)
        let right = samples.firstIndex { $0.0 >= time } ?? samples.count - 1
        let a = samples[max(0, right - 1)], b = samples[right]
        let t = a.0 == b.0 ? 1 : CGFloat((time - a.0) / (b.0 - a.0))
        let size = NSSize(width: a.1 + (b.1 - a.1) * t, height: a.2 + (b.2 - a.2) * t)
        return NSImage(size: size, flipped: false) { rect in
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: time < 0.3 ? min(26, rect.height / 2) : 7, yRadius: time < 0.3 ? min(26, rect.height / 2) : 7)
            NSColor.white.withAlphaComponent(0.8).setFill()
            border.fill()
            border.addClip()
            background.setFill()
            rect.insetBy(dx: 4, dy: 4).fill()
            if time < 0.3 {
                (time < 0.24 ? tile : row).draw(in: rect.insetBy(dx: 4, dy: 4), from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                let scale = min((rect.width - 8) / max(1, sourceWidth), (rect.height - 8) / max(1, document.size.height))
                let fitted = NSRect(x: 4, y: rect.maxY - 4 - document.size.height * scale,
                                    width: document.size.width * scale, height: document.size.height * scale)
                document.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1)
            }
            if time > 0.3 && time < 0.6 {
                row.draw(in: rect.insetBy(dx: 4, dy: 4), from: .zero, operation: .sourceOver,
                         fraction: 1 - (time - 0.3) / 0.3)
            }
            return true
        }
    }
}
