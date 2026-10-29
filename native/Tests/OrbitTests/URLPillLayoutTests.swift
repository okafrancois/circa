import AppKit
import Testing
@testable import Orbit

@Suite("URL pill layout", .serialized)
@MainActor
struct URLPillLayoutTests {
    @Test("Pill icons keep adaptive neutral grey through theme, hover and press changes", arguments: [false, true])
    func neutralIcons(isDark: Bool) throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        let pill = SidebarAddressField(frame: NSRect(x: 0, y: 0, width: 312, height: 36))
        pill.appearance = appearance
        let field = NSTextField(string: "example.org")
        pill.installField(field)
        let copy = PillCopyLinkButton()
        let site = SiteControlButton("", identifier: "site-controls", onPress: {})
        site.image = OrbitGlyph.symbol("slider.horizontal.3", pointSize: 18)
        pill.installAccessory(copy, onHover: true)
        pill.installAccessory(site, onHover: true)
        let event = NSEvent()
        let neutral = OrbitTokens.Color.Text.secondary.resolved(for: appearance)
        for theme in [OrbitTokens.SpaceTheme.default, .lavender, .default] {
            pill.accent = OrbitSpaceThemes.accent(for: theme)
            let textColor = field.textColor
            for state in 0..<3 {
                pill.mouseEntered(with: event)
                if state == 1 { copy.mouseEntered(with: event); site.mouseEntered(with: event) }
                if state == 2 {
                    copy.mouseExited(with: event); site.mouseExited(with: event)
                    copy.isHighlighted = true; site.isHighlighted = true
                }
                #expect(copy.tint.resolved(for: appearance) == neutral)
                #expect(site.contentTintColor?.resolved(for: appearance) == neutral)
                #expect(field.stringValue == "example.org" && field.textColor == textColor)
                if state > 0 {
                    #expect(copy.hoverFill.color == OrbitTokens.Color.State.standaloneButton)
                    #expect(site.layer?.backgroundColor == OrbitTokens.Color.State.sidebarItemHovered.resolvedCGColor(for: appearance))
                }
            }
            copy.isHighlighted = false; site.isHighlighted = false
            pill.mouseExited(with: event)
        }
    }

    @Test("Trailing icons stay at the pill edge while the address fills and truncates before them")
    func trailingAlignment() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 228, height: 640))
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        defer { window.close() }
        let pill = sidebar.addressContainer
        let field = NSTextField(string: "a-very-long-domain-name.example.org")
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        OrbitAddressFieldStyle.applySingleLine(to: field)
        pill.installField(field)
        let strip = sidebar.extensionsContainer
        strip.isAvailable = true
        pill.installAccessory(strip, onHover: true, order: 10)
        let copy = NSButton(title: "", target: nil, action: nil)
        let site = SiteControlButton("", identifier: "site-controls", onPress: {})
        for button in [copy, site] {
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        pill.installAccessory(copy, onHover: true, order: 50)
        pill.installAccessory(site, onHover: true, order: 100)
        pill.mouseEntered(with: NSEvent())
        for count in [0, 1] {
            strip.setPinnedButtons((0..<count).map { SiteControlButton("", identifier: "pin-\($0)", onPress: {}) })
            for width in [CGFloat(164), 228, 500] {
                window.setContentSize(NSSize(width: width, height: 640))
                for _ in 0..<3 { sidebar.layoutSubtreeIfNeeded() }
                let siteFrame = pill.convert(site.bounds, from: site)
                let copyFrame = pill.convert(copy.bounds, from: copy)
                let stripFrame = pill.convert(strip.bounds, from: strip)
                // AppKit's text-field frame includes two-point optical outsets on each side.
                let fieldFrame = pill.convert(field.alignmentRect(forFrame: field.frame), from: pill.controls)
                #expect(abs(siteFrame.maxX - (pill.bounds.maxX - 8)) < 0.5)
                #expect(abs(copyFrame.maxX - siteFrame.minX) < 0.5)
                #expect(abs(stripFrame.maxX - copyFrame.minX) < 0.5)
                #expect(fieldFrame.maxX <= stripFrame.minX + 0.5, "Field \(fieldFrame), pins \(stripFrame), copy \(copyFrame), site \(siteFrame)")
                #expect(fieldFrame.width > 0)
                #expect(strip.visiblePinCount == (width == 164 ? 0 : count))
            }
        }
    }

    @Test("Zero, one and three pins share the address row without overlapping the URL or site controls")
    func pinCountsAndOverflow() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 328, height: 640))
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        defer { window.close() }
        let pill = sidebar.addressContainer
        let field = NSTextField(string: "example.org")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pill.installField(field)
        let strip = sidebar.extensionsContainer
        strip.isAvailable = true
        pill.installAccessory(strip, onHover: true, order: 10)
        let site = SiteControlButton("", identifier: "site-controls", onPress: {})
        let copy = NSButton(title: "", target: nil, action: nil)
        for view in [site, copy] {
            view.widthAnchor.constraint(equalToConstant: 28).isActive = true
            view.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        // Installation order must not put the site icon before copy or the extensions.
        pill.installAccessory(site, onHover: true, order: 100)
        pill.installAccessory(copy, onHover: true, order: 50)
        pill.mouseEntered(with: NSEvent())
        for count in [0, 1, 3] {
            let pins = (0..<count).map { SiteControlButton("", identifier: "pin-\($0)", onPress: {}) }
            strip.setPinnedButtons(pins)
            for _ in 0..<3 { sidebar.layoutSubtreeIfNeeded(); pill.layoutSubtreeIfNeeded() }
            #expect(strip.visiblePinCount == count)
            #expect(field.frame.width >= 60)
            #expect(field.frame.maxX <= strip.frame.minX)
            #expect(strip.frame.maxX <= copy.frame.minX)
            #expect(copy.frame.maxX <= site.frame.minX)
            #expect(site.frame.maxX <= pill.bounds.maxX)
            #expect(strip.subviews.count == count) // No puzzle, including the zero-pin state.
            #expect(pins.allSatisfy { $0.frame.maxX <= strip.bounds.maxX && $0.superview === strip })
        }
        let pins = (0..<8).map { SiteControlButton("", identifier: "overflow-\($0)", onPress: {}) }
        strip.setPinnedButtons(pins)
        sidebar.setFrameSize(NSSize(width: 200, height: 640))
        for _ in 0..<3 { sidebar.layoutSubtreeIfNeeded(); pill.layoutSubtreeIfNeeded() }
        #expect(strip.visiblePinCount < pins.count)
        #expect(pins.filter(\.isHidden).allSatisfy { $0.superview === strip && $0.window === window })
        #expect(field.frame.width >= 60)
        #expect(!window.isVisible)
    }

    @Test("Pinned controls remain visible outside hover and yield their width while editing")
    func hoverAndEditing() {
        let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 328, height: 640))
        let pill = sidebar.addressContainer, strip = sidebar.extensionsContainer
        strip.setPinnedButtons([SiteControlButton("", identifier: "pinned-extension", onPress: {})])
        strip.isAvailable = true
        pill.installAccessory(strip, onHover: true)
        sidebar.layoutSubtreeIfNeeded()
        let page = sidebar.geometry.pageFrame
        #expect(strip.alphaValue == 1)
        pill.mouseEntered(with: NSEvent())
        #expect(!strip.isHidden && strip.alphaValue == 1)
        pill.holdsAccessoriesVisible = true
        pill.mouseExited(with: NSEvent())
        #expect(!strip.isHidden && strip.alphaValue == 1)
        pill.isEditing = true
        #expect(strip.isHidden)
        pill.isEditing = false
        pill.holdsAccessoriesVisible = false
        #expect(strip.alphaValue == 1 && !strip.isHidden)
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.geometry.pageFrame == page)
        #expect(strip.isDescendant(of: pill))
    }
}
