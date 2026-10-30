import AppKit
import BrowserShell
import BrowserCore
import BrowserEngine
import QuartzCore

/// Local sharing only. macOS owns service selection and delivery; no Orbit cloud URL is created.
@MainActor
final class BrowserSharingController<Engine: BrowserEngine>: NSObject, NSSharingServicePickerDelegate {
    private weak var owner: BrowserWindowController<Engine>?
    let button = SiteControlButton("", identifier: "share-page", onPress: {})
    private var picker: NSSharingServicePicker?
    private let toast = BrowserCopiedToast()

    init(owner: BrowserWindowController<Engine>) {
        self.owner = owner
        super.init()
        button.image = OrbitIcon.image(sfName: "square.and.arrow.up", pointSize: 16, accessibilityDescription: uiText("Share…"))
        button.toolTip = uiText("Share…")
        button.onPress = { [weak self] in self?.showMenu() }
    }

    func install() {
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        owner?.sidebar.addressContainer.installAccessory(button, onHover: true)
    }

    func copyMarkdownLink() {
        guard let owner, let surface = owner.pageCommandSurface() else { return }
        let generation = surface.documentGeneration
        owner.session.performWindowAction { [weak owner, weak surface] in
            guard let owner, let surface, owner.pageCommandSurface() === surface,
                  !surface.isDisposed, surface.documentGeneration == generation,
                  let url = surface.navigationState.url else { return }
            owner.sharing.copyText(BrowserMarkdownLink.format(title: surface.navigationState.title, url: BrowserCopyURLCleaner.clean(url)))
        }
    }

    func copyLink() {
        guard let owner else { return }
        if owner.isPeekPageFocused, let url = owner.presentedPeekSurface?.navigationState.url {
            copy(url, in: owner.contentCard)
        } else if owner.sidebar.selection.nodes.count >= 2 {
            owner.copySidebarLinks(markdown: false)
        } else {
            owner.session.performOnSelectedSurface { [weak self] surface in
                guard let self, let url = surface.navigationState.url else { return }
                copy(url, in: owner.contentCard)
            }
        }
    }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { return }
        if let view = owner?.contentCard { toast.show(in: view) }
    }

    func copy(_ url: URL, in view: NSView?) {
        guard BrowserLinkPasteboard.write(BrowserCopyURLCleaner.clean(url)) else { return }
        if let view { toast.show(in: view) }
    }

    func sharePage() {
        owner?.session.performOnSelectedSurface { [weak self] surface in
            guard let self, let url = surface.navigationState.url else { return }
            share(url, title: surface.navigationState.title)
        }
    }

    func share(_ url: URL, title: String?) {
        guard let owner, owner.acceptsCommands, let window = owner.window, window.isVisible else { return }
        let picker = NSSharingServicePicker(items: [url])
        self.picker = picker
        picker.delegate = self
        if button.window != nil, !button.isHiddenOrHasHiddenAncestor {
            picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else {
            let view = owner.contentCard
            let rect = NSRect(x: view.bounds.maxX - 48, y: view.isFlipped ? 12 : view.bounds.maxY - 36, width: 24, height: 24)
            picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        }
    }

    private func showMenu() {
        guard let owner, owner.acceptsCommands, owner.session.selectedSurface?.navigationState.url != nil else { return }
        let menu = NSMenu()
        let copy = NSMenuItem(title: uiText("Copy Link"), action: #selector(copySelectedLink), keyEquivalent: "C")
        copy.keyEquivalentModifierMask = [.command]
        copy.image = OrbitIcon.image(sfName: "link", pointSize: 16, accessibilityDescription: nil)
        copy.target = self
        menu.addItem(copy)
        menu.addItem(.separator())
        let share = NSMenuItem(title: uiText("Share…"), action: #selector(shareSelectedPage), keyEquivalent: "")
        share.image = OrbitIcon.image(sfName: "square.and.arrow.up", pointSize: 16, accessibilityDescription: nil)
        share.target = self
        menu.addItem(share)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    @objc private func copySelectedLink() { copyLink() }
    @objc private func shareSelectedPage() { sharePage() }
}

/// One transient, nonactivating confirmation per window, including repeated copies.
@MainActor
final class BrowserCopiedToast: NSView {
    private var dismissal: Task<Void, Never>?
    private var serial: UInt64 = 0

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 104, height: 36))
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.13, blue: 0.17, alpha: 0.96).cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        let icon = NSImageView(image: OrbitIcon.image(sfName: "checkmark", pointSize: 16, accessibilityDescription: nil)!)
        icon.contentTintColor = .white
        let label = NSTextField(labelWithString: uiText("Copied"))
        label.font = BrandTextStyle.ui.font(size: 13, weight: .medium)
        label.textColor = .white
        let row = NSStackView(views: [icon, label])
        row.spacing = 7
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.centerXAnchor.constraint(equalTo: centerXAnchor), row.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     icon.widthAnchor.constraint(equalToConstant: 13)])
        setAccessibilityIdentifier("copied-toast")
        setAccessibilityLabel(uiText("Copied"))
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(in view: NSView) {
        serial &+= 1
        let current = serial
        dismissal?.cancel()
        removeFromSuperview()
        frame.origin = NSPoint(x: view.bounds.maxX - frame.width - 16,
                               y: view.isFlipped ? 16 : view.bounds.maxY - frame.height - 16)
        autoresizingMask = view.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
        alphaValue = 1
        view.addSubview(self, positioned: .above, relativeTo: nil)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.18
            layer?.add(fade, forKey: "copy-fade")
            let entrance = CASpringAnimation(keyPath: "transform.translation.y")
            entrance.fromValue = view.isFlipped ? -7 : 7
            entrance.toValue = 0
            entrance.damping = 18
            entrance.stiffness = 240
            entrance.duration = 0.32
            layer?.add(entrance, forKey: "copy-slide")
        }
        NSAccessibility.post(element: view, notification: .announcementRequested,
                             userInfo: [.announcement: uiText("Copied"), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, serial == current else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
                animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.serial == current else { return }
                    self.removeFromSuperview()
                }
            }
        }
    }
}

@MainActor
enum BrowserLinkPasteboard {
    /// Both representations are needed: plain text editors do not accept public.url alone.
    @discardableResult
    static func write(_ url: URL, to board: NSPasteboard = .general) -> Bool {
        board.clearContents()
        let written = board.setString(url.absoluteString, forType: .string)
        _ = board.setString(url.absoluteString, forType: .URL)
        return written
    }
}
