import AppKit
import BrowserCore

/// Hover is observational: it never selects a tab, changes the responder, or changes calendar data.
@MainActor
final class CalendarPreviewController {
    var sidebarOnRight = false
    let view = CalendarPreviewView()
    weak var anchor: NSView?
    private var tab: BrowserOrganizationTabItem?
    var account: BrowserCalendarWebAccount?
    var permitted: (NSView, BrowserOrganizationTabItem, BrowserCalendarWebAccount) -> Bool = { _, _, _ in false }
    var agenda: (BrowserCalendarWebAccount) -> BrowserCalendarWebAgenda? = { _ in nil }
    var refresh: (BrowserCalendarWebAccount) -> Void = { _ in }
    var menu: (BrowserOrganizationTabItem, BrowserCalendarWebAccount) -> NSMenu? = { _, _ in nil }
    var open: (BrowserOrganizationTabItem, BrowserCalendarWebAccount, String?) -> Void = { _, _, _ in }
    private var timer: (any OrbitCancellable)?
    private var departure: (any OrbitCancellable)?
    private var monitor: Any?
    private var observations: [NSObjectProtocol] = []
    private var anchorFrame: NSRect = .zero
    private var armed = false
    private var epoch: UInt64 = 0
    private var container: NSView?
    var isPresented: Bool { container != nil }
    var onPresentationChange: (() -> Void)?

    init() {
        view.onPointer = { [weak self] inside in
            if inside { self?.departure?.cancel(); self?.departure = nil }
            else { self?.leave() }
        }
        view.onAdd = { [weak self] in self?.choose(nil) }
        view.onMenu = { [weak self] in
            guard let self, let tab = self.tab, let account = self.account else { return nil }
            return self.menu(tab, account)
        }
    }

    func hover(_ tile: FavoriteTileView, inside: Bool) {
        hover(tile, tab: tile.item.tab, inside: inside)
    }

    func hover(_ tile: NSView, tab: BrowserOrganizationTabItem, inside: Bool) {
        if !inside { if anchor === tile { leave() }; return }
        if anchor === tile, self.tab?.id == tab.id { departure?.cancel(); departure = nil; return }
        dismiss()
        guard let account = BrowserCalendarWebAccount(url: tab.pinnedURL ?? tab.url), permitted(tile, tab, account) else { return }
        anchor = tile; self.tab = tab; self.account = account
        anchorFrame = tile.convert(tile.visibleRect, to: nil)
        refresh(account)
        let token = epoch
        timer = OrbitRunLoopTimer(after: 0.29) { [weak self] in
            guard let self, self.epoch == token else { return }
            self.armed = true; self.reconcile()
        }
    }

    func reconcile() {
        guard let tile = anchor, let tab, let account else { return }
        guard validate(tile, tab, account) else { dismiss(); return }
        guard armed, let agenda = agenda(account), agenda.isFresh(at: Date()) else {
            if isPresented { dismiss() }
            return
        }
        if container == nil { view.clear() }
        view.render(agenda)
        if container == nil { show(tile) }
        layout(tile)
    }

    private func validate(_ tile: NSView, _ tab: BrowserOrganizationTabItem, _ account: BrowserCalendarWebAccount) -> Bool {
        let enabled = (tile as? FavoriteTileView)?.commandsEnabled
            ?? (tile as? SidebarListRow).map { $0.commandsEnabled && !$0.isRenaming && !$0.isLeaving } ?? false
        let identity = (tile as? FavoriteTileView)?.item.tab.id ?? (tile as? SidebarTabRow)?.item.id
        return enabled && identity == tab.id && NSApp.isActive && tile.window?.isKeyWindow == true && tile.window?.attachedSheet == nil
            && !tile.isHiddenOrHasHiddenAncestor && !tile.visibleRect.isEmpty
            && tile.convert(tile.visibleRect, to: nil) == anchorFrame && permitted(tile, tab, account)
    }

    private func show(_ tile: NSView) {
        guard let window = tile.window, let host = window.contentView else { return }
        let container = NSView()
        container.wantsLayer = true
        container.clipsToBounds = false
        container.layer?.masksToBounds = false
        tile.effectiveAppearance.performAsCurrentDrawingAppearance {
            container.layer?.backgroundColor = OrbitTokens.Color.Calendar.shell.cgColor
        }
        container.layer?.cornerRadius = 12
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = .init(width: 0, height: -6)
        container.shadow = shadow
        container.addSubview(view)
        host.addSubview(container, positioned: .above, relativeTo: nil)
        self.container = container
        container.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.06
            container.animator().alphaValue = 1
        }
        onPresentationChange?()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.window === self.anchor?.window else { self.dismiss(); return event }
                if event.keyCode == 53 { self.dismiss(); return nil }
                self.dismiss()
            } else if let container = self.container {
                let point = container.convert(event.locationInWindow, from: nil)
                if event.window !== container.window || !container.bounds.contains(point) { self.dismiss() }
            }
            return event
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                     NSWindow.didResignKeyNotification, NSWindow.willBeginSheetNotification,
                     NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })

    }

    private func layout(_ tile: NSView) {
        guard let container, let host = container.superview else { return }
        let anchor = tile.convert(tile.bounds, to: host)
        let width = min(239, host.bounds.width - 16)
        let height = min(view.contentHeight, host.bounds.height - 16)
        let preferredX = sidebarOnRight ? anchor.minX - width + 4 : anchor.maxX - 4
        let x = min(max(host.bounds.minX + 8, preferredX), host.bounds.maxX - width - 8)
        let wantedY = host.isFlipped ? anchor.maxY - 4 : anchor.minY + 4 - height
        let y = max(host.bounds.minY + 8, min(wantedY, host.bounds.maxY - height - 8))
        container.frame = .init(x: x, y: y, width: width, height: height)
        container.layer?.shadowPath = CGPath(roundedRect: container.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        view.frame = container.bounds
    }

    private func leave() {
        if !armed && !isPresented { dismiss(); return }
        departure?.cancel()
        let token = epoch
        departure = OrbitRunLoopTimer(after: 0.033) { [weak self] in
            guard let self, self.epoch == token else { return }
            self.dismiss(animated: true)
        }
    }

    private func choose(_ id: String?) {
        guard let tile = anchor, let tab, let account, validate(tile, tab, account),
              id == nil else { dismiss(); return }
        open(tab, account, id)
        dismiss()
    }

    func dismiss(animated: Bool = false) {
        let wasPresented = isPresented
        epoch &+= 1
        timer?.cancel(); timer = nil; departure?.cancel(); departure = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        for observation in observations { NotificationCenter.default.removeObserver(observation) }
        observations.removeAll()
        if let old = container, animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.05; old.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    if self?.view.superview === old { self?.view.removeFromSuperview(); self?.view.clear() }
                    old.removeFromSuperview()
                }
            })
        } else {
            view.removeFromSuperview(); view.clear(); container?.removeFromSuperview()
        }
        container = nil
        anchor = nil; tab = nil; account = nil; armed = false
        if wasPresented { onPresentationChange?() }
    }
}
