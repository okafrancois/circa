import AppKit

/// Application activation is independent of window visibility. In particular, hiding must
/// not manufacture a departure, and hiding an existing session must preserve its ownership.
@MainActor
final class BrowserAutomaticPiPActivation {
    struct Context {
        var ownsActiveWindow: Bool
        var isHidden: Bool
        var isMiniaturized: Bool
        var isActive: Bool
    }

    private let center: NotificationCenter
    private let context: () -> Context
    private let changed: () -> Void
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var departure: Task<Void, Never>?
    private var wasActiveWindow = false
    private var isHiding = false
    private(set) var isAway = false

    init(center: NotificationCenter = .default, context: @escaping () -> Context,
         changed: @escaping () -> Void) {
        self.center = center
        self.context = context
        self.changed = changed
        observe(NSApplication.willResignActiveNotification) { coordinator in
            coordinator.wasActiveWindow = coordinator.context().ownsActiveWindow
        }
        observe(NSApplication.willHideNotification) { coordinator in
            coordinator.isHiding = true
            coordinator.departure?.cancel()
        }
        observe(NSApplication.didUnhideNotification) { $0.isHiding = false }
        observe(NSApplication.didResignActiveNotification) { $0.resignedActive() }
        observe(NSApplication.didBecomeActiveNotification) { coordinator in
            coordinator.departure?.cancel()
            coordinator.wasActiveWindow = false
            coordinator.setAway(false)
        }
    }

    deinit { for observer in observers { center.removeObserver(observer) } }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor (BrowserAutomaticPiPActivation) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }

    private func resignedActive() {
        let ownsWindow = wasActiveWindow || context().ownsActiveWindow
        wasActiveWindow = false
        departure?.cancel()
        // Let AppKit finish its hide/minimize bookkeeping before admitting a departure.
        departure = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            let current = context()
            guard ownsWindow, !isHiding, !current.isHidden, !current.isMiniaturized,
                  !current.isActive else { return }
            setAway(true)
        }
    }

    private func setAway(_ value: Bool) {
        guard isAway != value else { return }
        isAway = value
        changed()
    }
}
