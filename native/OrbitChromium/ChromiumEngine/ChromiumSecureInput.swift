import AppKit
import BrowserEngine
import Carbon.HIToolbox
import OrbitChromiumBridge

/// Process-wide focus safety net, covering hosted tabs, auxiliary windows and detached views.
/// Chromium owns the secure-input scope; reconciliation asks it to release that scope rather
/// than calling DisableSecureEventInput behind its counter's back.
@MainActor
final class ChromiumSecureInput {
    private(set) var reconcileTicks = 0
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var reconciling = false
    private weak var focusedSurface: ChromiumSurface?
    private weak var runtime: ChromiumRuntime?

    init(runtime: ChromiumRuntime) {
        self.runtime = runtime
        let center = NotificationCenter.default
        for name in [NSApplication.willResignActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didBecomeActiveNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.willCloseNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let inactive = note.name == NSApplication.willResignActiveNotification
                    || note.name == NSApplication.didResignActiveNotification
                let losingWindow = note.name == NSWindow.didResignKeyNotification
                    || note.name == NSWindow.didMiniaturizeNotification || note.name == NSWindow.willCloseNotification
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    self?.reconcile(forceInactive: inactive || (losingWindow && window === self?.focusedSurface?.documentView.window))
                }
            })
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        // Discover an existing responder once when restoring the synthetic owner probe.
        for surface in runtime.registeredSurfaces where surface.ownsKeyResponder {
            focusedSurface = surface
            break
        }
        reconcile()
    }

    func focusChanged(_ surface: ChromiumSurface) {
        if surface.ownsKeyResponder {
            if focusedSurface !== surface { focusedSurface?.reconcileSecureInput(forceInactive: true, enabled: IsSecureEventInputEnabled()) }
            focusedSurface = surface
        }
        if focusedSurface === surface { reconcile() }
    }

    private func reconcile(forceInactive: Bool = false) {
        guard !reconciling, let runtime, !runtime.isQuitting else { return }
        let enabled = IsSecureEventInputEnabled()
        guard let focusedSurface, enabled || focusedSurface.secureInputNeedsFocusRestore || forceInactive else {
            timer?.invalidate()
            timer = nil
            return
        }
        reconcileTicks += 1
        reconciling = true
        defer { reconciling = false }
        focusedSurface.reconcileSecureInput(forceInactive: forceInactive, enabled: enabled)
        let poll = BrowserSecureInputPolling.shouldPoll(applicationActive: NSApp.isActive && !forceInactive,
            hasFocusedSurface: self.focusedSurface?.ownsKeyResponder == true,
            secureInputEnabled: IsSecureEventInputEnabled())
        if !poll {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            // CEF has no native focused-node callback in the browser process. While a
            // password owns input, cover geometry changes and delayed renderer updates.
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
            timer.tolerance = 0.05
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
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
    func secureInputDocumentWillChange() {
        guard ownsKeyResponder, IsSecureEventInputEnabled() else { return }
        // Drop the outgoing document's scope before its replacement can inherit it.
        // Keep the AppKit responder, restoring engine focus once the new document loads.
        secureInputNavigating = true
        secureInputFocusChanged()
    }

    func secureInputDocumentDidLoad() {
        guard secureInputNavigating else { return }
        secureInputNavigating = false
        secureInputFocusChanged()
    }

    var ownsKeyResponder: Bool {
        guard let window = documentView.window, window.isKeyWindow,
              let responder = window.firstResponder as? NSView, let engineContentView else { return false }
        return responder.isDescendant(of: engineContentView)
    }

    func secureInputFocusChanged() { engine?.runtime.secureInputFocusChanged(self) }

    func releaseSecureInputFocus() {
        if isReady { _ = ACRSetFocus(token, 0) }
        if let window = documentView.window, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: documentView) {
            window.makeFirstResponder(nil)
        }
        secureInputFocusChanged()
    }

    func reconcileSecureInput(forceInactive: Bool, enabled: Bool) {
        guard isReady, !isDisposed else { return }
        let window = documentView.window
        let responder = window?.firstResponder as? NSView
        let intersectsWindow = window?.contentView.map { content in
            !documentView.convert(documentView.bounds, to: content).intersection(content.bounds).isEmpty
        } == true
        let intersectsScreen = window.map { window in
            NSScreen.screens.contains { !$0.frame.intersection(window.frame).isEmpty }
        } == true
        let focus = BrowserSecureInputFocus(applicationActive: NSApp.isActive && !forceInactive,
            windowKey: window?.isKeyWindow == true, windowVisible: window?.isVisible == true && window?.isMiniaturized == false && window?.isOnActiveSpace == true && intersectsScreen,
            viewVisible: window != nil && !documentView.isHiddenOrHasHiddenAncestor && !documentView.visibleRect.isEmpty && intersectsWindow && !secureInputHostHidden,
            responderInSurface: engineContentView.map { responder?.isDescendant(of: $0) == true } == true, retired: isSuspended || secureInputNavigating)
        if let active = secureInputReconciliation.update(eligible: focus.permitsSecureInput, secureInputEnabled: enabled) {
            secureInputNeedsFocusRestore = !active
            _ = ACRSetFocus(token, active ? 1 : 0)
        }
    }
}
