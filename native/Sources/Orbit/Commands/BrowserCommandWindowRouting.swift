import AppKit
import BrowserShell

struct BrowserCommandWindowRoute {
    let windowID: UUID?
    let allowsMissingWindowCreation: Bool
    var restorableWindowID: UUID? = nil
    var allowsMissingWindowHandling: Bool { allowsMissingWindowCreation || restorableWindowID != nil }
}

/// Shared by production composition and hidden tests. A newly requested window retains its
/// command queue while its predecessor is still key. An auxiliary key window never lends a
/// ready background browser window to a command, nor reinterprets it as a missing window.
@MainActor
enum BrowserCommandWindowRouting {
    static func route<Window>(router: BrowserWindowRouter<Window>, keyWindow: NSWindow?,
                              nativeWindow: (Window) -> NSWindow?) -> BrowserCommandWindowRoute {
        let missing = router.windows.isEmpty && !router.hasPendingWindow
        let keyID = keyWindow.flatMap { key in router.windows.first { nativeWindow($0.value) === key }?.key }
        if keyWindow != nil && keyID == nil {
            return .init(windowID: nil, allowsMissingWindowCreation: missing)
        }
        if router.hasPendingWindow {
            return .init(windowID: router.selectedWindowID, allowsMissingWindowCreation: false)
        }
        if (keyWindow == nil || keyWindow?.isMiniaturized == true), let selected = router.selectedWindowID,
           !router.windows.isEmpty,
           router.windows.values.allSatisfy({ nativeWindow($0)?.isMiniaturized == true }) {
            return .init(windowID: nil, allowsMissingWindowCreation: false, restorableWindowID: selected)
        }
        return .init(windowID: keyID, allowsMissingWindowCreation: missing)
    }
    /// Used only by the explicitly registered New Tab/Command Bar missing-window handlers.
    /// Restoring a minimized window must not make unrelated document commands target it.
    @discardableResult
    static func performWhenWindowMissing<Window>(router: BrowserWindowRouter<Window>, keyWindow: NSWindow?,
        nativeWindow: @escaping (Window) -> NSWindow?, action: @escaping (Window) -> Void,
        create: () -> Void) -> Bool {
        let route = route(router: router, keyWindow: keyWindow, nativeWindow: nativeWindow)
        if let id = route.restorableWindowID {
            router.perform(in: id) { window in
                nativeWindow(window)?.deminiaturize(nil)
                action(window)
            }
            return true
        }
        guard route.allowsMissingWindowCreation else { return false }
        create()
        return true
    }

}
