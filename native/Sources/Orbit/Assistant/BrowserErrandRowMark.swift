import AppKit
import BrowserCore
import BrowserShell

struct SidebarErrandSummary: Equatable {
    let id: TabID
    let folder: FolderID
    let profile: ProfileID
    let space: SpaceID
}

@MainActor final class BrowserErrandRowMark: NSView {
    enum State: Equatable { case working, waiting, done, count(Int) }
    let ring = SidebarTabLoadingView()
    let image = NSImageView()
    let label = NSTextField(labelWithString: "")
    var state: State = .working { didSet { update() } }
    var tint: NSColor = .labelColor { didSet { ring.tint = tint; image.contentTintColor = tint; label.textColor = tint } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [ring, image, label] { addSubview(view) }
        label.font = BrandTextStyle.ui.font(size: 11); label.alignment = .right
        setAccessibilityElement(false); update()
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); ring.frame = bounds; image.frame = bounds; label.frame = bounds }
    private func update() {
        ring.isHidden = state != .working; ring.isLoading = state == .working
        image.isHidden = true; label.isHidden = true
        switch state {
        case .waiting: image.image = OrbitIcon.image(sfName: "hand.raised", pointSize: 14); image.isHidden = false
        case .done: image.image = OrbitIcon.image(sfName: "checkmark", pointSize: 14); image.isHidden = false
        case .count(let number): label.stringValue = String(number); label.isHidden = false
        case .working: break
        }
    }
}
