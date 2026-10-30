import AppKit
import BrowserEngine

/// A menu owns its snapshot and actions only for the lifetime of that presentation.
@MainActor
final class BrowserNavigationHistoryMenu: NSObject {
    enum Direction { case back, forward }
    let menu = NSMenu()
    private let select: (BrowserNavigationEntry, Bool) -> Void

    init(history: BrowserNavigationHistory, direction: Direction,
         favicon: (URL) -> NSImage?, select: @escaping (BrowserNavigationEntry, Bool) -> Void) {
        self.select = select
        super.init()
        menu.autoenablesItems = false
        let entries = history.entries.filter {
            direction == .back ? $0.index < history.currentIndex : $0.index > history.currentIndex
        }.sorted { direction == .back ? $0.index > $1.index : $0.index < $1.index }
        for entry in entries {
            let item = NSMenuItem(title: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                                  action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry
            item.toolTip = entry.url.absoluteString
            let image = (favicon(entry.url) ?? OrbitGlyph.faviconPlaceholder)?.copy() as? NSImage
            image?.size = NSSize(width: 16, height: 16)
            item.image = image
            if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
            menu.addItem(item)
        }
    }

    @objc private func choose(_ item: NSMenuItem) {
        activate(item, modifiers: NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags)
    }

    func activate(_ item: NSMenuItem, modifiers: NSEvent.ModifierFlags) {
        guard let entry = item.representedObject as? BrowserNavigationEntry else { return }
        select(entry, modifiers.contains(.command))
    }
}

/// Uses AppKit's mouse press default, with a monotonic clock injectable for deadline tests.
@MainActor
struct BrowserNavigationHold {
    let delay: TimeInterval
    var now: () -> TimeInterval
    private var deadline: TimeInterval?
    init(delay: TimeInterval = NSPressGestureRecognizer().minimumPressDuration,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.delay = delay
        self.now = now
    }
    mutating func begin() { deadline = now() + delay }
    mutating func cancel() { deadline = nil }
    var remaining: TimeInterval? { deadline.map { max(0, $0 - now()) } }
}

/// Shared event behavior; the existing buttons keep their own drawing and highlighting.
@MainActor
final class BrowserNavigationButtonInteraction {
    var makeMenu: (() -> BrowserNavigationHistoryMenu?)?
    var openAdjacent: (() -> Void)?
    var hold = BrowserNavigationHold()
    var nextEvent: (Date) -> NSEvent? = { deadline in
        NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: deadline,
                        inMode: .eventTracking, dequeue: true)
    }

    func mouseDown(_ event: NSEvent, on button: NSButton) {
        guard button.isEnabled else { return }
        if event.modifierFlags.contains(.control) { showMenu(on: button); return }
        let adjacent = event.modifierFlags.contains(.command)
        button.highlight(true)
        defer { button.highlight(false); hold.cancel() }
        hold.begin()
        while button.window != nil {
            let remaining = adjacent ? nil : hold.remaining
            if remaining == 0 {
                button.highlight(false)
                showMenu(on: button)
                return
            }
            let deadline = remaining.map { Date(timeIntervalSinceNow: $0) } ?? .distantFuture
            guard let next = nextEvent(deadline) else { continue }
            let inside = button.bounds.contains(button.convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                guard inside else { return }
                if adjacent { openAdjacent?() }
                else { _ = button.sendAction(button.action, to: button.target) }
                return
            }
            button.highlight(inside)
            if !inside { hold.cancel() }
        }
    }

    func showMenu(on button: NSButton) {
        guard button.isEnabled, let presentation = makeMenu?(), !presentation.menu.items.isEmpty else { return }
        presentation.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.height : 0), in: button)
        // NSMenuItem's target is weak. Retain the snapshot throughout native menu tracking.
        withExtendedLifetime(presentation) {}
    }

    private var middlePressed = false
    func otherMouseDown(_ event: NSEvent, on button: NSButton) {
        middlePressed = button.isEnabled && event.buttonNumber == 2
    }

    func otherMouseUp(_ event: NSEvent, on button: NSButton) {
        defer { middlePressed = false }
        guard middlePressed, button.isEnabled, event.buttonNumber == 2,
              button.bounds.contains(button.convert(event.locationInWindow, from: nil)) else { return }
        openAdjacent?()
    }
}

final class BrowserNavigationGlyphButton: OrbitGlyphButton {
    let navigation = BrowserNavigationButtonInteraction()
    override func mouseDown(with event: NSEvent) { navigation.mouseDown(event, on: self) }
    override func rightMouseDown(with event: NSEvent) { navigation.showMenu(on: self) }
    override func otherMouseDown(with event: NSEvent) { navigation.otherMouseDown(event, on: self) }
    override func otherMouseUp(with event: NSEvent) { navigation.otherMouseUp(event, on: self) }
}

final class BrowserNavigationImageButton: NSButton {
    let navigation = BrowserNavigationButtonInteraction()
    override func mouseDown(with event: NSEvent) { navigation.mouseDown(event, on: self) }
    override func rightMouseDown(with event: NSEvent) { navigation.showMenu(on: self) }
    override func otherMouseDown(with event: NSEvent) { navigation.otherMouseDown(event, on: self) }
    override func otherMouseUp(with event: NSEvent) { navigation.otherMouseUp(event, on: self) }
}
