import AppKit

/// What a tab-modal page dialog shows (CH-ESSENTIALS). Kind identifies the request for tests and
/// the smoke; text is already localized.
struct BrowserPageDialogSpec: Equatable {
    enum Kind: String, Equatable {
        case alert, confirm, prompt, beforeUnload, authentication, externalProtocol, folderUpload, unresponsive
    }

    struct Field: Equatable {
        var label: String
        var initialValue: String = ""
        var isSecure = false
    }

    var kind: Kind
    var title: String
    var message: String?
    /// A secondary line, for example the insecure-connection warning of an HTTP sign-in.
    var note: String?
    var fields: [Field] = []
    var checkbox: String?
    var primary: String
    var secondary: String?
    /// Escape chooses the primary button (Wait in the unresponsive dialog) instead of the secondary.
    var escapeChoosesPrimary = false
}

struct BrowserPageDialogResult: Equatable {
    var accepted: Bool
    var fieldValues: [String] = []
    var checkboxChecked = false
}

/// A dialog over one document only, the way Chromium shows tab-modal dialogs: a card at the top
/// center of the page over a light scrim that takes the page's mouse events. It is a subview of the
/// surface's host view, so it follows its tab (hidden with it, shown again with it), its Split pane,
/// its Peek and its Little Orbit window, and never covers another document.
@MainActor
final class BrowserPageDialogView: NSView {
    let spec: BrowserPageDialogSpec
    private let card = NSView()
    private var inputs: [NSTextField] = []
    private var checkbox: NSButton?
    private let completion: (BrowserPageDialogResult) -> Void
    private var isFinished = false

    init(spec: BrowserPageDialogSpec, completion: @escaping (BrowserPageDialogResult) -> Void) {
        self.spec = spec
        self.completion = completion
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        build()
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    // The page under the scrim receives no pointer events while the dialog is up.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimFocus()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        claimFocus()
    }

    /// The first field, or the default button, takes the focus while the dialog's page is shown in
    /// the key window.
    func claimFocus() {
        guard let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else { return }
        if let field = inputs.first { window.makeFirstResponder(field) }
        else { window.makeFirstResponder(nil) }
    }

    private func build() {
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.borderWidth = 0.5
        card.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            return shadow
        }()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilitySubrole(.dialog)
        card.setAccessibilityLabel(spec.title)
        addSubview(card)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let title = NSTextField(wrappingLabelWithString: spec.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.isSelectable = false
        stack.addArrangedSubview(title)
        if let message = spec.message, !message.isEmpty {
            let label = NSTextField(wrappingLabelWithString: Self.displayed(message))
            label.font = .systemFont(ofSize: 13)
            label.isSelectable = true
            label.maximumNumberOfLines = 24
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if let note = spec.note {
            let label = NSTextField(wrappingLabelWithString: note)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
        }
        for field in spec.fields {
            let input: NSTextField = field.isSecure ? NSSecureTextField() : NSTextField()
            input.placeholderString = field.label
            input.stringValue = field.initialValue
            input.setAccessibilityLabel(field.label)
            input.target = self
            input.action = #selector(acceptAction(_:))
            inputs.append(input)
            stack.addArrangedSubview(input)
            input.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if let text = spec.checkbox {
            let box = NSButton(checkboxWithTitle: text, target: nil, action: nil)
            checkbox = box
            stack.addArrangedSubview(box)
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.addArrangedSubview(spacer)
        if let secondary = spec.secondary {
            let button = NSButton(title: secondary, target: self, action: #selector(cancelAction(_:)))
            button.bezelStyle = .rounded
            if !spec.escapeChoosesPrimary { button.keyEquivalent = "\u{1b}" }
            buttons.addArrangedSubview(button)
        }
        let primary = NSButton(title: spec.primary, target: self, action: #selector(acceptAction(_:)))
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        buttons.addArrangedSubview(primary)
        if spec.secondary == nil || spec.escapeChoosesPrimary {
            // Escape also dismisses an alert (OK) and keeps waiting in the unresponsive dialog.
            let escape = NSButton(title: "", target: self, action: #selector(escapeAction(_:)))
            escape.keyEquivalent = "\u{1b}"
            escape.isBordered = false
            escape.setAccessibilityElement(false)
            escape.frame = .zero
            buttons.addArrangedSubview(escape)
            escape.widthAnchor.constraint(equalToConstant: 0).isActive = true
        }
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            card.widthAnchor.constraint(equalToConstant: 420).withPriority(.defaultHigh),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            card.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
    }

    /// Very long page messages are cut, as Chromium elides them; never a trap for the window.
    static func displayed(_ message: String) -> String {
        let limit = 3000
        guard message.count > limit else { return message }
        return String(message.prefix(limit)) + "…"
    }

    @objc private func acceptAction(_ sender: Any?) { finish(accepted: true) }
    @objc private func cancelAction(_ sender: Any?) { finish(accepted: false) }
    @objc private func escapeAction(_ sender: Any?) { finish(accepted: spec.escapeChoosesPrimary || spec.secondary == nil) }

    /// Answers once (button, keyboard, test or smoke), then leaves the page.
    func finish(accepted: Bool, fieldValues: [String]? = nil, checkboxChecked: Bool? = nil) {
        guard !isFinished else { return }
        isFinished = true
        let values = fieldValues ?? inputs.map(\.stringValue)
        let checked = checkboxChecked ?? (checkbox?.state == .on)
        removeFromSuperview()
        completion(BrowserPageDialogResult(accepted: accepted, fieldValues: values, checkboxChecked: checked))
    }
}

/// Shown in place of a document whose renderer ended (Chromium's sad tab is Views and crashes in
/// hosted mode): Chromium's wording, with Reload. Removed by the next committed document.
@MainActor
final class BrowserPageCrashedView: NSView {
    private let reload: () -> Void

    init(termination: String, reload: @escaping () -> Void) {
        self.reload = reload
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: uiText("Aw, Snap!"))
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let message = NSTextField(wrappingLabelWithString: uiText("Something went wrong while displaying this webpage."))
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        let button = NSButton(title: uiText("Reload"), target: nil, action: nil)
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.target = self
        button.action = #selector(reloadAction(_:))
        let stack = NSStackView(views: [icon, title, message, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(uiText("Aw, Snap!"))
        identifier = NSUserInterfaceItemIdentifier("orbit.page-crashed.\(termination)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
    override func mouseDown(with event: NSEvent) {}

    @objc private func reloadAction(_ sender: Any?) { reload() }
    func performReload() { reload() }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
