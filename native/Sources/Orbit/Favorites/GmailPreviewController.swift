import AppKit
import BrowserCore

/// Hover is observational: it never selects a tab, changes the responder, or marks mail as read.
@MainActor
final class GmailPreviewController {
    var sidebarOnRight = false
    let view = GmailPreviewView()
    weak var anchor: NSView?
    private var tab: BrowserOrganizationTabItem?
    var account: BrowserGmailAccount?
    var permitted: (NSView, BrowserOrganizationTabItem, BrowserGmailAccount) -> Bool = { _, _, _ in false }
    var inbox: (BrowserGmailAccount) -> BrowserGmailInbox? = { _ in nil }
    var refresh: (BrowserGmailAccount) -> Void = { _ in }
    var open: (BrowserOrganizationTabItem, BrowserGmailAccount, URL) -> Void = { _, _, _ in }
    private var timer: (any OrbitCancellable)?
    private let hoverPopover = SidebarHoverPopover(closeDelay: 0.18)
    var containsPointer: Bool { hoverPopover.containsPointer }
    private var armed = false
    private var epoch: UInt64 = 0
    private var container: SidebarHoverPopoverSurface?
    var isPresented: Bool { container != nil }
    var onPresentationChange: (() -> Void)?

    init() {
        hoverPopover.onDismiss = { [weak self] _ in self?.dismiss() }
        hoverPopover.onResize = { [weak self] in self?.reconcile() }
        view.onMessage = { [weak self] id in self?.choose(id) }
        view.onCompose = { [weak self] in self?.choose(nil) }
    }

    func hover(_ tile: FavoriteTileView, inside: Bool) {
        hover(tile, tab: tile.item.tab, inside: inside)
    }

    func hover(_ tile: NSView, tab: BrowserOrganizationTabItem, inside: Bool) {
        if !inside {
            if anchor === tile {
                if isPresented { hoverPopover.update() }
                else { dismiss() }
            }
            return
        }
        guard (tile.window as? OrbitBrowserWindow)?.isRestoringPopoverHover != true else { return }
        if (anchor === tile && self.tab?.id == tab.id) || containsPointer { return }
        dismiss()
        guard let account = BrowserGmailAccount(url: tab.pinnedURL ?? tab.url), permitted(tile, tab, account) else { return }
        anchor = tile; self.tab = tab; self.account = account
        refresh(account)
        let token = epoch
        timer = OrbitRunLoopTimer(after: 0.3) { [weak self] in
            guard let self, self.epoch == token else { return }
            self.armed = true; self.reconcile()
        }
    }

    func reconcile() {
        guard let tile = anchor, let tab, let account else { return }
        guard validate(tile, tab, account) else { dismiss(); return }
        guard armed, let inbox = inbox(account) else {
            if isPresented { dismiss() }
            return
        }
        view.render(inbox)
        if container == nil { show(tile) }
        else { layout(tile) }
    }

    private func validate(_ tile: NSView, _ tab: BrowserOrganizationTabItem, _ account: BrowserGmailAccount) -> Bool {
        let enabled = (tile as? FavoriteTileView)?.commandsEnabled
            ?? (tile as? SidebarListRow).map { $0.commandsEnabled && !$0.isRenaming && !$0.isLeaving } ?? false
        let identity = (tile as? FavoriteTileView)?.item.tab.id ?? (tile as? SidebarTabRow)?.item.id
        return enabled && identity == tab.id && NSApp.isActive && tile.window?.isKeyWindow == true && tile.window?.attachedSheet == nil
            && !tile.isHiddenOrHasHiddenAncestor && !tile.visibleRect.isEmpty
            && permitted(tile, tab, account)
    }

    private func show(_ tile: NSView) {
        guard let window = tile.window, let host = window.contentView else { return }
        let container = SidebarHoverPopoverSurface()
        container.wantsLayer = true
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.22
        container.layer?.shadowRadius = 14
        container.layer?.shadowOffset = .init(width: 0, height: -6)
        container.scrollReceiver = view.scroll
        container.pointerReceiver = view.updatePointerTarget
        container.addSubview(view)
        host.addSubview(container, positioned: .above, relativeTo: nil)
        self.container = container
        layout(tile)
        (tile as? FavoriteTileView)?.suppressesTitleTooltip = true
        hoverPopover.start(trigger: tile, popover: container)
        onPresentationChange?()
    }

    private func layout(_ tile: NSView) {
        guard let container, let host = container.superview else { return }
        let anchor = tile.convert(tile.bounds, to: host)
        let width = min(GmailPreviewMetrics.width, host.bounds.width - 16)
        let height = min(view.contentHeight, host.bounds.height - 16)
        let preferredX = sidebarOnRight ? anchor.minX - width + 4 : anchor.maxX - 4
        let x = min(max(host.bounds.minX + 8, preferredX), host.bounds.maxX - width - 8)
        let wantedY = host.isFlipped ? anchor.maxY - 4 : anchor.minY + 4 - height
        let y = max(host.bounds.minY + 8, min(wantedY, host.bounds.maxY - height - 8))
        container.frame = .init(x: x, y: y, width: width, height: height)
        view.frame = container.bounds
    }

    private func choose(_ id: String?) {
        defer { dismiss() }
        guard let tile = anchor, let tab, let account, validate(tile, tab, account) else { return }
        if let id {
            guard let message = inbox(account)?.messages.first(where: { $0.id == id }),
                  let url = account.messageURL(for: message) else { return }
            open(tab, account, url)
        } else {
            open(tab, account, account.composeURL)
        }
    }

    func dismiss() {
        let wasPresented = isPresented
        epoch &+= 1
        timer?.cancel(); timer = nil
        hoverPopover.stop()
        (anchor as? FavoriteTileView)?.suppressesTitleTooltip = false
        view.removeFromSuperview(); view.clear(); container?.removeFromSuperview(); container = nil
        anchor = nil; tab = nil; account = nil; armed = false
        if wasPresented { onPresentationChange?() }
    }
}
