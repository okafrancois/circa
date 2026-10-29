import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

extension BrowserWindowController {
    func installSidebarPresentation() {
        windowShell.onSidebarWidthChange = { [weak self] in self?.windowPlacementDidChange() }
        windowShell.onPresentationChange = { [weak self] in self?.updateSidebarColumnVisibility() }
        windowShell.onCollapseRequest = { [weak self] in self?.submitInput { $0.hideSidebar() } }
        sidebar.onFooterPresentationChange = { [weak self] in self?.windowShell.hoverHoldDidChange() }
        windowShell.onFullScreenChange = { [weak self] fullScreen in
            self?.sidebar.cancelFooterPresentations()
            self?.sidebar.navigationContainer.isFullScreen = fullScreen
        }
        windowShell.allowsHoverReveal = { [weak self] in
            guard let self else { return false }
            return acceptsCommands && !library.isPresented && !library.drawer.animation.isAnimating
        }
        windowShell.allowsResize = { [weak self] in
            guard let self else { return false }
            return acceptsCommands && !library.isPresented && !library.drawer.animation.isAnimating
        }
        windowShell.isHoverHeld = { [weak self] in
            guard let self else { return false }
            return sidebar.hasFooterPresentation || isEditingInSidebar || folderPreview.isPresented || siteControls?.isPopoverShown == true
                || themeEditor?.panel?.isVisible == true
        }
        for name in [NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification] {
            windowShell.observe(name, object: addressField) { [weak self] in
                guard let self else { return }
                // AppKit can still return its field editor while dispatching didEndEditing.
                sidebar.addressContainer.isEditing = name == NSControl.textDidBeginEditingNotification
            }
            windowShell.observe(name, object: nil) { [weak self] in self?.windowShell.hoverHoldDidChange() }
        }
    }

    /// ⌘S: pin or hide the sidebar. Hiding from a hover-revealed sidebar is not possible: the
    /// toggle pins it, as the floating panel shows the same toggle.
    func toggleSidebar() {
        guard acceptsCommands else { return }
        session.performWindowAction { [weak self] in
            guard let self, !isPreparingForTermination else { return }
            setSidebarVisible(!isSidebarVisible)
        }
    }

    func hideSidebar() {
        guard acceptsCommands else { return }
        session.performWindowAction { [weak self] in
            guard let self, !isPreparingForTermination, isSidebarVisible else { return }
            setSidebarVisible(false, animated: !OrbitTokens.Motion.sidebarCollapseIsInstant)
        }
    }

    func setSidebarVisible(_ visible: Bool, animated: Bool = true) {
        // Read before the column hides. An instant hide (reduced motion, drag-collapse, a window
        // that cannot animate) makes AppKit drop the field editor or hidden responder first and
        // leave the window itself as first responder: the page then received no keys (DBG-KEYS).
        let focusLeavesSidebar = !visible && isFocusInSidebar
        isSidebarVisible = visible
        windowShell.setDocked(visible, animated: animated)
        updateSidebarColumnVisibility()
        if focusLeavesSidebar { focusContentAfterSidebarHide() }
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// The content the sidebar hands keyboard focus to: Peek, the Library, else the document.
    func focusContentAfterSidebarHide() {
        if let surface = presentedPeekSurface { surface.focusDocument() }
        else if library.isPresented { window?.makeFirstResponder(libraryFocusView) }
        else { focusSelectedDocument() }
    }

    /// Downloads belong to the Library content surface; the sidebar keeps its own visibility.
    func updateSidebarColumnVisibility() {
        let onScreen = windowShell.isSidebarOnScreen
        // The offscreen frame clips the sidebar in a live window. Keep its backing stores warm
        // instead of tearing down the layer subtree at each hide/reveal; AX follows visibility.
        let sidebarHidden = !onScreen && window?.isVisible != true
        let paneHidden = !library.isPresented || library.category != .downloads
        if sidebar.isHidden != sidebarHidden { sidebar.isHidden = sidebarHidden }
        sidebar.isShellHidden = !onScreen
        sidebar.setAccessibilityHidden(!onScreen)
        if downloadsPane.isHidden != paneHidden { downloadsPane.isHidden = paneHidden }
    }

    /// Site controls anchor to the visible sidebar address field.
    var isAddressFieldOnScreen: Bool {
        windowShell.isSidebarOnScreen && !sidebar.isHidden
    }

    /// Editing a sidebar field, or any other sidebar responder (the tab list after a click).
    var isFocusInSidebar: Bool {
        if isEditingInSidebar { return true }
        return (window?.firstResponder as? NSView)?.isDescendant(of: sidebar) == true
    }

    var isEditingInSidebar: Bool {
        guard let editor = window?.firstResponder as? NSText,
              let field = editor.delegate as? NSView else { return false }
        return field.isDescendant(of: sidebar)
    }

    /// Theme of the active Space: window fill, appearance and accent. Space switches cross-fade.
    func renderChrome() {
        let spaceID = session.snapshot?.activeSpaceID
        sidebar.spaceSwipe.validate(catalog: session.catalog, active: spaceID)
        closeThemeEditorIfNeeded(activeSpaceID: spaceID)
        let theme = resolvedSpaceTheme(for: spaceID)
        let switching = displayedSpaceID != nil && displayedSpaceID != spaceID
        // A late swipe publication can finish the preview inside willRender. Install its
        // stored theme first so clearing the interactive blend cannot flash the old Space.
        windowShell.onThemePaint = { [weak self] painted in
            let accent = OrbitSpaceThemes.accent(for: painted)
            self?.sidebar.applyAccent(accent)
            self?.contentCard.themeForeground = accent.foreground
        }
        windowShell.apply(theme: theme, animated: switching)
        sidebar.prepareSpaceContentPublication(to: spaceID)
        _ = sidebar.spaceSwipe.willRender(active: spaceID)
        renderLoadingIndicator()
    }

    func renderLoadingIndicator() {
        let state = session.selectedSurface?.navigationState
        windowShell.setLoadingPhase(.resolve(isLoading: state?.isLoading ?? false, url: state?.url,
                                             committedURL: state?.committedURL))
    }

    // MARK: Test and diagnostics accessors

    var isSidebarFloating: Bool { windowShell.isFloatingRevealed }
    var shellGeometry: OrbitShellGeometry? { windowShell.geometry }
}
