import AppKit
import QuartzCore
import SwiftUI

extension View {
    func assistantPopover<Content: View>(isPresented: Binding<Bool>, trailing: Bool = false,
                                        @ViewBuilder content: () -> Content) -> some View {
        background(AssistantPopoverAnchor(isPresented: isPresented, trailing: trailing, content: content()))
    }
}

private struct AssistantPopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let trailing: Bool
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduced

    func makeCoordinator() -> BrowserAssistantPopover { BrowserAssistantPopover() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let binding = $isPresented
        context.coordinator.onDismiss = { binding.wrappedValue = false }
        if isPresented {
            context.coordinator.show(from: view, trailing: trailing, content: AnyView(content),
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

    static func frame(anchor: NSRect, size: NSSize, visible: NSRect, trailing: Bool) -> NSRect {
        let width = min(size.width, max(1, visible.width - 16))
        let height = min(size.height, max(1, visible.height - 16))
        let x = trailing ? anchor.maxX - width : anchor.minX
        let y = anchor.maxY + 6 + height <= visible.maxY - 8
            ? anchor.maxY + 6 : anchor.minY - 6 - height
        return NSRect(x: max(visible.minX + 8, min(x, visible.maxX - 8 - width)),
                      y: max(visible.minY + 8, min(y, visible.maxY - 8 - height)),
                      width: width, height: height)
    }

    func show(from anchor: NSView, trailing: Bool, content: AnyView, reduced: Bool) {
        if let host { host.rootView = content; return }
        guard let source = anchor.window, source.isVisible,
              let screen = source.screen else { return }
        let host = NSHostingView(rootView: content)
        host.sizingOptions = [.intrinsicContentSize]
        let anchorFrame = source.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let frame = Self.frame(anchor: anchorFrame, size: host.fittingSize,
                               visible: screen.visibleFrame, trailing: trailing)
        let panel = AssistantMenuPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("assistant-popup")
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.appearance = anchor.effectiveAppearance
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        let background = NSView(frame: NSRect(origin: .zero, size: frame.size))
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        OrbitFloatingMaterial.install(in: background, blending: .behindWindow, radius: 10)
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
        animate(background, anchor: anchorFrame, panelFrame: frame, trailing: trailing, reduced: reduced)
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

    private func animate(_ view: NSView, anchor: NSRect, panelFrame: NSRect, trailing: Bool, reduced: Bool) {
        guard let layer = view.layer else { return }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = reduced ? 0.15 : 0.16
        opacity.timingFunction = reduced ? CAMediaTimingFunction(name: .linear)
            : CAMediaTimingFunction(controlPoints: 1 / 3, 1, 2 / 3, 1)
        layer.add(opacity, forKey: "assistant-entry-opacity")
        guard !reduced else { return }
        let origin = CGPoint(x: trailing ? panelFrame.width : 0,
                             y: anchor.midY < panelFrame.midY ? 0 : panelFrame.height)
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
}
