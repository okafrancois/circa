import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

@Suite("URL pill selection presentation", .serialized)
@MainActor
struct URLPillSwitchTests {
    @Test("Transport security uses the existing site state and the connection glyph, inside the moving URL group")
    func securityGroup() throws {
        let field = OrbitLocationField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.font = .systemFont(ofSize: 13)
        for (url, symbol) in [("https://example.org/path", "lock.fill"), ("http://example.org/path", "lock.slash.fill")] {
            let presentation = BrowserAddressPresentation(url: URL(string: url), security: try pageSecurity(level: symbol == "lock.fill" ? 3 : 0), format: { $0.host })
            field.refreshAddress(url, in: nil, presentation: presentation)
            field.layoutSubtreeIfNeeded()
            #expect(field.stringValue == url) // Editing/AX retain the unshortened destination.
            #expect(field.securitySymbol == symbol)
            #expect(field.securityIcon.image != nil && !field.securityIcon.isHidden)
            #expect(field.securityIcon.superview === field.displayLabel.superview)
            #expect(field.securityIcon.frame.maxX < field.displayLabel.frame.minX)
            #expect(abs(field.securityIcon.frame.midY - field.displayLabel.frame.midY) <= 0.5)
            let restingY = field.securityIcon.frame.midY
            field.setStatus("Synthetic status", animated: false)
            field.layoutSubtreeIfNeeded()
            #expect(field.hasStatus && field.securityIcon.frame.midY > restingY)
            let status = try #require(field.textGroup.subviews.compactMap { $0 as? NSTextField }.last)
            let rect = field.textMask.convert(status.bounds, from: status)
            #expect(rect.minY >= field.textMask.bounds.minY && rect.maxY <= field.textMask.bounds.maxY)
            #expect(status.alphaValue == 1)

            #expect(abs(field.securityIcon.frame.midY - field.displayLabel.frame.midY) <= 0.5)
            field.setStatus(nil, animated: false)
            #expect(status.alphaValue == 0)
        }
        field.placeholderAttributedString = NSAttributedString(string: "Synthetic placeholder")
        field.stringValue = ""
        #expect(field.displayLabel.stringValue == "Synthetic placeholder")
        for value in ["", "about:blank", "orbit:settings"] {
            field.stringValue = value
            #expect(field.securityIcon.isHidden && field.securitySymbol == nil)
        }
    }

    @Test("A declined preview restores address, status and security without a late source repaint")
    func previewRollback() {
        let source = SpaceID(), target = SpaceID()
        let field = OrbitLocationField()
        field.statusForSpace = { $0 == target ? "Synthetic status" : nil }
        let original = BrowserAddressPresentation(url: URL(string: "http://example.org/"), security: nil, format: { $0.host })
        let destination = BrowserAddressPresentation(url: URL(string: "https://example.net/"), security: try! pageSecurity(level: 3), format: { $0.host })
        field.refreshAddress(original.value, in: source, presentation: original)
        field.setAddress(destination.value, from: source, to: target, spaces: [], awaitingPublication: true, presentation: destination)
        #expect(field.hasStatus && field.security == .https)
        field.refreshAddress("http://example.org/late", in: source)
        #expect(field.security == .https && field.stringValue == "https://example.net/")
        field.finishSpaceTransition(original.value, in: source, spaces: [], presentation: original)
        #expect(!field.hasStatus && field.security == .insecure && field.pendingSpaceID == nil)
    }

    @Test("An empty Space retains profile pins while removing site actions and preserving the popup anchors")
    func emptySpaceAccessories() throws {
        let pill = SidebarAddressField(frame: NSRect(x: 0, y: 0, width: 400, height: 36))
        let window = NSWindow(contentRect: pill.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = pill
        defer { window.close() }
        let field = OrbitLocationField()
        field.stringValue = "https://example.org/"
        pill.installField(field)
        let pins = [NSButton(), NSButton()]
        pill.extensions.isAvailable = true
        pill.installAccessory(pill.extensions, onHover: true, order: 10)
        pill.extensions.setPinnedButtons(pins)
        let site = NSButton()
        site.widthAnchor.constraint(equalToConstant: 28).isActive = true
        pill.installAccessory(site, onHover: true, order: 100)
        pill.holdsAccessoriesVisible = true
        pill.layoutSubtreeIfNeeded()
        let before = pill.extensions.frame.minX
        pill.beginSelectionUpdate()
        field.setAddress("", from: SpaceID(), to: SpaceID(), spaces: [])
        pill.endSelectionUpdate(animated: false)
        pill.layoutSubtreeIfNeeded()
        #expect(site.isHidden && site.superview === pill.controls)
        #expect(pill.extensions.subviews.count == 2 && !pill.extensions.isHidden)
        #expect(pins.allSatisfy { $0.superview === pill.extensions && $0.window === window })
        #expect(pill.extensions.frame.minX > before)
        #expect(field.securityIcon.isHidden)
    }
}
