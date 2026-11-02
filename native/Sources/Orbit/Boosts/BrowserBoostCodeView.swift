import AppKit
import BrowserShell

@MainActor
final class BrowserBoostCodeView: NSView, NSTextViewDelegate, NSTextFieldDelegate {
    let session: BrowserBoostEditorSession
    let generation: BrowserBoostGeneration?
    let prompt = NSTextField()
    private let send = BoostButton(symbol: "arrow.up", label: uiText("Generate CSS"))
    private let apply = BoostButton(title: "")
    private let editCode = BoostButton(title: uiText("Edit Code"))
    private let status = NSTextField(labelWithString: "")
    var onBack: (() -> Void)?
    var requestJavaScriptConsent: ((@escaping (Bool) -> Void) -> Void)?
    private let canvas = LibraryFlippedView()
    private let css = BoostButton(title: uiText("CSS"))
    private let js = BoostButton(title: uiText("JS"))
    let textView = NSTextView()
    private let scroll = NSScrollView()
    private var showingGeneratedDraft = false
    private(set) var isCSS = true
    private(set) var selectionTask: Task<Void, Never>?

    init(session: BrowserBoostEditorSession, generation: BrowserBoostGeneration? = nil, appearance: NSAppearance? = nil) {
        self.session = session
        self.generation = generation
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 588))
        self.appearance = appearance
        wantsLayer = true; layer?.cornerRadius = 12; layer?.masksToBounds = true
        layer?.borderWidth = 0.5; layer?.borderColor = color(light: 0xe3e3e3, dark: 0x414047).cgColor
        layer?.backgroundColor = color(light: 0xffffff, dark: 0x222128).cgColor
        canvas.frame = bounds; addSubview(canvas)
        let header = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 44))
        header.wantsLayer = true; header.layer?.backgroundColor = color(light: 0xffffff, dark: 0x222128).cgColor
        canvas.addSubview(header)
        let separator = NSView(frame: NSRect(x: 0, y: 43.5, width: 480, height: 0.5))
        separator.wantsLayer = true; separator.layer?.backgroundColor = color(light: 0xebe9ea, dark: 0x34333a).cgColor
        canvas.addSubview(separator)
        let back = BoostButton(title: uiText("←  Back")); back.fill = .clear
        back.contentTintColor = color(light: 0x5e5a66, dark: 0xb4afba)
        back.actionBlock = { [weak self] in self?.onBack?() }
        back.frame = NSRect(x: 12, y: 6, width: 60, height: 28); canvas.addSubview(back)
        let ask = NSView(frame: NSRect(x: 10, y: 54, width: 460, height: 38))
        ask.wantsLayer = true; ask.layer?.cornerRadius = 10
        ask.layer?.backgroundColor = color(light: 0xf6f3ee, dark: 0x18181d).cgColor
        ask.layer?.borderWidth = 1; ask.layer?.borderColor = color(light: 0xe2dfdb, dark: 0x2a2a2f).cgColor
        canvas.addSubview(ask)
        let sparkle = NSImageView(frame: NSRect(x: 20, y: 65, width: 16, height: 16))
        sparkle.image = OrbitIcon.image(sfName: "sparkles", pointSize: 16); canvas.addSubview(sparkle)
        let heading = NSTextField(labelWithString: uiFormat("Boost · %@", session.boost.hostPattern.host))
        heading.frame = NSRect(x: 90, y: 12, width: 360, height: 20)
        heading.font = BrandTextStyle.ui.font(size: 13, weight: .semibold)
        heading.textColor = color(light: 0x141317, dark: 0xf4f1ec); canvas.addSubview(heading)
        prompt.placeholderString = uiText("Describe a change…")
        let promptFont = BrandTextStyle.ui.font(size: 12.5)
        prompt.font = promptFont
        prompt.placeholderAttributedString = NSAttributedString(string: uiText("Describe a change…"), attributes: [.font: promptFont, .foregroundColor: color(light: 0x96929e, dark: 0x7d7884)])
        prompt.delegate = self; prompt.isContinuous = false; prompt.cell?.sendsActionOnEndEditing = false
        prompt.isBordered = false; prompt.focusRingType = .none
        prompt.drawsBackground = false
        prompt.textColor = color(light: 0x141317, dark: 0xf4f1ec)
        prompt.frame = NSRect(x: 44, y: 62, width: 382, height: 22)
        prompt.target = self; prompt.action = #selector(submitPrompt)
        canvas.addSubview(prompt)
        send.frame = NSRect(x: 440, y: 62, width: 22, height: 22)
        send.fill = color(light: 0x0a7aff, dark: 0x0a7aff); send.contentTintColor = .white; send.cornerRadius = 11
        send.actionBlock = { [weak self] in self?.submitPrompt() }
        send.setAccessibilityLabel(uiText("Generate CSS")); canvas.addSubview(send)
        apply.title = uiFormat("Apply to %@", session.boost.hostPattern.host)
        apply.frame = NSRect(x: 290, y: 552, width: 180, height: 26)
        let footerFont = BrandTextStyle.ui.font(size: 12.5, weight: .medium)
        apply.font = footerFont
        let applyWidth = min(250, ceil((apply.title as NSString).size(withAttributes: [.font: footerFont]).width) + 24)
        apply.frame = NSRect(x: 470 - applyWidth, y: 552, width: applyWidth, height: 26)
        apply.cornerRadius = 7
        apply.fill = color(light: 0x0a7aff, dark: 0x0a7aff); apply.contentTintColor = .white
        apply.actionBlock = { [weak self] in self?.generation?.apply() }
        canvas.addSubview(apply)
        let editWidth = ceil((editCode.title as NSString).size(withAttributes: [.font: footerFont]).width) + 24
        editCode.frame = NSRect(x: apply.frame.minX - 8 - editWidth, y: 552, width: editWidth, height: 26)
        editCode.font = BrandTextStyle.ui.font(size: 12.5, weight: .medium); editCode.cornerRadius = 7
        editCode.fill = color(light: 0xefebe4, dark: 0x2c2b32)
        editCode.contentTintColor = color(light: 0x141317, dark: 0xf4f1ec)
        editCode.actionBlock = { [weak self] in guard let self else { return }; window?.makeFirstResponder(textView) }
        canvas.addSubview(editCode)
        status.maximumNumberOfLines = 2; status.usesSingleLineMode = false; status.lineBreakMode = .byWordWrapping
        status.font = .systemFont(ofSize: 11.5); status.frame = NSRect(x: 10, y: 552, width: max(0, editCode.frame.minX - 20), height: 26)
        canvas.addSubview(status)
        let tabs = NSView(frame: NSRect(x: 10, y: 102, width: 100, height: 24))
        tabs.wantsLayer = true; tabs.layer?.cornerRadius = 6; tabs.layer?.masksToBounds = true
        tabs.layer?.backgroundColor = NSColor.clear.cgColor
        css.font = BrandTextStyle.ui.font(size: 12); js.font = BrandTextStyle.ui.font(size: 12)
        css.frame = NSRect(x: 0, y: 0, width: 50, height: 24)
        js.frame = NSRect(x: 50, y: 0, width: 50, height: 24)
        css.actionBlock = { [weak self] in self?.selectCSS(true) }
        js.actionBlock = { [weak self] in self?.selectCSS(false) }
        tabs.addSubview(css); tabs.addSubview(js); canvas.addSubview(tabs)
        scroll.frame = NSRect(x: 10, y: 134, width: 460, height: 398)
        scroll.wantsLayer = true; scroll.layer?.masksToBounds = true
        scroll.layer?.cornerRadius = 8; scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = color(light: 0xe2dfdb, dark: 0x2a2a2f).cgColor
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        textView.isRichText = false; textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textColor = color(light: 0x5e5a66, dark: 0xb4afba)
        textView.backgroundColor = color(light: 0xf6f3ee, dark: 0x18181d)
        textView.textContainerInset = NSSize(width: generation == nil ? 20 : 10, height: generation == nil ? 12 : 10)
        let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = 18.4; paragraph.maximumLineHeight = 18.4
        textView.defaultParagraphStyle = paragraph
        textView.minSize = NSSize(width: 0, height: 480)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 412, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: generation == nil ? 412 : 460, height: 480)
        textView.delegate = self
        scroll.documentView = textView
        scroll.verticalRulerView = BrowserBoostLineNumbers(textView: textView, scrollView: scroll)
        scroll.hasVerticalRuler = generation == nil; scroll.rulersVisible = generation == nil
        canvas.addSubview(scroll)
        display(css: true)
        generation?.onChange = { [weak self] in self?.renderGeneration() }
        renderGeneration()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === prompt else { return }
        generation?.cancel()
    }
    @objc private func submitPrompt() {
        guard let generation else { return }
        if generation.running { generation.stop() } else { generation.run(prompt.stringValue) }
    }
    private func renderGeneration() {
        guard let generation else { apply.isEnabled = false; return }
        send.image = OrbitIcon.image(sfName: generation.running ? "stop.fill" : "arrow.up", pointSize: 14, accessibilityDescription: generation.running ? uiText("Stop") : uiText("Generate CSS"))
        send.setAccessibilityLabel(generation.running ? uiText("Stop") : uiText("Generate CSS"))
        apply.isEnabled = generation.ready && !generation.applying
        editCode.isEnabled = !generation.running && !generation.applying
        status.stringValue = generation.error
        if generation.running || generation.isDraftVisible {
            showingGeneratedDraft = true
            if !isCSS { display(css: true) }
            if textView.string != generation.output { textView.string = generation.output }
            textView.isEditable = !generation.running && !generation.applying
        } else {
            textView.isEditable = true
            if showingGeneratedDraft {
                showingGeneratedDraft = false
                textView.string = isCSS ? session.boost.content.customCSS : session.boost.content.customJavaScript
            }
        }
        scroll.verticalRulerView?.needsDisplay = true
    }

    func selectCSS(_ selected: Bool) {
        generation?.cancel()
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
        css.fill = selected ? color(light: 0xefebe4, dark: 0x2c2b32) : .clear; css.contentTintColor = selected ? color(light: 0x141317, dark: 0xf4f1ec) : color(light: 0x96929e, dark: 0x7d7884)
        js.fill = selected ? .clear : color(light: 0xefebe4, dark: 0x2c2b32); js.contentTintColor = selected ? color(light: 0x96929e, dark: 0x7d7884) : color(light: 0x141317, dark: 0xf4f1ec)
        textView.string = selected ? session.boost.content.customCSS : session.boost.content.customJavaScript
        textView.setAccessibilityLabel(selected ? uiText("CSS") : uiText("JS"))
        scroll.verticalRulerView?.needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        if generation?.isDraftVisible == true { generation?.editDraft(textView.string); return }
        let source = textView.string, css = isCSS
        session.edit { if css { $0.customCSS = source } else { $0.customJavaScript = source } }
        scroll.verticalRulerView?.needsDisplay = true
    }
    private func color(light: UInt32, dark: UInt32) -> NSColor {
        let value = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
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
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.systemIndigo])
        }
        if source.length == 0 {
            let point = convert(NSPoint(x: 0, y: textView.textContainerInset.height), from: textView)
            ("1" as NSString).draw(at: NSPoint(x: 33, y: point.y), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.systemIndigo])
        }
    }
}
