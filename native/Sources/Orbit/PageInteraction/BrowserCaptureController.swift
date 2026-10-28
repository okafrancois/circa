import AppKit
import BrowserEngine

/// Capture a region of the visible document to the clipboard. Passive snapshots (Peek, swipe,
/// thumbnails) never call the sound service. The source generation is rechecked on acceptance.
@MainActor
final class BrowserCaptureController<Engine: BrowserEngine> {
    weak var owner: BrowserWindowController<Engine>?
    private var overlay: BrowserCaptureSelectionView?
    private var captureID = UUID()
    private weak var source: Engine.Surface?
    private var task: Task<Void, Never>?
    var copyImage: (NSImage) -> Bool = { image in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([image])
    }

    init(owner: BrowserWindowController<Engine>) { self.owner = owner }

    func begin(fullPage: Bool = false) {
        guard overlay == nil, task == nil, let owner, let surface = owner.pageCommandSurface(),
              !surface.isDisposed, owner.window?.attachedSheet == nil,
              !fullPage || owner.engine.capabilities.contains(.fullPageSnapshots) else { return }
        let requestID = UUID()
        captureID = requestID
        source = surface
        let generation = surface.documentGeneration
        task = Task { [weak self, weak owner, weak surface] in
            defer { if self?.captureID == requestID { self?.task = nil } }
            do {
                guard let snapshot = try await surface?.captureSnapshot(.init(documentGeneration: generation, fullPage: fullPage)),
                      !Task.isCancelled, let self, let owner, let surface, owner.pageCommandSurface() === surface,
                      !surface.isDisposed, surface.documentGeneration == generation else { return }
                if fullPage {
                    self.finish(image: snapshot.image, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
                    return
                }
                let view = BrowserCaptureSelectionView(image: snapshot.image)
                view.frame = surface.hostView.bounds
                view.autoresizingMask = [.width, .height]
                view.onFinish = { [weak self, weak surface, weak owner] rect in
                    self?.overlay?.removeFromSuperview()
                    self?.overlay = nil
                    guard let owner, let surface, owner.pageCommandSurface() === surface, !surface.isDisposed,
                          surface.documentGeneration == generation else { return }
                    surface.focusDocument()
                    guard let self, let rect else { return }
                    self.finish(image: snapshot.image, normalizedRect: rect)
                }
                overlay = view
                surface.hostView.addSubview(view)
                owner.window?.makeFirstResponder(view)
            } catch {
                guard !Task.isCancelled, let owner, let surface, owner.pageCommandSurface() === surface,
                      !surface.isDisposed, surface.documentGeneration == generation else { return }
                owner.session.onError?(error)
            }
        }
    }

    func cancel() {
        captureID = UUID()
        task?.cancel()
        task = nil
        overlay?.removeFromSuperview()
        overlay = nil
        source = nil
    }

    func documentDidCommit(_ surface: Engine.Surface) {
        if source === surface { cancel() }
    }

    func finish(image: CGImage, normalizedRect: CGRect) {
        let rect = CGRect(x: normalizedRect.minX * CGFloat(image.width), y: normalizedRect.minY * CGFloat(image.height),
                          width: normalizedRect.width * CGFloat(image.width), height: normalizedRect.height * CGFloat(image.height))
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard rect.width > 1, rect.height > 1, let cropped = image.cropping(to: rect),
              copyImage(NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))) else { return }
        owner?.settingsPreferences?.runtime.feedback.didCapture()
    }
}

@MainActor
final class BrowserCaptureSelectionView: NSView {
    let image: CGImage
    var onFinish: ((CGRect?) -> Void)?
    private var start: NSPoint?
    private var selection = CGRect.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        setAccessibilityLabel(uiText("Drag to capture a portion of this page. Press Escape to cancel."))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(selection)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.3).setFill()
        shade.fill()
        NSColor.white.setStroke()
        NSBezierPath(rect: selection).stroke()
    }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                           width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard selection.width > 1, selection.height > 1, bounds.width > 0, bounds.height > 0 else {
            onFinish?(nil); return
        }
        onFinish?(CGRect(x: selection.minX / bounds.width, y: selection.minY / bounds.height,
                         width: selection.width / bounds.width, height: selection.height / bounds.height))
    }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\u{1b}" { onFinish?(nil) }
        else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onFinish?(nil) }
}
