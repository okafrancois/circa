import AppKit
import QuartzCore
import SwiftUI

extension View {
    func assistantSheet<Content: View>(isPresented: Binding<Bool>, valid: @escaping () -> Bool,
                                        @ViewBuilder content: () -> Content) -> some View {
        background(AssistantSheetAnchor(isPresented: isPresented, valid: valid, content: content()))
    }
}

private struct AssistantSheetAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let valid: () -> Bool
    let content: Content
    @Environment(\.assistantPalette) private var palette
    func makeCoordinator() -> BrowserAssistantSheet { BrowserAssistantSheet() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let binding = $isPresented
        context.coordinator.onDismiss = { binding.wrappedValue = false }
        if isPresented, valid(), let window = view.window {
            context.coordinator.show(in: window, content: AnyView(content.environment(\.assistantPalette, palette)), valid: valid)
        } else {
            context.coordinator.close(animated: valid())
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: BrowserAssistantSheet) {
        coordinator.close(animated: false, notify: false)
    }
}

/// Window-local modal content with independently animated backdrop and card.
@MainActor
final class BrowserAssistantSheet {
    static let identifier = NSUserInterfaceItemIdentifier("assistant-skill-sheet")
    var onDismiss: (() -> Void)?
    private(set) var overlay: NSView?
    private var card: NSHostingView<AnyView>?
    private weak var source: NSWindow?
    private weak var previousResponder: NSResponder?
    private var closing = false
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var validity: () -> Bool = { false }

    func show(in window: NSWindow, content: AnyView, valid: @escaping () -> Bool) {
        if let overlay, closing { remove(overlay, notify: false) }
        if let overlay {
            guard validity() else { close(animated: false); return }
            card?.rootView = content; overlay.needsLayout = true; return
        }
        guard valid(), let parent = window.contentView else { return }
        validity = valid
        closing = false
        source = window; previousResponder = window.firstResponder
        let cover = AssistantSheetCover(frame: parent.bounds)
        cover.identifier = Self.identifier
        cover.autoresizingMask = [.width, .height]
        cover.wantsLayer = true
        cover.layer?.backgroundColor = NSColor(srgbRed: 14 / 255, green: 14 / 255, blue: 17 / 255, alpha: 0.18).cgColor
        let host = AssistantSheetHost(rootView: content)
        host.sizingOptions = [.intrinsicContentSize]
        host.wantsLayer = true
        host.layer?.cornerRadius = 14
        host.layer?.masksToBounds = true
        cover.addSubview(host)
        cover.card = host
        cover.setAccessibilityElement(false)
        host.setAccessibilityRole(.sheet)
        parent.addSubview(cover, positioned: .above, relativeTo: nil)
        overlay = cover; card = host
        cover.needsLayout = true
        cover.layoutSubtreeIfNeeded()
        window.makeFirstResponder(host)
        animateEntry()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, event.window === window else { return event }
            if !validity() { close(animated: false); return event }
            if closing { return nil }
            if event.keyCode == BrowserAssistantKey.escape { close(); return nil }
            return event
        }
        for name in [NSWindow.willCloseNotification, NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close(animated: false) }
            })
        }
    }

    private func animateEntry() {
        guard let cover = overlay, let card, let layer = card.layer, source?.isVisible == true else { return }
        let reduced = OrbitMotionPreferences.prefersReducedMotion
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0; opacity.toValue = 1
        opacity.duration = reduced ? 0.15 : 0.36
        opacity.timingFunction = reduced ? CAMediaTimingFunction(name: .linear)
            : CAMediaTimingFunction(controlPoints: 0.19, 1, 0.22, 1)
        layer.add(opacity, forKey: "sheet-entry-opacity")
        if !reduced {
            let x = card.bounds.midX, y = card.bounds.midY
            var initial = CATransform3DMakeTranslation(x, y + 14, 0)
            initial = CATransform3DScale(initial, 0.98, 0.98, 1)
            initial = CATransform3DTranslate(initial, -x, -y, 0)
            let transform = CABasicAnimation(keyPath: "transform")
            transform.fromValue = NSValue(caTransform3D: initial)
            transform.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            transform.duration = opacity.duration; transform.timingFunction = opacity.timingFunction
            layer.add(transform, forKey: "sheet-entry-transform")
        }
        let dim = CABasicAnimation(keyPath: "backgroundColor")
        dim.fromValue = NSColor.clear.cgColor; dim.toValue = cover.layer?.backgroundColor
        dim.duration = reduced ? 0.15 : 0.2
        dim.timingFunction = reduced ? CAMediaTimingFunction(name: .linear)
            : CAMediaTimingFunction(controlPoints: 1 / 3, 2 / 3, 2 / 3, 1)
        cover.layer?.add(dim, forKey: "sheet-backdrop-entry")
    }

    func close(animated: Bool = true, notify: Bool = true) {
        guard let cover = overlay else { return }
        if !animated || !validity() { remove(cover, notify: notify); return }
        guard !closing else { return }
        closing = true
        let reduced = OrbitMotionPreferences.prefersReducedMotion
        guard source?.isVisible == true, let layer = card?.layer else { remove(cover, notify: notify); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak cover] in
            MainActor.assumeIsolated { if let cover { self?.remove(cover, notify: notify) } }
        }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = layer.presentation()?.opacity ?? 1; opacity.toValue = 0
        opacity.duration = reduced ? 0.15 : 0.18
        opacity.timingFunction = reduced ? CAMediaTimingFunction(name: .linear)
            : CAMediaTimingFunction(controlPoints: 1 / 3, 0, 2 / 3, 0)
        opacity.isRemovedOnCompletion = false; opacity.fillMode = .forwards
        layer.add(opacity, forKey: "sheet-exit-opacity")
        if !reduced {
            let movement = CABasicAnimation(keyPath: "transform")
            movement.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
            movement.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, 10, 0))
            movement.duration = opacity.duration; movement.timingFunction = opacity.timingFunction
            movement.isRemovedOnCompletion = false; movement.fillMode = .forwards
            layer.add(movement, forKey: "sheet-exit-transform")
        }
        let dim = CABasicAnimation(keyPath: "backgroundColor")
        dim.fromValue = cover.layer?.presentation()?.backgroundColor ?? cover.layer?.backgroundColor
        dim.toValue = NSColor.clear.cgColor; dim.duration = opacity.duration
        dim.isRemovedOnCompletion = false; dim.fillMode = .forwards
        cover.layer?.add(dim, forKey: "sheet-backdrop-exit")
        CATransaction.commit()
    }

    private func remove(_ cover: NSView, notify: Bool) {
        guard overlay === cover else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        cover.removeFromSuperview(); overlay = nil; card = nil; closing = false
        if let previousResponder, source?.isVisible == true { source?.makeFirstResponder(previousResponder) }
        self.previousResponder = nil
        if notify { onDismiss?() }
    }
}

private final class AssistantSheetCover: NSView {
    weak var card: NSView?
    override func layout() {
        super.layout()
        guard let card else { return }
        let size = card.fittingSize
        card.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                            width: size.width, height: size.height)
    }
    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

private final class AssistantSheetHost: NSHostingView<AnyView> {
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.superview?.needsLayout = true }
    }
}
