import AppKit
import BrowserShell

@MainActor
final class BrowserBoostCodeView: NSView, NSTextViewDelegate {
    let session: BrowserBoostEditorSession
    var onBack: (() -> Void)?
    var requestJavaScriptConsent: ((@escaping (Bool) -> Void) -> Void)?
    private let canvas = LibraryFlippedView()
    private let css = BoostButton(title: uiText("CSS"))
    private let js = BoostButton(title: uiText("JS"))
    let textView = NSTextView()
    private let scroll = NSScrollView()
    private(set) var isCSS = true
    private(set) var selectionTask: Task<Void, Never>?

    init(session: BrowserBoostEditorSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 588))
        wantsLayer = true; layer?.cornerRadius = 12; layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.white.cgColor
        canvas.frame = bounds; addSubview(canvas)
        let header = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 40))
        header.wantsLayer = true; header.layer?.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1).cgColor
        canvas.addSubview(header)
        let separator = NSView(frame: NSRect(x: 0, y: 39.5, width: 480, height: 0.5))
        separator.wantsLayer = true; separator.layer?.backgroundColor = NSColor(calibratedWhite: 0.88, alpha: 1).cgColor
        canvas.addSubview(separator)
        let back = BoostButton(title: uiText("←  Back")); back.fill = .clear
        back.actionBlock = { [weak self] in self?.onBack?() }
        back.frame = NSRect(x: 12, y: 6, width: 60, height: 28); canvas.addSubview(back)
        let tabs = NSView(frame: NSRect(x: 190, y: 8, width: 100, height: 24))
        tabs.wantsLayer = true; tabs.layer?.cornerRadius = 6; tabs.layer?.masksToBounds = true
        tabs.layer?.backgroundColor = NSColor(calibratedWhite: 0.9, alpha: 1).cgColor
        css.frame = NSRect(x: 0, y: 0, width: 50, height: 24)
        js.frame = NSRect(x: 50, y: 0, width: 50, height: 24)
        css.actionBlock = { [weak self] in self?.selectCSS(true) }
        js.actionBlock = { [weak self] in self?.selectCSS(false) }
        tabs.addSubview(css); tabs.addSubview(js); canvas.addSubview(tabs)
        scroll.frame = NSRect(x: 0, y: 40, width: 480, height: 480)
        scroll.wantsLayer = true; scroll.layer?.masksToBounds = true
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        textView.isRichText = false; textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = NSColor(srgbRed: 0.4, green: 0.4, blue: 0.53, alpha: 1)
        textView.backgroundColor = NSColor(calibratedWhite: 0.99, alpha: 1)
        textView.textContainerInset = NSSize(width: 20, height: 12)
        textView.minSize = NSSize(width: 432, height: 480)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = textView.maxSize
        textView.frame = NSRect(x: 0, y: 0, width: 432, height: 480)
        textView.delegate = self
        scroll.documentView = textView
        scroll.verticalRulerView = BrowserBoostLineNumbers(textView: textView, scrollView: scroll)
        scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        canvas.addSubview(scroll)
        display(css: true)
    }

    func selectCSS(_ selected: Bool) {
        guard !session.isClosed else { return }
        // Wait for accepted source edits before reading the other buffer.
        let pending = session.pending
        selectionTask = Task { [weak self] in
            await pending?.value
            guard let self, !session.isClosed else { return }
            if !selected && !session.boost.javaScriptOptIn {
                requestJavaScriptConsent? { [weak self] accepted in
                    guard let self, accepted, !session.isClosed else { return }
                    session.setJavaScriptConsent(true)
                    display(css: false)
                }
            } else { display(css: selected) }
        }
    }

    private func display(css selected: Bool) {
        isCSS = selected
        css.fill = selected ? .controlAccentColor : .clear; css.contentTintColor = selected ? .white : .darkGray
        js.fill = selected ? .clear : .controlAccentColor; js.contentTintColor = selected ? .darkGray : .white
        textView.string = selected ? session.boost.content.customCSS : session.boost.content.customJavaScript
        textView.setAccessibilityLabel(selected ? uiText("CSS") : uiText("JS"))
        scroll.verticalRulerView?.needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        let source = textView.string, css = isCSS
        session.edit { if css { $0.customCSS = source } else { $0.customJavaScript = source } }
        scroll.verticalRulerView?.needsDisplay = true
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); canvas.frame.origin.x = (bounds.width - 480) / 2 }
}

@MainActor
private final class BrowserBoostLineNumbers: NSRulerView {
    weak var textView: NSTextView?
    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView; ruleThickness = 48
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let manager = textView.layoutManager, let container = textView.textContainer else { return }
        textView.backgroundColor.setFill(); bounds.fill()
        let visible = manager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let source = textView.string as NSString
        manager.enumerateLineFragments(forGlyphRange: visible) { [self] line, _, _, glyphs, _ in
            let index = manager.characterIndexForGlyph(at: glyphs.location)
            let number = source.substring(to: index).filter { $0 == "\n" }.count + 1
            let point = convert(NSPoint(x: 0, y: line.minY + textView.textContainerInset.height), from: textView)
            (String(number) as NSString).draw(at: NSPoint(x: 33 - CGFloat(String(number).count - 1) * 8, y: point.y),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor.systemIndigo])
        }
        if source.length == 0 {
            let point = convert(NSPoint(x: 0, y: textView.textContainerInset.height), from: textView)
            ("1" as NSString).draw(at: NSPoint(x: 33, y: point.y), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor.systemIndigo])
        }
    }
}
