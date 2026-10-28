import AppKit
@testable import BrowserCore
import BrowserShell
import Foundation
import Testing
@testable import Orbit
import BrowserEngine
import WebKitEngine


private let reference = CGSize(width: 1024, height: 640)

private func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool { abs(a - b) <= tolerance }

private func components(_ hex: UInt32) -> [CGFloat] {
    [CGFloat((hex >> 16) & 0xFF), CGFloat((hex >> 8) & 0xFF), CGFloat(hex & 0xFF)]
}

/// Renders a layer-backed view into an sRGB bitmap and returns a pixel reader in top-left points.
@MainActor
private func render(_ view: NSView) throws -> (Int, Int) -> [CGFloat] {
    let width = Int(view.bounds.width), height = Int(view.bounds.height)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    try #require(view.layer).render(in: context)
    let bytes = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                          count: width * height * 4))
    // Bitmap rows run top to bottom.
    return { x, y in
        let offset = (y * width + x) * 4
        return [CGFloat(bytes[offset]), CGFloat(bytes[offset + 1]), CGFloat(bytes[offset + 2])]
    }
}

extension NativeWebKitTests {
@Suite("Theme R2 — default Space gradient and appearance")
@MainActor
struct ThemeR2GradientTests {
    @Test("The default Space uses a two-stop gradient and keeps legacyFlat for older sessions")
    func defaultTheme() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let stops = OrbitTokens.SpaceTheme.default.stops
        #expect(stops.count == 2)
        func rgb(_ colour: NSColor, _ appearance: NSAppearance) -> [CGFloat] {
            let c = colour.resolved(for: appearance)
            return [c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255]
        }
        for (colour, appearance, hex) in [(stops[0], light, UInt32(0xD9DBF5)), (stops[1], light, 0xF3E5E5),
                                          (stops[0], dark, 0x252538), (stops[1], dark, 0x352337)] {
            #expect(zip(rgb(colour, appearance), components(hex)).allSatisfy { close($0, $1, 0.6) })
        }
        #expect(zip(rgb(OrbitTokens.SpaceTheme.legacyFlat.stops[0], light), components(0xE6E6E8)).allSatisfy { close($0, $1, 0.6) })
        // Stops at d 20 / 1300 (light) and 160 / 1380 (dark) of a 1512 × 949 window along the 43° axis.
        let fractions = OrbitTokens.SpaceTheme.default.stopRange
        #expect(close(fractions.light.lowerBound, 20 / 1753.02, 1e-4) && close(fractions.light.upperBound, 1300 / 1753.02, 1e-4))
        #expect(close(fractions.dark.lowerBound, 160 / 1753.02, 1e-4) && close(fractions.dark.upperBound, 1380 / 1753.02, 1e-4))
    }

    @Test("The fill reproduces the measured 43° axis and its flat ends at 1512 × 949, in light and dark",
          arguments: [false, true])
    func gradientAxis(isDark: Bool) throws {
        let size = OrbitTokens.SpaceTheme.Gradient.referenceSize
        let view = OrbitThemeFillView(frame: NSRect(origin: .zero, size: size))
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()
        let pixel = try render(view)
        let start = components(isDark ? 0x252538 : 0xD9DBF5), end = components(isDark ? 0x352337 : 0xF3E5E5)
        let range = OrbitTokens.SpaceTheme.default.stopRange.range(isDark: isDark)
        func expected(_ point: CGPoint) -> [CGFloat] {
            let f = OrbitThemeGradient.axisFraction(of: point, in: size)
            let t = max(0, min(1, (f - range.lowerBound) / (range.upperBound - range.lowerBound)))
            return zip(start, end).map { $0 + ($1 - $0) * t }
        }
        // Flat start, flat end, and points along and across the axis (isolines perpendicular in points).
        let probes = [CGPoint(x: 2, y: 2), CGPoint(x: 1505, y: 940), CGPoint(x: 500, y: 300), CGPoint(x: 300, y: 700),
                      CGPoint(x: 900, y: 100), CGPoint(x: 1200, y: 600), CGPoint(x: 60, y: 900)]
        for probe in probes {
            let measured = pixel(Int(probe.x), Int(probe.y))
            #expect(zip(measured, expected(probe)).allSatisfy { close($0, $1, 2.5) }, "pixel \(probe): \(measured) vs \(expected(probe))")
        }
        // Two points on the same isoline (perpendicular to 43° in points) share a colour.
        let a = CGPoint(x: 700, y: 400)
        let b = CGPoint(x: a.x + 200 * sin(43 * .pi / 180), y: a.y - 200 * cos(43 * .pi / 180))
        #expect(zip(pixel(Int(a.x), Int(a.y)), pixel(Int(b.x.rounded()), Int(b.y.rounded()))).allSatisfy { close($0, $1, 1.5) })
    }

    @Test("Light ↔ dark is instant: an appearance change drops a Space cross-fade in flight")
    func appearanceSwitchIsInstant() throws {
        let view = OrbitThemeFillView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.appearance = NSAppearance(named: .aqua)
        view.apply(.lavender, fade: 0.3)
        #expect(view.isCrossfading)
        view.appearance = NSAppearance(named: .darkAqua)
        #expect(!view.isCrossfading)
        #expect(OrbitTokens.Motion.themeModeSwitchIsInstant)
    }
}
}

extension NativeWebKitTests {
@Suite("Theme R2 — tokens for other surfaces")
@MainActor
struct ThemeR2TokenTests {
    @Test("Command bar, Little Orbit, Peek, split and radii carry the round 2 measurements")
    func surfaceTokens() {
        typealias M = OrbitTokens.Metrics
        #expect(M.CommandBar.width == 765 && M.CommandBar.top(windowHeight: 640) == 151.5)
        #expect(M.CommandBar.top(windowHeight: 949) == 306)
        #expect(OrbitTokens.Radius.commandBar == 12 && OrbitTokens.Radius.commandBarRow == 8)
        #expect(OrbitTokens.Shadow.commandBar.offsetY == 24 && OrbitTokens.Shadow.commandBar.blur == 96)
        #expect(M.QuickWindow.toolbarHeight == 47 && M.QuickWindow.pageIsEdgeToEdge)
        #expect(M.Content.splitGap == 10 && M.Content.splitDividerHandle == NSSize(width: 2, height: 24))
        #expect(OrbitTokens.Shadow.splitActiveHalo.blur == 16)
        #expect(M.Peek.panelInsetFromCardX == 110 && M.Peek.panelTop == 12 && !M.Peek.hasInternalToolbar)
        #expect(OrbitTokens.Radius.floatingSidebar == 12 && OrbitTokens.Radius.peek == 8 && OrbitTokens.Radius.toast == 11)
        #expect(OrbitTokens.Shadow.tabSelected.blur == 2 && OrbitTokens.Shadow.popover.offsetY == 1 && OrbitTokens.Shadow.popover.blur == 6)
        #expect(OrbitTokens.Shadow.floatingSidebar.blur == 8 && OrbitTokens.Shadow.floatingSidebar.offsetY == 0)
        #expect(M.Sidebar.widthMin == 164 && M.Sidebar.widthMax == 500 && M.Sidebar.collapsePointerX == 82)
        #expect(M.Sidebar.closeCenterFromRowRight == 18 && M.Sidebar.floatingInset == 5)
        #expect(OrbitTokens.Typography.sidebarClear == NSFont.systemFont(ofSize: 11, weight: .semibold))
    }

    @Test("A row's × hovers with a 24 × 24 square of the measured 7 % fill")
    func rowCloseHoverFill() throws {
        let fill = OrbitGlyphButton.HoverFill.rowClose
        #expect(fill.side == 24)
        let light = try #require(NSAppearance(named: .aqua))
        #expect(close(fill.color.resolved(for: light).alphaComponent, 0.07))
        #expect(OrbitGlyphButton(glyph: nil, label: "").hoverFill == .standalone)
    }

    @Test("Shell and site-control strings default to Orbit's English (UX-LOCALIZATION)")
    func englishDefaults() {
        #expect(OrbitShellText.newTab == "New Tab" && OrbitShellText.newSpace == "New Space…")
        #expect(OrbitShellText.back == "Back" && OrbitShellText.space("Work") == "Space Work")
        #expect(OrbitShellText.addressPlaceholder == "Search or Enter URL…")
        #expect(BrowserSitePermission.camera.displayTitle == "Camera")
        #expect(BrowserSiteCommands.definitions.first?.localizedTitle == "Site Controls…")
    }
}
}

extension NativeWebKitTests {
@Suite("Theme R2 — loading capsule and VIS-1 defects")
@MainActor
struct ThemeR2BehaviourTests {
    @Test("Loading maps to a waiting pulse before commit and a progress sweep after")
    func loadingPhases() throws {
        let a = try #require(URL(string: "https://a.example/"))
        let b = try #require(URL(string: "https://b.example/"))
        #expect(OrbitLoadingIndicatorView.Phase.resolve(isLoading: false, url: a, committedURL: a) == .idle)
        #expect(OrbitLoadingIndicatorView.Phase.resolve(isLoading: true, url: b, committedURL: a) == .waiting)
        #expect(OrbitLoadingIndicatorView.Phase.resolve(isLoading: true, url: b, committedURL: nil) == .waiting)
        #expect(OrbitLoadingIndicatorView.Phase.resolve(isLoading: true, url: a, committedURL: a) == .progress)
    }

    @Test("The empty Space shows the theme through a white overlay; the card shadow is cast outside only")
    func emptyCard() throws {
        let card = BrowserContentCardView()
        card.appearance = NSAppearance(named: .aqua)
        card.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        card.present(nil)
        card.layoutSubtreeIfNeeded()
        let empty = try #require(card.clipBackground.flatMap { NSColor(cgColor: $0) })
        #expect(close(empty.alphaComponent, 0.70, 0.001))
        card.present(NSView())
        let page = try #require(card.clipBackground.flatMap { NSColor(cgColor: $0) })
        #expect(close(page.alphaComponent, 1))
        let shadow = try #require(card.shadowSpec)
        #expect(shadow.blur == 6 && shadow.offsetY == 1)
        #expect(card.layer?.shadowOpacity ?? 0 == 0)
    }

    @Test("The site-controls popover opens at its top and never exceeds the window space below its anchor")
    func sitePopoverContent() throws {
        let rows = (0..<30).map { BrowserSitePopover.label("Synthetic row \($0)") }
        let content = BrowserSitePopover.makeContent(rows: rows, maximumHeight: 300)
        #expect(content.frame.height == 300)
        let document = try #require(content.documentView)
        #expect(document.isFlipped && content.contentView.bounds.minY == 0)
        let first = rows[0].convert(rows[0].bounds, to: document)
        #expect(content.documentVisibleRect.contains(first), "first row \(first) visible \(content.documentVisibleRect)")
        #expect(first.minY < 40)
        // A 1024 × 640 window with the field's button at y 46…82 from the top: 640 − 82 − 12 − 14.
        #expect(BrowserSitePopover.maximumHeight(anchorRectInWindow: NSRect(x: 200, y: 640 - 82, width: 24, height: 24)) == 532)
        #expect(BrowserSitePopover.maximumHeight(anchorRectInWindow: NSRect(x: 0, y: 900, width: 24, height: 24)) == 580)
        #expect(BrowserSitePopover.maximumHeight(anchorRectInWindow: NSRect(x: 0, y: 40, width: 24, height: 24)) == 160)
        // A short popover keeps its fitting height.
        let short = BrowserSitePopover.makeContent(rows: [BrowserSitePopover.label("Origin", title: true)], maximumHeight: 300)
        #expect(short.frame.height < 100)
    }

    @Test("Site-control rows fit with initial and changing scroller styles and widths")
    func sitePopoverScrollerStyles() throws {
        // Set each view's initial style before document attachment. A later style change
        // alone misses the case where the clip is already narrower than the document.
        for initialStyle: NSScroller.Style in [.legacy, .overlay] {
            let rows = (0..<30).map { BrowserSitePopover.label("Synthetic row \($0)") }
            let content = BrowserSitePopover.makeContent(rows: rows, maximumHeight: 300,
                                                        scrollerStyle: initialStyle)
            let document = try #require(content.documentView)
            #expect(document.frame.width == content.documentVisibleRect.width,
                    "initial style \(initialStyle.rawValue), document \(document.frame), visible \(content.documentVisibleRect)")
            for style: NSScroller.Style in [.legacy, .overlay, .legacy] {
                content.scrollerStyle = style
                for width: CGFloat in [360, 320, 360] {
                    content.setFrameSize(NSSize(width: width, height: 300))
                    content.tile()
                    content.layoutSubtreeIfNeeded()
                    document.layoutSubtreeIfNeeded()
                    let visible = content.documentVisibleRect
                    let first = rows[0].convert(rows[0].bounds, to: document)
                    #expect(visible.contains(first),
                            "initial \(initialStyle.rawValue), style \(style.rawValue), first \(first), visible \(visible)")
                    #expect(document.frame.width == visible.width,
                            "document \(document.frame), clip \(visible)")
                    #expect(visible.minX == 0 && visible.minY == 0)
                    #expect(!content.hasHorizontalScroller)
                    for row in rows {
                        let frame = row.convert(row.bounds, to: document)
                        #expect(frame.minX >= visible.minX && frame.maxX <= visible.maxX)
                    }
                }
            }
        }
    }

    @Test("Wrapped site-control rows remain reachable with a legacy scroller")
    func sitePopoverWrappedRows() throws {
        let rows = (0..<8).map { _ in
            BrowserSitePopover.label(String(repeating: "Synthetic connection description ", count: 4))
        }
        let content = BrowserSitePopover.makeContent(rows: rows, maximumHeight: 300, scrollerStyle: .legacy)
        content.tile()
        content.layoutSubtreeIfNeeded()
        let document = try #require(content.documentView)
        document.layoutSubtreeIfNeeded()
        let last = rows[7].convert(rows[7].bounds, to: document)
        #expect(document.bounds.contains(last), "last \(last), document \(document.bounds)")
    }

    @Test("The address field stays on one line: tail ellipsis at rest, horizontal scrolling while editing, even with a selection")
    func addressFieldSingleLine() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        window.setContentSize(reference)
        window.contentView?.layoutSubtreeIfNeeded()
        let field = controller.addressControl
        let cell = try #require(field.cell)
        #expect(!cell.wraps && cell.lineBreakMode == .byTruncatingTail && cell.usesSingleLineMode)
        let address = "http://127.0.0.1:4330/specimen.html?synthetic=a-long-query/with/many/segments/that/overflow/the/field"
        #expect(window.makeFirstResponder(field))
        defer { window.makeFirstResponder(nil) }
        let editor = try #require(field.currentEditor() as? NSTextView)
        // As if pasted: the editor holds the URL, part of it selected (the case seen wrapping in Orbit Live).
        editor.string = address
        editor.setSelectedRange(NSRange(location: 7, length: 40))
        let layout = try #require(editor.layoutManager), container = try #require(editor.textContainer)
        layout.ensureLayout(for: container)
        var lines = 0
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in lines += 1 }
        #expect(lines == 1, "\(lines) lines for \(editor.string.count) characters, container \(container.size), editor \(editor.frame)")
        #expect(editor.isHorizontallyResizable && !container.widthTracksTextView)
    }

    @Test("Below 224 pt the toolbar turns compact; in full screen the toggle moves to x 28.6")
    func compactToolbarAndFullScreen() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        window.setContentSize(reference)
        let row = controller.sidebar.navigationContainer
        controller.windowShell.setSidebarWidth(200)
        root.layoutSubtreeIfNeeded()
        let overflow = try #require(row.overflowButton)
        #expect(row.layoutState?.isCompact == true)
        #expect(row.buttons[0].isHidden && row.buttons[3].isHidden && !overflow.isHidden)
        #expect(row.buttons[1].frame.midX == 124 && row.buttons[2].frame.midX == 152 && overflow.frame.midX == 180)
        controller.windowShell.setSidebarWidth(228)
        root.layoutSubtreeIfNeeded()
        #expect(row.layoutState?.isCompact == false && !row.buttons[0].isHidden && !row.buttons[3].isHidden && overflow.isHidden)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        root.layoutSubtreeIfNeeded()
        #expect(row.buttons[0].frame.midX == 28.6)
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        root.layoutSubtreeIfNeeded()
        #expect(close(row.buttons[0].frame.midX, 20 + 2 * controller.windowShell.trafficLightPitch + 27.25))
    }

    @Test("The loading capsule sits centred over the card in the top margin and hides when the margin is gone")
    func loadingCapsulePlacement() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        window.setContentSize(reference)
        root.layoutSubtreeIfNeeded()
        let capsule = controller.windowShell.loadingIndicator
        controller.windowShell.setLoadingPhase(.waiting)
        // Card 228…1014 × 10…630: centre x 621, capsule 4 high centred in the 10 pt margin.
        #expect(!capsule.isHidden && capsule.frame == NSRect(x: 621 - 23.5, y: 640 - 7, width: 47, height: 4))
        controller.windowShell.setLoadingPhase(.progress)
        #expect(!capsule.isHidden && capsule.frame.width == 127.5 && capsule.frame.midX == 621)
        controller.windowShell.setLoadingPhase(.idle)
        #expect(capsule.isHidden)
        // Full screen with the sidebar hidden: the card reaches the top, no margin holds the capsule.
        let standalone = OrbitLoadingIndicatorView()
        standalone.setPhase(.progress, animated: false)
        standalone.place(over: CGRect(origin: .zero, size: reference), in: reference)
        #expect(standalone.isHidden)
        standalone.place(over: CGRect(x: 10, y: 10, width: 1004, height: 620), in: reference)
        #expect(!standalone.isHidden && standalone.frame.midX == 512)
    }

    @Test("Dragging the edge past the threshold hides the sidebar at once")
    func dragCollapseIsInstant() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        controller.window?.setContentSize(reference)
        controller.windowShell.onCollapseRequest?()
        await controller.session.waitForPendingCommands()
        #expect(!controller.isSidebarShown && controller.windowShell.dockProgress == 0 && !controller.windowShell.isAnimating)
    }
}
}
