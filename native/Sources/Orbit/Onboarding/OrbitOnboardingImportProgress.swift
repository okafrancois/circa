import AppKit
import BrowserCore
import BrowserShell

/// Presentation of the existing import transaction, never an additional navigation step.
struct OrbitOnboardingImportStatus: Sendable {
    var source = ""
    var counts: [Int?] = Array(repeating: nil, count: 5)
    var fraction: Double?
    var finished = false
    var completedRows: Set<Int> = []
}

@MainActor
final class OrbitOnboardingImportProgressView: NSView {
    private let heading = OrbitOnboardingMomentTitle(wrappingLabelWithString: "")
    private let track = CALayer()
    private let fill = CALayer()
    private let rows = (0..<5).map { _ in NSTextField(labelWithString: "") }
    private let circles = (0..<5).map { _ in CAShapeLayer() }
    private let values = (0..<5).map { _ in NSTextField(labelWithString: "") }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(heading)
        let names = [uiText("Spaces"), uiText("Pinned tabs"), uiText("Themes"), uiText("Boosts"), uiText("Passwords (encrypted)")]
        for index in rows.indices {
            rows[index].stringValue = names[index]
            rows[index].font = OrbitOnboardingFonts.ui(22.11, weight: .medium)
            rows[index].textColor = BrandPalette.ink
            addSubview(rows[index])
            values[index].font = OrbitOnboardingFonts.mono(16.58)
            values[index].textColor = BrandPalette.ink.withAlphaComponent(0.6)
            values[index].alignment = .right
            addSubview(values[index])
            circles[index].lineWidth = 2.37
            circles[index].strokeColor = BrandPalette.ink.cgColor
            layer?.addSublayer(circles[index])
        }
        track.frame = NSRect(x: 780, y: 189.47, width: 366.32, height: 12.63)
        track.cornerRadius = 6.32
        track.backgroundColor = BrandPalette.ink.withAlphaComponent(0.13).cgColor
        fill.backgroundColor = BrandPalette.coral.cgColor
        fill.cornerRadius = 6.32
        track.addSublayer(fill); layer?.addSublayer(track)
        let privacy = NSTextField(labelWithString: uiText("nothing uploaded").uppercased())
        privacy.attributedStringValue = BrandTextStyle.mono.attributedString(privacy.stringValue, size: 16.58, attributes: [.foregroundColor: BrandPalette.cobalt, .kern: 1.99])
        privacy.frame = NSRect(x: 778, y: 221.05, width: 366, height: 25)
        addSubview(privacy)
        let next = OrbitOnboardingPrimaryButton()
        next.title = OrbitOnboardingText.next
        next.isEnabled = false
        next.frame = NSRect(origin: NSPoint(x: 54, y: 608), size: next.intrinsicContentSize)
        addSubview(next)
        let back = OrbitOnboardingLinkButton(title: OrbitOnboardingText.back, arrow: false, font: OrbitOnboardingFonts.back)
        back.isUnderlined = true; back.isEnabled = false; back.alphaValue = 1; back.accent = BrandPalette.ink
        back.frame.origin = NSPoint(x: next.frame.maxX + 22.11, y: next.frame.minY + 32 - back.frame.height / 2)
        addSubview(back)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func update(_ status: OrbitOnboardingImportStatus) {
        heading.attributedStringValue = BrandTextStyle.title.attributedString(uiFormat("Bringing %@ over…", status.source), size: 63.16, opticalSize: 40, attributes: [.foregroundColor: BrandPalette.ink])
        heading.frame = NSRect(x: 54, y: 94.74, width: 587.37, height: heading.sizeThatFits(NSSize(width: 587.37, height: 400)).height)
        for index in rows.indices {
            let y = heading.frame.maxY + 25.26 + CGFloat(index) * 39.47
            rows[index].frame = NSRect(x: 98, y: y, width: 346, height: 30)
            values[index].frame = NSRect(x: 453, y: y + 5, width: 75, height: 24)
            values[index].stringValue = status.counts[index].map(String.init) ?? "—"
            let completed = (status.finished || status.completedRows.contains(index)) && status.counts[index] != nil
            rows[index].alphaValue = completed ? 1 : 0.4
            values[index].alphaValue = completed ? 1 : 0.4
            circles[index].frame = NSRect(x: 54, y: y + 1, width: 28.42, height: 28.42)
            circles[index].path = CGPath(ellipseIn: circles[index].bounds.insetBy(dx: 1.2, dy: 1.2), transform: nil)
            circles[index].fillColor = completed ? BrandPalette.cobalt.cgColor : NSColor.clear.cgColor
            circles[index].opacity = completed ? 1 : 0.4
            circles[index].sublayers?.forEach { $0.removeFromSuperlayer() }
            if completed {
                let check = CAShapeLayer(), path = CGMutablePath()
                path.move(to: CGPoint(x: 7, y: 14)); path.addLine(to: CGPoint(x: 12, y: 19)); path.addLine(to: CGPoint(x: 21, y: 9))
                check.path = path; check.fillColor = nil
                check.strokeColor = BrandPalette.pageWhite.cgColor; check.lineWidth = 2.4
                circles[index].addSublayer(check)
            }
        }
        fill.frame = CGRect(x: 0, y: 0, width: track.bounds.width * CGFloat(status.fraction ?? 0), height: track.bounds.height)
    }
}
