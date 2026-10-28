import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// Sidebar projection and Spaces commands. Sidebar visibility (⌘S, hover reveal) lives in
/// `Window/BrowserWindowController+SidebarPresentation.swift`.
extension BrowserWindowController {
    func installSidebarActions() {
        installSidebarList()
        sidebar.spaceSwipe.allowsInput = { [weak self] in
            guard let self else { return false }
            return acceptsCommands && !session.isClosed && !palette.isPresented && !library.isPresented && !peek.isPresented
                && !siteControls.isPopoverShown && themeEditor == nil && tabSwitcher.view.superview == nil
        }
        sidebar.spaceSwipe.loadDocument = { [weak self] in
            guard let self else { return BrowserSessionDocument(profiles: [], spaces: [], windows: [], tabs: []) }
            return await session.spaceSwipeDocument()
        }
        sidebar.spaceSwipe.resolveTheme = { [weak self] id in self?.resolvedSpaceTheme(for: id) ?? .default }
        sidebar.spaceSwipe.onThemeProgress = { [weak self] blend in
            guard let self else { return }
            if blend == nil, let session, let active = session.snapshot?.activeSpaceID {
                // Publication can retire the preview before renderChrome installs its theme.
                // Adopt the published endpoint while the explicit blend still owns the paint.
                windowShell.apply(theme: resolvedSpaceTheme(for: active), animated: false)
            }
            windowShell.applySpaceSwipeBlend(blend)
            if blend == nil, let session {
                let url = session.selectedSurface?.navigationState.url ?? session.organization?.selectedTab?.url
                addressField.finishSpaceTransition(url?.absoluteString ?? String(),
                    in: session.snapshot?.activeSpaceID, spaces: session.catalog?.spaces ?? [])
            }
        }
        sidebar.spaceSwipe.onRelease = { [weak self] source, target, document in
            guard let self else { return }
            let selected = document.windows.first { $0.id.rawValue == id }?.spaces.first { $0.spaceID == target }?.selectedOccurrenceID
            let value = document.tabs.first { $0.occurrenceID == selected }?.url.absoluteString ?? String()
            addressField.setAddress(value, from: source, to: target, spaces: document.spaces, awaitingPublication: true)
        }
        sidebar.spaceSwipe.commit = { [weak self] target, catalog, admission, isCurrent, completion in
            guard let self else { completion(false); return }
            session.activateSpaceFromSwipe(target, catalog: catalog, admission: admission,
                waitForPresentation: { [weak self] in await self?.sidebar.spaceSwipe.waitForSettlement() },
                isCurrent: isCurrent, completion: completion)
        }
        sidebar.footer.onEditSpaceIcon = { [weak self] id in self?.presentSpaceIconEditor(for: id) }
        sidebar.onEditSpaceIcon = { [weak self] id in self?.presentSpaceIconEditor(for: id) }
        sidebar.onSelectSpace = { [weak self] id in
            self?.submitInput { owner in
                if !owner.sidebar.spaceSwipe.switchToSpace(id) { owner.activateSpace(id) }
            }
        }
        sidebar.onNewTab = { [weak self] in self?.submitInput { $0.openTab() } }
        sidebar.onNewSpace = { [weak self] in self?.submitInput { $0.presentNewSpace() } }
        sidebar.onDeleteSpace = { [weak self] id in self?.submitInput { $0.presentDeleteSpace(id) } }
        sidebar.onRenameSpace = { [weak self] id in self?.submitInput { $0.presentRenameSpace(id) } }
        sidebar.onEditSpaceTheme = { [weak self] id in self?.submitInput { $0.presentThemeEditor(for: id) } }
        sidebar.onMoveSpace = { [weak self] id, before in
            self?.submitInput { $0.session.moveSpace(id, before: before) }
        }
    }

    /// Projects the active Space's organization (Pinned, folders, Today) with the live titles of
    /// this window's documents; rows are diffed by `TabID`/`FolderID`.
    func rebuildTabStrip() {
        sidebarIcons.retain(Set(session.organization?.allTabs.map(\.id) ?? []))
        SpaceSwipeTrace.tabStrip {
            folderPreview.intent.reconcile(session.organization)
            updateSidebarUndoRouter()
            sidebar.render(catalog: session.catalog, activeSpaceID: session.snapshot?.activeSpaceID,
                           organization: session.organization)
        }
    }

    func activateSpace(_ id: SpaceID) {
        guard acceptsCommands else { return }
        session.activateSpace(id)
    }

    func activateAdjacentSpace(offset: Int) {
        guard acceptsCommands else { return }
        session.activateAdjacentSpace(offset: offset)
    }

    func createSpace(name: String, profileID: ProfileID) {
        guard acceptsCommands else { return }
        session.createSpace(name: name, profileID: profileID)
    }

    func presentNewSpace() {
        guard acceptsCommands else { return }
        session.performWindowAction { [weak self] in self?.presentNewSpaceSheet() }
    }

    private func presentNewSpaceSheet() {
        guard acceptsCommands, let window, let catalog = session.catalog, !catalog.profiles.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = uiText("New Space")
        alert.informativeText = uiText("Choose a name and browsing profile for this Space.")
        alert.addButton(withTitle: uiText("Create"))
        alert.addButton(withTitle: uiText("Cancel"))
        let name = NSTextField(string: uiText("New Space"))
        name.placeholderString = uiText("Space Name")
        name.setAccessibilityLabel(uiText("Space Name"))
        let profiles = NSPopUpButton(frame: .zero, pullsDown: false)
        profiles.addItems(withTitles: catalog.profiles.map(\.name))
        profiles.addItem(withTitle: uiText("New Profile…"))
        let profileName = NSTextField()
        profileName.placeholderString = uiText("New Profile Name")
        profileName.setAccessibilityLabel(uiText("New Profile Name"))
        profiles.setAccessibilityLabel(uiText("Browsing Profile"))
        if let active = catalog.spaces.first(where: { $0.id == session.snapshot?.activeSpaceID }),
           let index = catalog.profiles.firstIndex(where: { $0.id == active.profileID }) {
            profiles.selectItem(at: index)
        }
        let form = NSStackView(views: [name, profiles, profileName])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 12
        form.frame = NSRect(x: 0, y: 0, width: 300, height: 108)
        name.widthAnchor.constraint(equalToConstant: 300).isActive = true
        profiles.widthAnchor.constraint(equalToConstant: 300).isActive = true
        profileName.widthAnchor.constraint(equalToConstant: 300).isActive = true
        alert.accessoryView = form
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let title = name.stringValue
            if profiles.indexOfSelectedItem == catalog.profiles.count {
                let newProfileName = profileName.stringValue
                self?.submitInput { $0.session.createSpace(name: title, newProfileName: newProfileName) }
            } else if catalog.profiles.indices.contains(profiles.indexOfSelectedItem) {
                let profileID = catalog.profiles[profiles.indexOfSelectedItem].id
                self?.submitInput { $0.createSpace(name: title, profileID: profileID) }
            }
        }
    }

    func presentDeleteSpace(_ id: SpaceID) {
        guard acceptsCommands else { return }
        session.performWindowAction { [weak self] in
            guard let self, let window,
                  let space = session.catalog?.spaces.first(where: { $0.id == id }) else { return }
            let alert = NSAlert()
            alert.messageText = uiFormat("Delete your “%@” Space?", space.name)
            alert.informativeText = uiText("This will archive all the tabs and folders inside it.")
            alert.addButton(withTitle: uiText("Delete"))
            alert.addButton(withTitle: uiText("Cancel"))
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self, acceptsCommands else { return }
                Task { @MainActor [weak self] in
                    do { try await self?.onDeleteSpace?(id, space.profileID) }
                    catch { self?.session.onError?(error) }
                }
            }
        }
    }

    /// The displayed Space renames in place in its header; another Space or a hidden sidebar
    /// keeps the sheet (Orbit's behaviour for those cases is not observed).
    func presentRenameSpace(_ id: SpaceID) {
        guard acceptsCommands else { return }
        session.performWindowAction { [weak self] in
            guard let self else { return }
            if !beginInlineSpaceRename(id) { presentRenameSpaceSheet(id) }
        }
    }

    @discardableResult
    func beginInlineSpaceRename(_ id: SpaceID) -> Bool {
        guard acceptsCommands, window?.isVisible == true, !sidebar.isPresentationHidden,
              session.snapshot?.activeSpaceID == id, sidebar.page.spaceID == id,
              let profile = session.catalog?.spaces.first(where: { $0.id == id })?.profileID else { return false }
        return sidebar.page.beginSpaceRename { [weak self] name in
            guard let self, acceptsCommands,
                  session.catalog?.spaces.contains(where: { $0.id == id && $0.profileID == profile }) == true else { return }
            submitInput { $0.session.renameSpace(id, name: name) }
        }
    }

    private func presentRenameSpaceSheet(_ id: SpaceID) {
        guard acceptsCommands, let window, let space = session.catalog?.spaces.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = uiText("Rename Space")
        alert.addButton(withTitle: uiText("Save"))
        alert.addButton(withTitle: uiText("Cancel"))
        let name = NSTextField(string: space.name)
        name.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        name.setAccessibilityLabel(uiText("Space Name"))
        alert.accessoryView = name
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, acceptsCommands, response == .alertFirstButtonReturn else { return }
            let title = name.stringValue
            submitInput { $0.session.renameSpace(id, name: title) }
        }
    }
}
