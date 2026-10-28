import AppKit
import BrowserCore

struct BrowserBoostPickedElement: Decodable, Equatable {
    struct Rect: Decodable, Equatable { let x: Double, y: Double, width: Double, height: Double }
    let selector: String
    let related: String
    let rect: Rect
    let count: Int
}

/// A transient main-document picker. Only DOM inspection uses script evaluation; persisted
/// styles and scripts are always sent through the profile registration protocol.
@MainActor
final class BrowserBoostZapView: NSView {
    var inspect: ((NSPoint) async throws -> BrowserBoostPickedElement?)?
    var onZap: ((String) -> Void)?
    var onUnzap: ((String) -> Void)?
    var onDone: (() -> Void)?
    var onStop: (() -> Void)?
    var onError: ((Error) -> Void)?
    private var candidate: BrowserBoostPickedElement?
    private var selected = false
    private var ticket = UUID()
    private var task: Task<Void, Never>?
    private weak var trackingWindow: NSWindow?
    private var previouslyAcceptedMoves = false
    private var inputMonitor: Any?
    private let confirmation = NSView()
    private let caption = NSTextField(labelWithString: uiText("Click elements on the page to Zap them"))
    private let done = BoostButton(title: uiText("Done"))
    private var unzapButtons: [BoostButton] = []
    private let selectorLabel = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.borderWidth = 3; layer?.cornerRadius = 3
        layer?.borderColor = NSColor(srgbRed: 0.26, green: 0.21, blue: 1, alpha: 1).cgColor
        confirmation.wantsLayer = true; confirmation.layer?.backgroundColor = NSColor.white.cgColor
        confirmation.layer?.cornerRadius = 18; confirmation.layer?.shadowOpacity = 0.18; confirmation.layer?.shadowRadius = 12
        let zap = BoostButton(title: uiText("Zap this")); zap.fill = .systemRed; zap.contentTintColor = .white
        zap.frame = NSRect(x: 10, y: 42, width: 74, height: 38)
        zap.actionBlock = { [weak self] in self?.confirm(related: false) }
        let related = BoostButton(title: uiText("Zap all related elements")); related.fill = .systemOrange; related.contentTintColor = .white
        related.frame = NSRect(x: 94, y: 42, width: 250, height: 38)
        related.actionBlock = { [weak self] in self?.confirm(related: true) }
        let cancel = BoostButton(title: uiText("Cancel")); cancel.fill = .gray; cancel.contentTintColor = .white
        cancel.frame = NSRect(x: 354, y: 42, width: 65, height: 38)
        cancel.actionBlock = { [weak self] in self?.clear() }
        selectorLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular); selectorLabel.textColor = .secondaryLabelColor
        selectorLabel.frame = NSRect(x: 15, y: 10, width: 395, height: 18)
        for view in [zap, related, cancel, selectorLabel] { confirmation.addSubview(view) }
        addSubview(confirmation); confirmation.isHidden = true
        caption.font = .systemFont(ofSize: 13); caption.alignment = .center
        caption.textColor = NSColor(srgbRed: 0.84, green: 0.84, blue: 1, alpha: 1)
        addSubview(caption)
        done.fill = NSColor(srgbRed: 0.94, green: 0.93, blue: 1, alpha: 1)
        done.actionBlock = { [weak self] in self?.onDone?() }; addSubview(done)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
    }
    override func layout() {
        super.layout()
        done.frame = NSRect(x: max(8, bounds.width - 68), y: bounds.height - 46, width: 58, height: 38)
        caption.frame = NSRect(x: 70, y: bounds.height - 34, width: max(0, bounds.width - 150), height: 22)
        for (index, button) in unzapButtons.enumerated() { button.frame = NSRect(x: 10 + CGFloat(index) * 46, y: bounds.height - 46, width: 38, height: 38) }
    }
    override func mouseMoved(with event: NSEvent) {
        guard !selected else { return }
        let point = convert(event.locationInWindow, from: nil)
        ticket = UUID(); let token = ticket
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(30))
                let result = try await inspect?(point)
                guard !Task.isCancelled, ticket == token, superview != nil else { return }
                candidate = result; needsDisplay = true
            } catch { guard !Task.isCancelled else { return }; onError?(error) }
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, trackingWindow !== window {
            trackingWindow = window; previouslyAcceptedMoves = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true
            // Hosted native documents may own hit testing. Intercept only the exposed page
            // area; the confirmation, Done and unzap controls retain native button dispatch.
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
                guard let self, event.window === self.window, self.superview != nil else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let control = (!self.confirmation.isHidden && self.confirmation.frame.contains(point))
                    || self.done.frame.contains(point) || self.unzapButtons.contains { $0.frame.contains(point) }
                guard !control else { return event }
                if event.type == .leftMouseDown { self.mouseDown(with: event) }
                else { self.mouseMoved(with: event) }
                return nil
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        selected = true
        ticket = UUID(); let token = ticket; task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await inspect?(point)
                guard !Task.isCancelled, ticket == token, superview != nil else { return }
                candidate = result; selected = result != nil; presentConfirmation()
            } catch { onError?(error) }
        }
    }
    private func presentConfirmation() {
        guard let candidate else { return }
        selected = true; needsDisplay = true
        let rect = candidate.rect
        confirmation.frame = NSRect(x: min(max(10, rect.x - 60), max(10, bounds.width - 440)),
            y: min(rect.y + rect.height + 10, bounds.height - 150), width: 429, height: 90)
        selectorLabel.stringValue = "\(candidate.count)   \(candidate.related)"
        confirmation.isHidden = false
    }
    override func cancelOperation(_ sender: Any?) { if selected { clear() } else { onDone?() } }
    override func draw(_ dirtyRect: NSRect) {
        guard let rect = candidate?.rect else { return }
        let path = NSBezierPath(roundedRect: NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), xRadius: 2, yRadius: 2)
        NSColor.systemYellow.withAlphaComponent(selected ? 0.65 : 0.25).setFill(); path.fill()
        NSColor.systemYellow.setStroke(); path.lineWidth = 3; path.stroke()
    }
    func renderZaps(_ selectors: [String]) {
        for button in unzapButtons { button.removeFromSuperview() }; unzapButtons = []
        for selector in selectors {
            let button = BoostButton(symbol: "rectangle.slash", label: uiText("Click to unzap"))
            button.actionBlock = { [weak self] in self?.onUnzap?(selector) }
            addSubview(button); unzapButtons.append(button)
        }
        caption.stringValue = selectors.isEmpty ? uiText("Click elements on the page to Zap them") : uiText("← Click to unzap")
        needsLayout = true
    }
    func stop() {
        let heldFocus = (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
        task?.cancel(); ticket = UUID()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
        trackingWindow?.acceptsMouseMovedEvents = previouslyAcceptedMoves
        trackingWindow = nil; removeFromSuperview()
        if heldFocus { onStop?() }
    }
    private func confirm(related: Bool) {
        guard let candidate else { return }
        onZap?(related ? candidate.related : candidate.selector); clear()
    }
    private func clear() { selected = false; candidate = nil; confirmation.isHidden = true; needsDisplay = true }

    static func script(at point: NSPoint, zoom: Double) -> String {
        let x = max(0, point.x / max(0.25, zoom)), y = max(0, point.y / max(0.25, zoom))
        return """
        (() => {
          const element = document.elementFromPoint(\(x), \(y));
          if (!element || element === document.documentElement) return null;
          const part = e => e.id && document.querySelectorAll('#' + CSS.escape(e.id)).length === 1
            ? '#' + CSS.escape(e.id) : e.localName + ':nth-child(' + (Array.from(e.parentElement?.children || []).indexOf(e) + 1) + ')';
          const path = e => {
            let result = part(e), parent = e.parentElement;
            while (parent && document.querySelectorAll(result).length !== 1) {
              result = part(parent) + ' > ' + result; parent = parent.parentElement;
            }
            return result;
          };
          const selector = path(element);
          if (document.querySelector(selector) !== element) return null;
          const classes = Array.from(element.classList).map(c => '.' + CSS.escape(c)).join('');
          const related = (element.parentElement ? path(element.parentElement) + ' > ' : '') + element.localName + classes;
          const r = element.getBoundingClientRect(), scale = \(zoom);
          return JSON.stringify({selector, related, count: document.querySelectorAll(related).length,
            rect: {x:r.x*scale, y:r.y*scale, width:r.width*scale, height:r.height*scale}});
        })()
        """
    }
}
