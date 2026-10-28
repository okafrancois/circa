import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// Space themes in a browser window (ORBIT-THEMES): resolution of the painted theme and the editor.
extension BrowserWindowController {
    var canEditActiveSpaceTheme: Bool {
        guard !isPrivateWindow, acceptsCommands, !session.isClosed, themeEditors?.isFrozen != true,
              let spaceID = session.snapshot?.activeSpaceID, let profileID = session.activeProfileID else { return false }
        return session.catalog?.spaces.contains { $0.id == spaceID && $0.profileID == profileID } == true
            && themeEditors?.canBeginEditing(spaceID: spaceID, profileID: profileID) != false
    }

    /// Resolve after earlier accepted Space switches, using the session's validated authority.
    /// Captured registry targets are checked before delivery; this boundary never activates a Space.
    func presentActiveSpaceThemeEditor() {
        guard acceptsCommands, themeEditors?.isFrozen != true else { return }
        session.performWindowAction { [weak self] in
            guard let self, canEditActiveSpaceTheme, let spaceID = session.snapshot?.activeSpaceID else { return }
            openThemeEditor(for: spaceID)
        }
    }

    /// Painted theme of a Space in this window: the open editor's draft, the stored theme, the legacy
    /// Settings palette, then the default. Window fill, sidebar titles, split border and the command
    /// bar's selection all derive from it.
    func resolvedSpaceTheme(for spaceID: SpaceID?) -> OrbitTokens.SpaceTheme {
        if isPrivateWindow { return OrbitSpaceThemes.privateWindow }
        if let editor = themeEditor,
           session.catalog?.spaces.contains(where: { $0.id == spaceID && $0.profileID == editor.profileID }) == true,
           let draft = editor.previewTheme(for: spaceID) { return OrbitSpaceThemes.rendered(draft) }
        return OrbitSpaceThemes.theme(forSpace: spaceID, in: session.catalog,
                                    legacy: spaceID.flatMap { settingsPreferences?.theme(for: $0) })
    }

    /// The model the editor starts from: stored theme, legacy palette, default.
    func editableSpaceTheme(for space: BrowserSpace) -> BrowserSpaceTheme {
        space.theme ?? settingsPreferences?.runtime.document.space(space.id).palette.themeModel ?? BrowserSpaceThemePresets.default
    }

    /// "Edit Theme Color…" (Space context menu, C24): shows that Space, then opens its editor.
    func presentThemeEditor(for spaceID: SpaceID) {
        guard acceptsCommands else { return }
        if session.snapshot?.activeSpaceID != spaceID { session.activateSpace(spaceID) }
        session.performWindowAction { [weak self] in
            guard let self, session.snapshot?.activeSpaceID == spaceID else { return }
            openThemeEditor(for: spaceID)
        }
    }

    func openThemeEditor(for spaceID: SpaceID, animated: Bool = true) {
        guard acceptsCommands, themeEditors?.isFrozen != true, let window, let space = session.catalog?.spaces.first(where: { $0.id == spaceID }) else { return }
        guard themeEditors?.canBeginEditing(spaceID: spaceID, profileID: space.profileID) != false else { return }
        if let current = themeEditor {
            if current.spaceID == spaceID, !current.isClosed { current.panel?.makeKey(); return }
            current.close(animated: false)
        }
        let profileID = space.profileID
        // The session, not the window: the final write of a window closed mid-edit still lands.
        let session: BrowserWindowSession<Surface> = session
        let editor = OrbitThemeEditorController(
            spaceID: spaceID, profileID: profileID, stored: space.theme, initial: editableSpaceTheme(for: space),
            scopeDescription: space.name + " · " + (session.catalog?.profiles.first(where: { $0.id == profileID })?.name ?? uiText("Profile")),
            commit: { theme in _ = try await session.setSpaceTheme(theme, for: spaceID, profileID: profileID) },
            replay: { change in try await session.applySpaceThemeChange(change) })
        editor.onPreview = { [weak self] _ in self?.renderChrome() }
        editor.onClosed = { [weak self, weak editor] in
            guard let self else { return }
            // Keep painting the draft until this window's catalog carries the committed theme.
            Task { [weak self] in
                guard let self else { return }
                session.refreshCatalog()
                await session.waitForQueuedCommands()
                if themeEditor === editor { themeEditor = nil }
                renderChrome()
            }
        }
        themeEditors?.track(editor)
        themeEditor = editor
        editor.present(in: window, topLeft: themeEditorOrigin, animated: animated)
    }

    /// : the content card's left edge + 13, 13 below the window's top.
    var themeEditorOrigin: CGPoint {
        let offset = OrbitThemeEditorMetrics.offsetFromCard
        guard let content = window?.contentView else { return offset }
        let card = contentCard.convert(contentCard.bounds, to: content)
        return CGPoint(x: card.minX + offset.x, y: offset.y)
    }

    /// A Space switch, or the Space leaving the catalog, ends the editing session.
    func closeThemeEditorIfNeeded(activeSpaceID: SpaceID?) {
        guard let editor = themeEditor, !editor.isClosed else { return }
        let exists = session.catalog?.spaces.contains { $0.id == editor.spaceID && $0.profileID == editor.profileID } ?? false
        if editor.spaceID != activeSpaceID || !exists { editor.close() }
    }
}
