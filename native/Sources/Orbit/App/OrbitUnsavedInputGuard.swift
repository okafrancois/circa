import AppKit
import BrowserEngine
import ObjectiveC.runtime

/// A conservative, content-free mark belonging to the live document, including while it moves
/// between owners. Typing need not actually change a form to veto an unattended relaunch.
@MainActor
final class OrbitUnsavedInputGuard: NSObject {
    private static var associationKey: UInt8 = 0
    private static var observedMethods: Set<String> = []
    private var dirty = false
    private var observationFailed = false

    static func register(_ surface: any BrowserEngineSurface) {
        if state(on: surface.hostView) == nil {
            objc_setAssociatedObject(surface.hostView, &associationKey, OrbitUnsavedInputGuard(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        prepare(surface.hostView.window?.firstResponder)
    }

    static func observedBeforeUnload(_ surface: any BrowserEngineSurface) {
        // A dialog proves this document registered a handler. Keep the veto after Stay;
        // the bridge has no notification for handler registration/removal.
        register(surface)
        state(on: surface.hostView)?.dirty = true
    }

    static func paste(into surface: any BrowserEngineSurface) {
        guard let responder = surface.hostView.window?.firstResponder as? NSView,
              responder.isDescendant(of: surface.hostView) else { return }
        prepare(responder)
        state(for: responder)?.dirty = true
    }

    static func clear(_ surface: any BrowserEngineSurface) { state(on: surface.hostView)?.dirty = false }

    static func preventsInstallation(_ surfaces: [any BrowserEngineSurface]) -> Bool {
        surfaces.contains { surface in
            if surface.isDisposed || surface.isSuspended {
                clear(surface)
                return false
            }
            guard let state = state(on: surface.hostView) else { return true }
            return state.dirty || state.observationFailed
        }
    }

    private static func state(on view: NSView) -> OrbitUnsavedInputGuard? {
        objc_getAssociatedObject(view, &associationKey) as? OrbitUnsavedInputGuard
    }

    private static func state(for responder: NSResponder?) -> OrbitUnsavedInputGuard? {
        // AppKit field editors belong to shell controls, including tab-modal page dialogs.
        guard let view = responder as? NSView, !(view is NSText), view.window?.firstResponder === view else { return nil }
        var ancestor: NSView? = view
        while let current = ancestor {
            if let state = state(on: current) { return state }
            ancestor = current.superview
        }
        return nil
    }

    static func keyDown(in window: NSWindow, event: NSEvent) {
        guard event.type == .keyDown else { return }
        prepare(window.firstResponder)
        state(for: window.firstResponder)?.dirty = true
    }

    /// IME candidate commits and menu Paste can arrive without a key event. Observe the actual
    /// responder's public AppKit entry points and forward their arguments unchanged. The hook
    /// is installed once per class/selector; only a registered, focused web descendant is marked.
    /// No text, key value, or pasteboard contents are read or retained.
    static func prepare(_ responder: NSResponder?) {
        guard let state = state(for: responder), let responder, let cls = object_getClass(responder) else { return }
        let insert = NSSelectorFromString("insertText:replacementRange:")
        if responder.responds(to: insert) {
            typealias Original = @convention(c) (AnyObject, Selector, AnyObject, NSRange) -> Void
            observe(cls, selector: insert, state: state) { original in
                let call = unsafeBitCast(original, to: Original.self)
                let block: @convention(block) (AnyObject, AnyObject, NSRange) -> Void = { target, text, range in
                    MainActor.assumeIsolated { Self.state(for: target as? NSResponder)?.dirty = true }
                    call(target, insert, text, range)
                }
                return imp_implementationWithBlock(block)
            }
        }
        for name in ["paste:", "pasteAsPlainText:", "pasteAndMatchStyle:"] {
            let selector = NSSelectorFromString(name)
            guard responder.responds(to: selector) else { continue }
            typealias Original = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            observe(cls, selector: selector, state: state) { original in
                let call = unsafeBitCast(original, to: Original.self)
                let block: @convention(block) (AnyObject, AnyObject?) -> Void = { target, sender in
                    MainActor.assumeIsolated { Self.state(for: target as? NSResponder)?.dirty = true }
                    call(target, selector, sender)
                }
                return imp_implementationWithBlock(block)
            }
        }
    }

    private static func observe(_ cls: AnyClass, selector: Selector, state: OrbitUnsavedInputGuard,
                                replacement: (IMP) -> IMP) {
        let key = NSStringFromClass(cls) + "." + NSStringFromSelector(selector)
        guard !observedMethods.contains(key) else { return }
        guard let method = class_getInstanceMethod(cls, selector), let encoding = method_getTypeEncoding(method) else {
            state.observationFailed = true
            return
        }
        let implementation = replacement(method_getImplementation(method))
        // Add an override for inherited methods instead of changing the superclass's behavior.
        if !class_addMethod(cls, selector, implementation, encoding) {
            method_setImplementation(method, implementation)
        }
        observedMethods.insert(key)
    }
}

final class OrbitBrowserWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        OrbitUnsavedInputGuard.keyDown(in: self, event: event)
        super.sendEvent(event)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted { OrbitUnsavedInputGuard.prepare(firstResponder) }
        return accepted
    }
}
