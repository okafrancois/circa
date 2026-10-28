import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// Window composition: Space fill, content card, sidebar column and overlays. Owned by the
/// Themes & motion lot; features add their views through their own `install<Feature>(in:)`
/// helpers. Geometry lives in `OrbitWindowShell` / `OrbitShellGeometry` (design §2–3).
extension BrowserWindowController {
    func configureContent() {
        guard let window else { return }
        let root = OrbitWindowRootView()
        windowShell.prepare(window: window, root: root)

        let toggle = OrbitGlyphButton(glyph: OrbitGlyph.sidebarToggle, label: OrbitShellText.toggleSidebar)
        toggle.target = self
        toggle.action = #selector(toggleSidebarAction(_:))
        configureButton(backButton, glyph: OrbitGlyph.back, action: #selector(goBack(_:)), label: OrbitShellText.back)
        configureButton(forwardButton, glyph: OrbitGlyph.forward, action: #selector(goForward(_:)), label: OrbitShellText.forward)
        configureButton(reloadButton, glyph: OrbitGlyph.reload, action: #selector(reloadPage(_:)), label: OrbitShellText.reload)
        sidebar.navigationContainer.install([toggle, backButton, forwardButton, reloadButton])
        // Compact toolbar (W < 224, ): the hidden toggle and reload move into
        // the "•••" menu (: Orbit's menu content was not captured).
        let overflow = OrbitGlyphButton(glyph: OrbitGlyph.toolbarOverflow, label: OrbitShellText.moreToolbarItems)
        sidebar.navigationContainer.installOverflow(overflow) { [weak self] in self?.toolbarOverflowMenu() }
        sidebar.navigationContainer.trafficLightPitch = windowShell.trafficLightPitch
        configureAddressField()
        siteControls.install()
        extensionControls.install()
        installSidebarActions()
        favorites.install()
        sidebar.onShowLibrary = { [weak self] in self?.submitInput { $0.showLibrary() } }

        for view in [contentCard, sidebar] { view.translatesAutoresizingMaskIntoConstraints = false }
        root.addSubview(contentCard)
        windowShell.installLoadingIndicator(in: root)
        installFindBar(in: root)
        installSplit()
        installLibrary(in: root)
        installDownloadsPane(in: library.view.body)
        installArchive(in: library.view.body)
        windowShell.installFloatingBackdrop(in: root)
        root.addSubview(sidebar)
        installPeek(in: root)
        installPalette(in: root)
        windowShell.installResizeHandle(in: root)
        window.contentView = root

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: windowShell.preferredSidebarWidth)
        sidebarLeading = sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        windowShell.installConstraints(root: root, sidebar: sidebar, card: contentCard,
                                       width: sidebarWidth, leading: sidebarLeading)
        installSidebarPresentation()
    }

    private func configureAddressField() {
        addressField.placeholderString = OrbitShellText.addressPlaceholder
        addressField.placeholderAttributedString = NSAttributedString(string: OrbitShellText.addressPlaceholder, attributes: [
            .font: OrbitTokens.Typography.addressField, .foregroundColor: OrbitTokens.Color.Text.placeholder
        ])
        addressField.target = self
        addressField.delegate = self
        addressField.action = #selector(navigateToEnteredAddress(_:))
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addressField.setAccessibilityIdentifier("browser-address")
        addressField.font = OrbitTokens.Typography.addressField
        addressField.textColor = OrbitTokens.Color.Text.baseSecondary
        addressField.isBordered = false
        addressField.isBezeled = false
        addressField.drawsBackground = false
        addressField.focusRingType = .none
        OrbitAddressFieldStyle.applySingleLine(to: addressField)
        zoomButton.isBordered = false
        zoomButton.font = OrbitTokens.Typography.addressAccessory
        zoomButton.contentTintColor = OrbitTokens.Color.Text.secondary
        zoomButton.target = self
        zoomButton.action = #selector(resetPageZoom(_:))
        zoomButton.toolTip = OrbitShellText.resetZoom
        zoomButton.setAccessibilityIdentifier("page-zoom-reset")
        zoomButton.isHidden = true
        sidebar.addressContainer.installField(addressField)
        sidebar.addressContainer.installAccessory(zoomButton)
        let copy = PillCopyLinkButton()
        copy.target = self
        copy.action = #selector(copyAddressFromPill(_:))
        copy.toolTip = uiText("Copy URL")
        copy.setAccessibilityIdentifier("address-copy-url")
        copy.widthAnchor.constraint(equalToConstant: SidebarExtensionStrip.hitSize).isActive = true
        copy.heightAnchor.constraint(equalToConstant: SidebarExtensionStrip.hitSize).isActive = true
        sidebar.addressContainer.installAccessory(copy, onHover: true, order: 50)
    }

    /// Items hidden by the compact toolbar.
    private func toolbarOverflowMenu() -> NSMenu? {
        guard acceptsCommands else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: OrbitShellText.toggleSidebar, action: #selector(toggleSidebarAction(_:)), keyEquivalent: "").target = self
        let reload = menu.addItem(withTitle: OrbitShellText.reload, action: #selector(reloadPage(_:)), keyEquivalent: "")
        reload.target = self
        reload.isEnabled = reloadButton.isEnabled
        return menu
    }

    private func configureButton(_ button: OrbitGlyphButton, glyph: NSImage?, action: Selector, label: String) {
        button.glyph = glyph
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
    }
}
