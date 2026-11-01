import AppKit
import QuartzCore
import SwiftUI

extension View {
    /// Attach to the composer: the menu is placed from its frame and never leaves the dock's width.
    func assistantPopover<Content: View>(isPresented: Binding<Bool>, placement: BrowserAssistantPopover.Placement,
                                        @ViewBuilder content: () -> Content) -> some View {
        background(AssistantPopoverAnchor(isPresented: isPresented, placement: placement, content: content()))
    }
}

private struct AssistantPopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let placement: BrowserAssistantPopover.Placement
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.assistantPalette) private var palette

    func makeCoordinator() -> BrowserAssistantPopover { BrowserAssistantPopover() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let binding = $isPresented
        context.coordinator.onDismiss = { binding.wrappedValue = false }
        if isPresented {
            context.coordinator.show(from: view, placement: placement,
                                     content: AnyView(content.environment(\.assistantPalette, palette)), palette: palette,
                                     reduced: reduced || OrbitMotionPreferences.prefersReducedMotion)
        } else {
            context.coordinator.close(notify: false)
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: BrowserAssistantPopover) {
        coordinator.close(notify: false, restoreFocus: false)
    }
}

/// A window-owned, arrowless menu whose content keeps its layout during presentation.
@MainActor
final class BrowserAssistantPopover: NSObject, NSWindowDelegate {
    var onDismiss: (() -> Void)?
    private(set) var panel: NSPanel?
    private weak var source: NSWindow?
    private weak var previousResponder: NSResponder?
    private var host: NSHostingView<AnyView>?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    enum Placement: Equatable {
        /// Above the composer, leading aligned, at most this wide.
        case above(maxWidth: CGFloat)
        /// Over the composer, spanning its width and leaving its toolbar visible.
        case over(bottomInset: CGFloat)
        var trailingOrigin: Bool { if case .over = self { true } else { false } }
    }

    /// Opens upward from the composer. The dock's width is a hard bound; `top` limits the height so
    /// a short window shrinks the scrolling list rather than moving the menu away from its composer.
    static func frame(composer: NSRect, size: NSSize, placement: Placement, top: CGFloat, visible: NSRect) -> NSRect {
        let minX = max(composer.minX, visible.minX + 8)
        let available = max(1, min(composer.maxX, visible.maxX - 8) - minX)
        let y: CGFloat, width: CGFloat
        switch placement {
        case .above(let maxWidth):
            y = composer.maxY + 6
            width = min(size.width, maxWidth, available)
        case .over(let bottomInset):
            y = composer.minY + bottomInset
            width = available
        }
        let limit = min(top, visible.maxY - 8)
        let origin = max(visible.minY + 8, min(y, limit - 1))
        return NSRect(x: minX, y: origin, width: width, height: min(size.height, max(1, limit - origin)))
    }

    func show(from anchor: NSView, placement: Placement, content: AnyView, palette: BrowserAssistantPalette, reduced: Bool) {
        if let host { host.rootView = content; return }
        guard let source = anchor.window, source.isVisible,
              let screen = source.screen else { return }
        let host = NSHostingView(rootView: content)
        host.sizingOptions = [.intrinsicContentSize]
        let anchorFrame = source.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let frame = Self.frame(composer: anchorFrame, size: host.fittingSize, placement: placement,
                               top: source.frame.maxY - 18, visible: screen.visibleFrame)
        let panel = AssistantMenuPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("assistant-popup")
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.appearance = palette.appearance
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        let background = NSView(frame: NSRect(origin: .zero, size: frame.size))
        background.wantsLayer = true
        background.layer?.cornerRadius = OrbitTokens.Radius.plusMenu
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = palette.popoverEdge.cgColor
        // Denser than the bar's frost so neither the page nor the conversation ghosts through.
        let solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if !solid {
            let effect = NSVisualEffectView(frame: background.bounds)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.appearance = palette.appearance
            effect.autoresizingMask = [.width, .height]
            background.addSubview(effect)
        }
        let tint = NSView(frame: background.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = (solid ? palette.popoverSolid : palette.popover).cgColor
        tint.autoresizingMask = [.width, .height]
        background.addSubview(tint)
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        panel.contentView = background
        self.source = source
        previousResponder = source.firstResponder
        self.host = host
        self.panel = panel
        source.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        animate(background, panelFrame: frame, trailing: placement.trailingOrigin, reduced: reduced)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak panel] event in
            if let self, event.window !== self.panel {
                // Let the clicked control update its own state before dismissing this menu.
                DispatchQueue.main.async { [weak self, weak panel] in
                    if self?.panel === panel { self?.close() }
                }
            }
            return event
        }
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.willEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification, NSWindow.didResizeNotification,
                     NSWindow.didMoveNotification, NSWindow.willBeginSheetNotification] {
            observers.append(center.addObserver(forName: name, object: source, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close(restoreFocus: false) }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(restoreFocus: false) }
        })
    }

    private func animate(_ view: NSView, panelFrame: NSRect, trailing: Bool, reduced: Bool) {
        guard let layer = view.layer else { return }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = reduced ? 0.15 : 0.16
        opacity.timingFunction = reduced ? CAMediaTimingFunction(name: .linear)
            : CAMediaTimingFunction(controlPoints: 1 / 3, 1, 2 / 3, 1)
        layer.add(opacity, forKey: "assistant-entry-opacity")
        guard !reduced else { return }
        // Menus always open upward, so they scale from their bottom edge.
        let origin = CGPoint(x: trailing ? panelFrame.width : 0, y: 0)
        let scale = CABasicAnimation(keyPath: "transform")
        var transform = CATransform3DMakeTranslation(origin.x, origin.y, 0)
        transform = CATransform3DScale(transform, 0.97, 0.97, 1)
        scale.fromValue = NSValue(caTransform3D: CATransform3DTranslate(transform, -origin.x, -origin.y, 0))
        scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        scale.duration = 0.16
        scale.timingFunction = opacity.timingFunction
        layer.add(scale, forKey: "assistant-entry-scale")
    }

    func close(notify: Bool = true, restoreFocus: Bool = true) {
        guard let panel else { return }
        let restoreKey = panel.isKeyWindow
        self.panel = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        source?.removeChildWindow(panel)
        panel.close()
        host = nil
        if restoreFocus, restoreKey, source?.isVisible == true {
            source?.makeKey()
            if let previousResponder { source?.makeFirstResponder(previousResponder) }
        }
        previousResponder = nil
        if notify { onDismiss?() }
    }
    func windowDidResignKey(_ notification: Notification) { close(restoreFocus: false) }
}

@MainActor
private final class AssistantMenuPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    /// A focused search field must not consume Escape before the menu sees it.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == BrowserAssistantKey.escape { onCancel?(); return }
        super.sendEvent(event)
    }
}
