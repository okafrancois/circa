import AppKit

/// One event-turn cache shared by the monitor and menu route. Scope, enablement and the
/// selected document are always revalidated. Only normalization/native matching is reused.
@MainActor
final class BrowserShortcutEventCache {
    private weak var event: NSEvent?
    private var input: BrowserShortcutEvent?
    private var cleanupScheduled = false
    private(set) var normalizationCount = 0

    func normalized(_ event: NSEvent, isComposing: Bool = false) -> BrowserShortcutEvent? {
        guard !isComposing, BrowserShortcut.canRoute(event) else { return nil }
        if self.event === event { return input }
        normalizationCount += 1
        self.event = event
        input = BrowserShortcutEvent(event)
        if !cleanupScheduled {
            cleanupScheduled = true
            DispatchQueue.main.async { [weak self] in self?.clear() }
        }
        return input
    }

    func clear() {
        event = nil
        input = nil
        cleanupScheduled = false
    }
}
