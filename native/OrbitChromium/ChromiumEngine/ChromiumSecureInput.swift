import AppKit
import BrowserEngine
import Carbon.HIToolbox
import OrbitChromiumBridge

/// Process-wide focus safety net, covering hosted tabs, auxiliary windows and detached views.
/// Chromium owns the secure-input scope; reconciliation asks it to release that scope rather
/// than calling DisableSecureEventInput behind its counter's back.
@MainActor
final class ChromiumSecureInput {
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var reconciling = false
    private weak var runtime: ChromiumRuntime?

    init(runtime: ChromiumRuntime) {
        self.runtime = runtime
        let center = NotificationCenter.default
        for name in [NSApplication.willResignActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didBecomeActiveNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.willCloseNotification, NSApplication.didUpdateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let inactive = note.name == NSApplication.willResignActiveNotification
                    || note.name == NSApplication.didResignActiveNotification
                MainActor.assumeIsolated {
                    self?.reconcile(forceInactive: inactive)
                }
            })
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        // Also catch renderer-driven state changes after deactivation, without reading DOM
        // values or touching another process's secure-input ownership.
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func reconcile(forceInactive: Bool = false) {
        guard !reconciling, let runtime, !runtime.isQuitting else { return }
        reconciling = true
        defer { reconciling = false }
        let enabled = IsSecureEventInputEnabled()
        for surface in runtime.registeredSurfaces {
            surface.reconcileSecureInput(forceInactive: forceInactive, enabled: enabled)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
    }
}

extension ChromiumSurface {
    func releaseSecureInputFocus() {
        if isReady { _ = ACRSetFocus(token, 0) }
        if let window = hostView.window, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: hostView) {
            window.makeFirstResponder(nil)
        }
    }

    func reconcileSecureInput(forceInactive: Bool, enabled: Bool) {
        guard isReady, !isDisposed else { return }
        let window = hostView.window
        let responder = window?.firstResponder as? NSView
        let intersectsWindow = window?.contentView.map { content in
            !hostView.convert(hostView.bounds, to: content).intersection(content.bounds).isEmpty
        } == true
        let intersectsScreen = window.map { window in
            NSScreen.screens.contains { !$0.frame.intersection(window.frame).isEmpty }
        } == true
        let focus = BrowserSecureInputFocus(applicationActive: NSApp.isActive && !forceInactive,
            windowKey: window?.isKeyWindow == true, windowVisible: window?.isVisible == true && window?.isMiniaturized == false && window?.isOnActiveSpace == true && intersectsScreen,
            viewVisible: window != nil && !hostView.isHiddenOrHasHiddenAncestor && !hostView.visibleRect.isEmpty && intersectsWindow && !secureInputHostHidden,
            responderInSurface: engineContentView.map { responder?.isDescendant(of: $0) == true } == true, retired: isSuspended)
        if let active = secureInputReconciliation.update(eligible: focus.permitsSecureInput, secureInputEnabled: enabled) {
            _ = ACRSetFocus(token, active ? 1 : 0)
        }
    }
}
