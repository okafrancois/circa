import AppKit
import BrowserCore
import BrowserEngine

extension BrowserWindowController {
    func installLibrary(in root: NSView) {
        let view = library.view
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        root.addSubview(view)
        let leading = view.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        let width = view.widthAnchor.constraint(equalToConstant: 417)
        width.priority = NSLayoutConstraint.Priority(999)
        library.widthConstraint = width
        library.spacesWidthConstraint = view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56)
        library.spacesWidthConstraint?.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            leading, width,
            view.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -56),
            view.topAnchor.constraint(equalTo: root.topAnchor),
            view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        library.drawer.install(view: view, root: root, leading: leading)
        library.drawer.shouldFinishClosing = { [weak self] in
            guard let self else { return true }
            return library.displayedProfileID != session.activeProfileID || session.isClosed
        }
        library.drawer.onVisibleWidthChange = { [weak self] width in self?.windowShell.setLibraryVisibleWidth(width) }
        library.drawer.onProgressChange = { [weak self] progress in
            guard let self else { return }
            windowShell.setLibraryProgress(progress)
            if let root = window?.contentView, progress > 0 {
                let below = progress < 1
                if library.view.isBelowSidebarDuringTransition != below {
                    root.addSubview(library.view, positioned: below ? .below : .above, relativeTo: sidebar)
                    library.view.isBelowSidebarDuringTransition = below
                }
            }
        }
        library.drawer.onOutsideClick = { [weak self] in
            guard let self, !peek.isPresented else { return }
            hideLibrary(focus: false)
        }
        library.drawer.onClosed = { [weak self] in self?.finishHidingLibrary() }
        installLibrarySwipe()
        view.onCategory = { [weak self] category in
            guard let self, library.isPresented, library.view.acceptsLibraryInput else { return }
            submitInput { $0.showLibrary(category) }
        }
        view.onBack = { [weak self] in self?.submitInput { $0.hideLibrary() } }
        view.body.wantsLayer = true
        let historyView = library.historyView
        historyView.translatesAutoresizingMaskIntoConstraints = false
        historyView.isHidden = true
        view.body.addSubview(historyView)
        NSLayoutConstraint.activate([
            historyView.leadingAnchor.constraint(equalTo: view.body.leadingAnchor), historyView.trailingAnchor.constraint(equalTo: view.body.trailingAnchor),
            historyView.topAnchor.constraint(equalTo: view.body.topAnchor), historyView.bottomAnchor.constraint(equalTo: view.body.bottomAnchor)
        ])
        let spacesView = library.spacesView
        spacesView.translatesAutoresizingMaskIntoConstraints = false
        spacesView.isHidden = true
        view.body.addSubview(spacesView)
        NSLayoutConstraint.activate([
            spacesView.leadingAnchor.constraint(equalTo: view.body.leadingAnchor), spacesView.trailingAnchor.constraint(equalTo: view.body.trailingAnchor),
            spacesView.topAnchor.constraint(equalTo: view.body.topAnchor), spacesView.bottomAnchor.constraint(equalTo: view.body.bottomAnchor)
        ])
        let boostsView = library.boostsView
        boostsView.translatesAutoresizingMaskIntoConstraints = false
        boostsView.isHidden = true
        view.body.addSubview(boostsView)
        NSLayoutConstraint.activate([
            boostsView.leadingAnchor.constraint(equalTo: view.body.leadingAnchor), boostsView.trailingAnchor.constraint(equalTo: view.body.trailingAnchor),
            boostsView.topAnchor.constraint(equalTo: view.body.topAnchor), boostsView.bottomAnchor.constraint(equalTo: view.body.bottomAnchor)
        ])
        boostsView.onBack = view.onBack
        boostsView.onOpen = { [weak self] boost, profile in self?.openLibraryBoost(boost, profile: profile) }
        let mediaView = library.mediaView
        mediaView.translatesAutoresizingMaskIntoConstraints = false
        mediaView.isHidden = true
        view.body.addSubview(mediaView)
        NSLayoutConstraint.activate([
            mediaView.leadingAnchor.constraint(equalTo: view.body.leadingAnchor), mediaView.trailingAnchor.constraint(equalTo: view.body.trailingAnchor),
            mediaView.topAnchor.constraint(equalTo: view.body.topAnchor), mediaView.bottomAnchor.constraint(equalTo: view.body.bottomAnchor)
        ])
        mediaView.onBack = view.onBack
        mediaView.onAction = { [weak self] context, action in
            guard let self, acceptsCommands, library.isPresented, library.category == .media,
                  library.view.acceptsLibraryInput, session.activeProfileID == context.key.profileID,
                  library.mediaView.rows.contains(where: { $0.snapshot.context == context }) else { return }
            downloads.perform(action, in: context)
        }
        spacesView.onBack = view.onBack
        spacesView.onOpen = { [weak self] target, catalog, ticket in
            guard let self, acceptsCommands, library.isPresented, library.category == .spaces,
                  library.presentationID == ticket, library.view.acceptsLibraryInput,
                  let source = session.paletteContext else { return }
            let (selectionID, admission) = library.beginSelection()
            submitInput { controller in
                guard controller.session.paletteContext == source else {
                    admission.revoke(); controller.library.finishSelection(selectionID); return
                }
                controller.session.activateCatalogSpace(target, catalog: catalog, admission: admission, isCurrent: { [weak controller] in
                    guard let controller else { return false }
                    return controller.acceptsCommands && controller.library.isPresented
                        && controller.library.category == .spaces && controller.library.presentationID == ticket
                }, completion: { [weak controller] accepted in
                    controller?.library.finishSelection(selectionID)
                    guard let controller, controller.library.presentationID == ticket,
                          controller.library.category == .spaces else { return }
                    guard accepted else { controller.session.refreshCatalog(); return }
                    controller.hideLibrary()
                })
            }
        }
        library.history.onChange = { [weak self] in
            guard let self else { return }
            let name = session?.catalog?.profiles.first { $0.id == library.history.profileID }?.name ?? ""
            library.historyView.render(library.history, profileName: name)
        }
        historyView.onSearch = { [weak self] query in self?.library.history.search(query) }
        historyView.onMore = { [weak self] in self?.library.history.loadMore() }
        historyView.onReload = { [weak self] in self?.library.history.reload() }
        historyView.onBack = view.onBack
        historyView.onOpen = { [weak self] visit in
            guard let self, let profile = library.history.profileID,
                  library.history.visits.contains(where: { $0.id == visit.id }) else { return }
            submitInput { controller in
                // Queued input must still target the exact profile displayed by the row.
                guard controller.session.activeProfileID == profile else { return }
                controller.session.openTab(url: visit.url)
                controller.hideLibrary()
            }
        }
        historyView.onDelete = { [weak self] visit in self?.deleteLibraryHistory(.visit(visit.id)) }
        historyView.onDeleteSite = { [weak self] visit in
            guard let host = visit.url.host else { return }
            self?.confirmLibraryHistoryDeletion(.site(host))
        }
        historyView.onDeleteRange = { [weak self] index in
            guard let self else { return }
            switch index {
            case 1: confirmLibraryHistoryDeletion(.lastHour(now: Date()))
            case 2: confirmLibraryHistoryDeletion(.lastDay(now: Date()))
            case 3: confirmLibraryHistoryDeletion(nil)
            case 4: confirmLibraryHistoryDeletion(.all)
            default: break
            }
        }
    }

    func showLibrary(_ category: BrowserLibraryCategory? = nil) {
        guard acceptsCommands else { return }
        recordExplicitInput()
        sidebar.spaceSwipe.cancel()
        let paletteSequence = palette.presentationSequence
        session.performWindowAction { [weak self] in
            guard let self, session.activeProfileID != nil,
                  palette.presentationSequence == paletteSequence else { return }
            presentLibrary(category)
        }
    }

    /// Presentation-only work can run at first horizontal intent without awaiting the store.
    /// The Library retains the active Space and profile; no selection is published by this swipe.
    private func presentLibrary(_ category: BrowserLibraryCategory? = nil, interactiveWidth: CGFloat? = nil) {
        guard acceptsCommands, session.activeProfileID != nil else { return }
        if interactiveWidth == nil { sidebar.spaceSwipe.cancel() }
        palette.dismiss(returnFocus: false)
        if library.isPresented, let category, category != library.category, window?.isVisible == true {
            OrbitTransitions.crossfade(library.view.body.layer, duration: OrbitMotionPreferences.prefersReducedMotion
                ? OrbitTokens.Motion.reducedMotionCrossfade : OrbitTokens.Motion.libraryCategoryFade)
        }
        library.category = category ?? library.category
        library.presentationID = UUID()
        library.isPresented = true
        library.displayedProfileID = session.activeProfileID
        if let root = window?.contentView {
            root.addSubview(library.view, positioned: .above, relativeTo: sidebar)
            root.addSubview(peek.overlay, positioned: .above, relativeTo: library.view)
        }
        renderLibrary()
        library.drawer.sidebarWidth = sidebar.bounds.width
        library.drawer.setPresented(true)
        if let interactiveWidth { library.drawer.track(visibleWidth: interactiveWidth) }
        window?.makeFirstResponder(libraryFocusView)
    }

    private func installLibrarySwipe() {
        let swipe = library.swipe
        swipe.captureAuthority = { [weak self] in
            guard let self else { return { false } }
            let context = session.paletteContext
            let catalog = session.catalog
            return { [weak self] in self?.session.paletteContext == context && self?.session.catalog == catalog }
        }
        swipe.canInteract = { [weak self] in
            guard let self else { return false }
            return acceptsCommands && !session.isClosed && !palette.isPresented && !peek.isPresented
                && !siteControls.isPopoverShown && themeEditor == nil && tabSwitcher.view.superview == nil
        }
        swipe.canOpen = { [weak self] in
            guard let self else { return false }
            return !library.isPresented && library.swipe.canInteract() && sidebar.swipeCanInteract
                && session.snapshot?.activeSpaceID == session.catalog?.spaces.first?.id
        }
        swipe.beginOpening = { [weak self] in
            guard let self else { return }
            recordExplicitInput()
            presentLibrary(interactiveWidth: CGFloat(library.drawer.animation.value) * library.drawer.width)
        }
        swipe.finish = { [weak self] presented, velocity in
            guard let self else { return }
            if presented {
                guard library.isPresented else { return }
                library.drawer.setPresented(true, velocity: velocity)
                window?.makeFirstResponder(libraryFocusView)
            } else { hideLibrary(velocity: velocity) }
        }
        swipe.install(view: library.view, drawer: library.drawer, sidebar: sidebar)
    }

    /// The search field of the displayed Library category.
    var libraryFocusView: NSView {
        switch library.category {
        case .downloads: downloadsPane.searchField
        case .archive: archive.view.searchField
        case .history: library.historyView.searchField
        case .spaces: library.spacesView
        case .media: library.mediaView.searchField
        case .boosts: library.boostsView.searchField
        }
    }

    func findInLibraryOrPage() {
        guard !library.isPresented || peek.isPresented else { return }
        showFind()
    }

    func hideLibrary(focus: Bool = true, velocity: Double? = nil) {
        guard library.isPresented else { return }
        library.isPresented = false
        library.presentationID = UUID()
        library.drawer.setPresented(false, velocity: velocity)
        findSession.select(pageCommandSurface())
        renderFind()
        refreshPageZoom()
        if focus {
            if let surface = presentedPeekSurface { surface.focusDocument() }
            else { focusSelectedDocument() }
        }
    }

    private func finishHidingLibrary() {
        guard !library.isPresented else { return }
        library.displayedProfileID = nil
        if let root = window?.contentView {
            root.addSubview(peek.overlay, positioned: .below, relativeTo: windowShell.floatingBackdrop)
            root.addSubview(library.view, positioned: .below, relativeTo: peek.overlay)
        }
        deactivateArchiveCategory()
        hideDownloads()
        library.history.stop()
        library.spacesTask?.cancel(); library.spacesTask = nil
        library.spacesView.clear()
        library.mediaView.clear()
        library.boostsTask?.cancel(); library.boostsTask = nil
        library.boostsView.clear()
    }

    func renderLibrary() {
        guard library.isPresented else {
            if let displayed = library.displayedProfileID,
               displayed != session.activeProfileID || session.isClosed {
                library.drawer.finishClosing()
            }
            return
        }
        guard let profile = session.activeProfileID else { hideLibrary(); return }
        library.displayedProfileID = profile
        windowShell.libraryPreservesDocumentWidth = library.category == .spaces
        library.widthConstraint?.isActive = library.category != .spaces
        library.spacesWidthConstraint?.isActive = library.category == .spaces
        library.view.select(library.category, theme: windowShell.theme)
        library.historyView.isHidden = library.category != .history
        library.spacesView.isHidden = library.category != .spaces
        library.mediaView.isHidden = library.category != .media
        library.boostsView.isHidden = library.category != .boosts
        if library.category == .boosts { renderLibraryBoosts() }
        else { library.boostsTask?.cancel(); library.boostsView.clear() }
        if library.category == .media { renderLibraryMedia() } else { library.mediaView.clear() }
        if library.category == .spaces, let catalog = session.catalog {
            var icons: [SpaceID: BrowserSpaceIcon] = [:]
            for space in catalog.spaces {
                if let icon = settingsPreferences?.runtime.document.space(space.id).iconSelection { icons[space.id] = icon }
            }
            library.spacesView.render(catalog: catalog, activeSpaceID: session.snapshot?.activeSpaceID,
                sourceProfile: profile, icons: icons, presentation: library.presentationID,
                themes: Dictionary(uniqueKeysWithValues: catalog.spaces.map { ($0.id, resolvedSpaceTheme(for: $0.id)) }))
            let ticket = library.presentationID
            library.spacesTask?.cancel()
            library.spacesTask = Task { [weak self] in
                guard let self else { return }
                let document = await session.spaceSwipeDocument()
                guard !Task.isCancelled, library.isPresented, library.category == .spaces,
                      library.presentationID == ticket, session.activeProfileID == profile, session.catalog == catalog else { return }
                library.spacesView.renderContents(document: document, windowID: session.snapshot?.id, icon: sidebar.previewIcon)
            }
        } else { library.spacesTask?.cancel(); library.spacesTask = nil; library.spacesView.clear() }
        if library.category == .archive {
            hideDownloads()
            archive.isPresented = true
            archive.view.isHidden = false
            renderArchive()
        } else {
            deactivateArchiveCategory()
            if library.category == .downloads {
                // Follow the current Space's profile on every projection, never the opening Space.
                if downloadsProfileID != profile { downloadsPane.searchField.stringValue = "" }
                downloadsProfileID = profile
                downloadsPane.isHidden = false
                renderDownloads()
            } else { hideDownloads() }
        }
        if library.category == .history { library.history.selectProfile(profile) }
        else { library.history.stop() }
    }

    func renderLibraryMedia() {
        guard library.isPresented, library.category == .media, let profile = session.activeProfileID else { return }
        library.mediaView.render(downloads.snapshots(profileID: profile), profile: profile)
    }

    private func deleteLibraryHistory(_ deletion: BrowserHistoryDeletion) {
        guard acceptsCommands, let profile = library.history.profileID, session.activeProfileID == profile else { return }
        recordExplicitInput()
        library.deletionTask = Task { [weak self] in
            guard let self, acceptsCommands, !session.isClosed,
                  library.isPresented, library.category == .history,
                  session.activeProfileID == profile else { return }
            await library.history.delete(deletion, in: profile)
        }
    }

    /// nil requests a custom, half-open range. Confirmations capture the displayed profile.
    private func confirmLibraryHistoryDeletion(_ deletion: BrowserHistoryDeletion?) {
        guard acceptsCommands, let window, let profile = library.history.profileID,
              session.activeProfileID == profile else { return }
        let alert = NSAlert()
        let name = session.catalog?.profiles.first { $0.id == profile }?.name ?? libraryText("profile", "Profile")
        alert.messageText = String.localizedStringWithFormat(libraryText("deleteProfile", "Delete History — %@"), name)
        let target = libraryHistoryDeletionDescription(deletion)
        alert.informativeText = target + "\n" + libraryText("deleteExplanation", "This cannot be undone. Other profiles, downloads, cookies and archived tabs are kept.")
        alert.addButton(withTitle: libraryText("delete", "Delete"))
        alert.addButton(withTitle: libraryText("cancel", "Cancel"))
        let range = BrowserLibraryDateRangeView()
        if deletion == nil {
            range.confirmButton = alert.buttons.first
            range.onChange = { [weak alert] interval in
                alert?.informativeText = libraryHistoryDeletionDescription(interval.map(BrowserHistoryDeletion.interval))
                    + "\n" + libraryText("deleteExplanation", "This cannot be undone. Other profiles, downloads, cookies and archived tabs are kept.")
            }
            range.validateInterval()
            alert.accessoryView = range
        }
        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  library.isPresented, library.category == .history,
                  library.history.profileID == profile, session.activeProfileID == profile else { return }
            if let deletion { deleteLibraryHistory(deletion) }
            else if let interval = range.interval {
                deleteLibraryHistory(.interval(interval))
            }
        }
        if let present = library.historyConfirmation {
            library.confirmationTask = Task { respond(await present(alert)) }
        } else { alert.beginSheetModal(for: window, completionHandler: respond) }
    }
}
