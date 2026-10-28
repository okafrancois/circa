import AppKit

/// Semantic IDs shared by menus, keyboard input, context menus and the command palette.
enum BrowserCommandID: String, CaseIterable, Sendable {
    case boostGallery
    case showHideSidebar
    case newChatGPTMessage
    case goForward
    case cancelTrace
    case changeProfile
    case zoomOut
    case visitHelpCenter
    case aboutOrbit
    case redo
    case collapseAllFolders
    case renameCurrentItem
    case viewDownloads
    case expandAllFolders
    case cycleTabBackward
    case pinUnpinTab
    case addSplitView
    case tabSwitcherBackward
    case peekEmail
    case closeThisSplitPane
    case openCommandBar
    case setAsDefaultBrowser
    case capture
    case recordTrace
    case developerTools
    case showSpellingAndGrammar
    case dark
    case essentialKeyboardShortcuts
    case resetAllTabsInThisSpace
    case showAll
    case privacyPolicy
    case goBack
    case shareOrbit
    case openTaskManager
    case newProfile
    case copyURLAsMarkdown
    case editBoost
    case enterExitFullScreen
    case renameSpace
    case viewLibrary
    case newQuickWindowWindow
    case hideOrbit
    case findPrevious
    case clearUnpinnedTabs
    case stopLoading
    case networkInspector
    case selectAll
    case jumpToSelection
    case manageSpaces
    case duplicate
    case closeWindow
    case copyOrbitInfo
    case revealOrbitData
    case share
    case pageShare
    case expandPinnedSection
    case expandCurrentSplit
    case automatic
    case viewSource
    case viewMedia
    case newWindow
    case newNote
    case refreshThePage
    case restoreLastClosedTab
    case hideOtherWindows
    case pasteAndMatchStyle
    case revealTabInSidebar
    case zoomToActualSize
    case revealCurrentTab
    case gettingStarted
    case find
    case nextSpace
    case findAndReplace
    case newTab
    case collapsePinnedSection
    case previousTab
    case viewBoosts
    case cycleTabForward
    case newBoost
    case copyURL
    case print
    case captureInPortraitMode
    case useSelectionToFind
    case viewArchive
    case newFolder
    case archiveTab
    case manageExtensions
    case openPasswordManager
    case quitOrbit
    case minimizeWindow
    case preferences
    case tabSwitcherForward
    case newIncognitoWindow
    case forceRefreshThePage
    case zoomIn
    case exportOrbitNotes
    case paste
    case clearCacheAndRefresh
    case showHideToolbar
    case previousSpace
    case light
    case joinMeeting
    case viewHistory
    case sendToDia
    case clearArchive
    case newLegacyBoostAdvanced
    case newSpace
    case savePageAs
    case newNoteInSplit
    case addExtension
    case captureFullPage
    case findNext
    case newEasel
    case toggleDeveloperMode
    case contactTheTeam
    case separatePageFromSplitView
    case javascriptConsole
    case exit
    case checkForUpdates
    case resetTabToOriginalURL
    case releaseNotes
    case cast
    case inspectElements
    case cut
    case nextTab
    case copyURLAsQuote
    case editTheme
    case clearCookiesAndRefresh
    case importFromAnotherBrowser
    case copy
    case blankWindow
    case closeQuickWindow, focusQuickWindowAddress, reloadQuickWindow
    case openQuickWindowOrPeekIn
    case restoreData
    case viewEaselsNotes
    case troubleshooting
    case item1
    case item2
    case item3
    case zoom
    case bringAllToFront
    case signOut
    case correctSpellingAutomatically
    case smartCopyPaste
    case underline
    case textReplacement
    case bold
    case stopSpeaking
    case delete
    case capitalize
    case startSpeaking
    case smartLinks
    case makeLowerCase
    case undo
    case smartQuotes
    case checkDocumentNow
    case allowJavaScriptFromAppleEvents
    case checkGrammarWithSpelling
    case checkSpellingWhileTyping
    case smartDashes
    case dataDetectors
    case makeUpperCase
    case italic
    case showSubstitutions
    case services
    case spellingAndGrammar
    case substitutions
    case transformations
    case speech
    case format
    case font
    case appearance
    case websitesEaselsAndNotesWillUse
    case developer
    case selectTab1
    case selectSpace1
    case selectTab2
    case selectSpace2
    case selectTab3
    case selectSpace3
    case selectTab4
    case selectSpace4
    case selectTab5
    case selectSpace5
    case selectTab6
    case selectSpace6
    case selectTab7
    case selectSpace7
    case selectTab8
    case selectSpace8
    case selectTab9
    case selectSpace9
    case closeSwitcherTab
    case promoteQuickWindow
    case chooseQuickWindowSpace
    case dismissPeek
    case cycleExtensions
    case removeSuggestion
    case pasteAsNewTab
    case showSiteControls
    case removeFavorite
    case renameFavorite
    case copyFavoriteLink
    case resetFavorite
    case sidebarCopyLinks
    case sidebarCopyMarkdownLinks
    case sidebarDuplicate
    case sidebarArchiveOtherTabs, sidebarArchiveTabsAbove, sidebarArchiveTabsBelow, sidebarMuteTab
    case sidebarAddToFavorites
    case sidebarCloseItems
    case sidebarDeleteFolder
    case sidebarDeleteFolderAndTabs
    case toggleSplitOrientation, swapSplitPanes, unsplitAllPanes
    case focusNextSplitPane, focusPreviousSplitPane
    case importFromArc
    case importArcConnections, restoreArcConnections
    case importBookmarks, exportBookmarks
    // CH-ESSENTIALS page context menu (see BrowserPageContextCommands).
    case pageOpenLinkInNewTab, pageOpenLinkInSplitView, pageSaveLinkAs, pageCopyLinkAddress, pageCopyEmailAddress
    case pageOpenImageInNewTab, pageSaveImageAs, pageCopyImage, pageCopyImageAddress
    case pageOpenMediaInNewTab, pageSaveMediaAs, pageCopyMediaAddress
    case pageMediaLoop, pageMediaShowControls, pageMediaPictureInPicture
    case pageLookUp, pageSearchSelection
    case pageSpellingSuggestion0, pageSpellingSuggestion1, pageSpellingSuggestion2, pageSpellingSuggestion3, pageSpellingSuggestion4
    case pageAddToDictionary, pageEmojiAndSymbols
    case pageUndo, pageRedo, pageCut, pageCopy, pagePaste, pagePasteAndMatchStyle, pageSelectAll
    case pageBack, pageForward, pageReload, pagePrint, pageViewSource, pageInspect
}

/// Serialized declaration, not evidence that Orbit executed the command.
struct OrbitMenuDeclaration: Sendable {
    let command: BrowserCommandID
    let title: String
    let menu: String
    let key: String
    let modifierMask: UInt?
    let localizesKey: Bool
    let source: String
    let owner: String
    var shortcut: BrowserShortcut? {
        guard !key.isEmpty else { return nil }
        // NSCoder's omitted keyed integer decodes to zero. Preserve the raw optional field
        // above; F12 and Escape therefore carry an empty effective modifier mask.
        return BrowserShortcut(key: key, modifiers: NSEvent.ModifierFlags(rawValue: modifierMask ?? 0))
    }
}

enum OrbitCommandCatalog {
    /// Compatibility IDs for menu structure are retained separately from executable commands.
    static let structuralIDs: Set<BrowserCommandID> = [
        .services, .spellingAndGrammar, .substitutions, .transformations, .speech, .format,
        .font, .appearance, .websitesEaselsAndNotesWillUse, .developer, .troubleshooting,
        .item1, .item2, .item3
    ]
    /// Hidden on every command surface even if an internal workflow retains a handler.
    static let hiddenCommands: Set<BrowserCommandID> = [.importArcConnections, .restoreArcConnections, .importBookmarks, .exportBookmarks]

    static func isCommandBarAction(_ definition: BrowserCommandDefinition) -> Bool {
        definition.scope == .browser && !hiddenCommands.contains(definition.id) && !structuralIDs.contains(definition.id)
            && !["Sidebar", "FavoritesContext", "Page Context"].contains(definition.menu)
    }

    static var actionDefinitions: [BrowserCommandDefinition] { definitions.filter { !structuralIDs.contains($0.id) } }

    static let declarations: [OrbitMenuDeclaration] = [
        .init(command: .boostGallery, title: "Boost Gallery", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.1", owner: "BOOSTS"),
        .init(command: .showHideSidebar, title: "Show/Hide Sidebar", menu: "View", key: "s", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.2", owner: "SHELL"),
        .init(command: .newChatGPTMessage, title: "New ChatGPT Message…", menu: "Tabs", key: "g", modifierMask: 1572864, localizesKey: true, source: "menu.declaration.3", owner: "OUT-OF-SCOPE-AI"),
        .init(command: .goForward, title: "Go Forward", menu: "Archive", key: "]", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.4", owner: "SHELL"),
        .init(command: .cancelTrace, title: "Cancel Trace", menu: "Troubleshooting", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.5", owner: "SHELL"),
        .init(command: .changeProfile, title: "Change Profile", menu: "Spaces", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.6", owner: "ORG"),
        .init(command: .zoomOut, title: "Zoom Out", menu: "View", key: "-", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.7", owner: "SHELL"),
        .init(command: .visitHelpCenter, title: "Visit Help Center", menu: "Help", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.8", owner: "SHELL"),
        .init(command: .aboutOrbit, title: "About Orbit", menu: "Orbit", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.9", owner: "SHELL"),
        .init(command: .redo, title: "Redo", menu: "Edit", key: "Z", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.10", owner: "SHELL"),
        .init(command: .collapseAllFolders, title: "Collapse All Folders", menu: "Tabs", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.11", owner: "ORG"),
        .init(command: .renameCurrentItem, title: "Rename Current Item", menu: "Tabs", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.12", owner: "ORG"),
        .init(command: .viewDownloads, title: "View Downloads", menu: "Window", key: "J", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.13", owner: "SHELL"),
        .init(command: .expandAllFolders, title: "Expand All Folders", menu: "Tabs", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.14", owner: "ORG"),
        .init(command: .cycleTabBackward, title: "Cycle Tab Backward", menu: "Tabs", key: "\u{F702}", modifierMask: 1310720, localizesKey: true, source: "menu.declaration.15", owner: "ORG"),
        .init(command: .pinUnpinTab, title: "Pin/Unpin Tab", menu: "Tabs", key: "d", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.16", owner: "ORG"),
        .init(command: .addSplitView, title: "Add Split View", menu: "View", key: "=", modifierMask: 393216, localizesKey: true, source: "menu.declaration.17", owner: "SPLIT"),
        .init(command: .tabSwitcherBackward, title: "Tab Switcher (backward)", menu: "Tabs", key: "\u{19}", modifierMask: 393216, localizesKey: true, source: "menu.declaration.18", owner: "PALETTE"),
        .init(command: .peekEmail, title: "Peek Email…", menu: "Tabs", key: "E", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.19", owner: "MAIL"),
        .init(command: .closeThisSplitPane, title: "Close this Split Pane", menu: "View", key: "-", modifierMask: 393216, localizesKey: true, source: "menu.declaration.20", owner: "SPLIT"),
        .init(command: .openCommandBar, title: "Open Command Bar", menu: "File", key: "l", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.21", owner: "PALETTE"),
        .init(command: .setAsDefaultBrowser, title: "Set as Default Browser", menu: "Orbit", key: "", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.22", owner: "SHELL"),
        .init(command: .capture, title: "Capture…", menu: "File", key: "2", modifierMask: 1179648, localizesKey: true, source: "menu.declaration.23", owner: "CAPTURE"),
        .init(command: .recordTrace, title: "Record Trace", menu: "Troubleshooting", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.24", owner: "SHELL"),
        .init(command: .developerTools, title: "Developer Tools", menu: "Developer", key: "\u{F70F}", modifierMask: nil, localizesKey: true, source: "menu.declaration.25", owner: "ENGINE/SHELL"),
        .init(command: .showSpellingAndGrammar, title: "Show Spelling and Grammar", menu: "Spelling", key: ":", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.26", owner: "EDITING"),
        .init(command: .dark, title: "Dark", menu: "", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.27", owner: "THEME"),
        .init(command: .essentialKeyboardShortcuts, title: "Essential Keyboard Shortcuts", menu: "Help", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.28", owner: "SETTINGS"),
        .init(command: .resetAllTabsInThisSpace, title: "Reset all tabs in this Space", menu: "Tabs", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.29", owner: "ORG"),
        .init(command: .showAll, title: "Show All", menu: "Orbit", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.30", owner: "SHELL"),
        .init(command: .privacyPolicy, title: "Privacy Policy", menu: "Orbit", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.31", owner: "SHELL"),
        .init(command: .goBack, title: "Go Back", menu: "Archive", key: "\u{F702}", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.32", owner: "SHELL"),
        .init(command: .shareOrbit, title: "Share Orbit", menu: "Orbit", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.33", owner: "SHELL"),
        .init(command: .openTaskManager, title: "Open Task Manager", menu: "Troubleshooting", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.34", owner: "SHELL"),
        .init(command: .newProfile, title: "New Profile", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.35", owner: "ENGINE/SHELL"),
        .init(command: .copyURLAsMarkdown, title: "Copy URL as Markdown", menu: "Edit", key: "C", modifierMask: 1572864, localizesKey: true, source: "menu.declaration.36", owner: "EDITING"),
        .init(command: .editBoost, title: "Edit Boost", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.37", owner: "BOOSTS"),
        .init(command: .enterExitFullScreen, title: "Enter/Exit Full Screen", menu: "View", key: "f", modifierMask: 1310720, localizesKey: true, source: "menu.declaration.38", owner: "SHELL"),
        .init(command: .renameSpace, title: "Rename Space", menu: "Spaces", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.39", owner: "ORG"),
        .init(command: .viewLibrary, title: "View Library", menu: "Window", key: "L", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.40", owner: "LIBRARY"),
        .init(command: .newQuickWindowWindow, title: "New Little Orbit Window", menu: "File", key: "n", modifierMask: 1572864, localizesKey: true, source: "menu.declaration.41", owner: "LITTLE/PEEK"),
        .init(command: .hideOrbit, title: "Hide Orbit", menu: "Orbit", key: "h", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.42", owner: "SHELL"),
        .init(command: .findPrevious, title: "Find Previous", menu: "Find", key: "G", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.43", owner: "SHELL"),
        .init(command: .clearUnpinnedTabs, title: "Clear Unpinned Tabs", menu: "Tabs", key: "K", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.44", owner: "ORG"),
        .init(command: .stopLoading, title: "Stop Loading", menu: "View", key: ".", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.45", owner: "SHELL"),
        .init(command: .networkInspector, title: "Network Inspector", menu: "Developer", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.46", owner: "ENGINE/SHELL"),
        .init(command: .selectAll, title: "Select All", menu: "Edit", key: "a", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.47", owner: "SHELL"),
        .init(command: .jumpToSelection, title: "Jump to Selection", menu: "Find", key: "j", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.48", owner: "EDITING"),
        .init(command: .manageSpaces, title: "Manage Spaces…", menu: "Spaces", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.49", owner: "ORG"),
        .init(command: .duplicate, title: "Duplicate", menu: "Tabs", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.50", owner: "SHELL"),
        .init(command: .closeWindow, title: "Close Window", menu: "File", key: "W", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.51", owner: "SHELL"),
        .init(command: .copyOrbitInfo, title: "Copy Orbit Info", menu: "Troubleshooting", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.52", owner: "SHELL"),
        .init(command: .revealOrbitData, title: "Reveal Orbit Data", menu: "Troubleshooting", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.53", owner: "SHELL"),
        .init(command: .share, title: "Share…", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.54", owner: "SHELL"),
        .init(command: .expandPinnedSection, title: "Expand Pinned Section", menu: "View", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.55", owner: "THEME"),
        .init(command: .expandCurrentSplit, title: "Expand Current Split", menu: "View", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.56", owner: "SPLIT"),
        .init(command: .automatic, title: "Automatic", menu: "", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.57", owner: "THEME"),
        .init(command: .viewSource, title: "View Source", menu: "Developer", key: "u", modifierMask: 1572864, localizesKey: true, source: "menu.declaration.58", owner: "ENGINE/SHELL"),
        .init(command: .viewMedia, title: "View Media", menu: "Window", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.59", owner: "SHELL"),
        .init(command: .newWindow, title: "New Window", menu: "File", key: "n", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.60", owner: "SHELL"),
        .init(command: .newNote, title: "New Note", menu: "File", key: "N", modifierMask: 262144, localizesKey: true, source: "menu.declaration.61", owner: "SHELL"),
        .init(command: .refreshThePage, title: "Refresh the Page", menu: "View", key: "r", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.62", owner: "SHELL"),
        .init(command: .restoreLastClosedTab, title: "Restore Last Closed Tab", menu: "File", key: "T", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.63", owner: "SHELL"),
        .init(command: .hideOtherWindows, title: "Hide Other Windows", menu: "Orbit", key: "h", modifierMask: 1572864, localizesKey: true, source: "menu.declaration.64", owner: "SHELL"),
        .init(command: .pasteAndMatchStyle, title: "Paste and Match Style", menu: "Edit", key: "V", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.65", owner: "SHELL"),
        .init(command: .revealTabInSidebar, title: "Reveal Tab in Sidebar", menu: "Tabs", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.66", owner: "ORG"),
        .init(command: .zoomToActualSize, title: "Zoom to Actual Size", menu: "View", key: "0", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.67", owner: "SHELL"),
        .init(command: .revealCurrentTab, title: "Reveal Current Tab", menu: "View", key: " ", modifierMask: 262144, localizesKey: true, source: "menu.declaration.68", owner: "SHELL"),
        .init(command: .gettingStarted, title: "Getting Started", menu: "Help", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.69", owner: "SHELL"),
        .init(command: .find, title: "Find…", menu: "Find", key: "f", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.70", owner: "SHELL"),
        .init(command: .nextSpace, title: "Next Space", menu: "Spaces", key: "\u{F703}", modifierMask: 1572864, localizesKey: true, source: "menu.declaration.71", owner: "SHELL"),
        .init(command: .findAndReplace, title: "Find and Replace", menu: "Find", key: "f", modifierMask: 1572864, localizesKey: true, source: "menu.declaration.72", owner: "EDITING"),
        .init(command: .newTab, title: "New Tab…", menu: "File", key: "t", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.73", owner: "PALETTE"),
        .init(command: .collapsePinnedSection, title: "Collapse Pinned Section", menu: "View", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.74", owner: "THEME"),
        .init(command: .previousTab, title: "Previous Tab", menu: "Tabs", key: "\u{F700}", modifierMask: 1572864, localizesKey: true, source: "menu.declaration.75", owner: "ORG"),
        .init(command: .viewBoosts, title: "View Boosts", menu: "Window", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.76", owner: "BOOSTS"),
        .init(command: .cycleTabForward, title: "Cycle Tab Forward", menu: "Tabs", key: "\u{F703}", modifierMask: 1310720, localizesKey: true, source: "menu.declaration.77", owner: "ORG"),
        .init(command: .newBoost, title: "New Boost", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.78", owner: "BOOSTS"),
        .init(command: .copyURL, title: "Copy URL", menu: "Edit", key: "C", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.79", owner: "SHELL"),
        .init(command: .print, title: "Print", menu: "File", key: "p", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.80", owner: "ENGINE/SHELL"),
        .init(command: .captureInPortraitMode, title: "Capture in Portrait Mode", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.81", owner: "CAPTURE"),
        .init(command: .useSelectionToFind, title: "Use Selection to Find", menu: "Find", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.82", owner: "EDITING"),
        .init(command: .viewArchive, title: "View Archive", menu: "Archive", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.83", owner: "LIBRARY"),
        .init(command: .goBack, title: "Go Back", menu: "Archive", key: "[", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.84", owner: "SHELL"),
        .init(command: .newFolder, title: "New Folder…", menu: "Tabs", key: "N", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.85", owner: "ORG"),
        .init(command: .archiveTab, title: "Archive Tab", menu: "File", key: "w", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.86", owner: "SHELL"),
        .init(command: .manageExtensions, title: "Manage Extensions…", menu: "Extensions", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.87", owner: "EXTENSIONS"),
        .init(command: .quitOrbit, title: "Quit Orbit", menu: "Orbit", key: "q", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.88", owner: "SHELL"),
        .init(command: .minimizeWindow, title: "Minimize Window", menu: "Window", key: "m", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.89", owner: "SHELL"),
        .init(command: .preferences, title: "Preferences…", menu: "Orbit", key: ",", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.90", owner: "SETTINGS"),
        .init(command: .tabSwitcherForward, title: "Tab Switcher (forward)", menu: "Tabs", key: "\t", modifierMask: 262144, localizesKey: true, source: "menu.declaration.91", owner: "PALETTE"),
        .init(command: .newIncognitoWindow, title: "New Incognito Window", menu: "File", key: "N", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.92", owner: "ENGINE/SHELL"),
        .init(command: .forceRefreshThePage, title: "Force Refresh the Page", menu: "View", key: "R", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.93", owner: "SHELL"),
        .init(command: .zoomIn, title: "Zoom In", menu: "View", key: "+", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.94", owner: "SHELL"),
        .init(command: .exportOrbitNotes, title: "Export Orbit Notes", menu: "Help", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.95", owner: "SHELL"),
        .init(command: .paste, title: "Paste", menu: "Edit", key: "v", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.96", owner: "SHELL"),
        .init(command: .clearCacheAndRefresh, title: "Clear Cache and Refresh", menu: "View", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.97", owner: "SHELL"),
        .init(command: .showHideToolbar, title: "Show/Hide Toolbar", menu: "View", key: "D", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.98", owner: "THEME"),
        .init(command: .previousSpace, title: "Previous Space", menu: "Spaces", key: "\u{F702}", modifierMask: 1572864, localizesKey: true, source: "menu.declaration.99", owner: "SHELL"),
        .init(command: .light, title: "Light", menu: "", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.100", owner: "THEME"),
        .init(command: .joinMeeting, title: "Join Meeting", menu: "Tabs", key: "j", modifierMask: 1310720, localizesKey: true, source: "menu.declaration.101", owner: "CALENDAR"),
        .init(command: .viewHistory, title: "View History", menu: "Archive", key: "y", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.102", owner: "HISTORY"),
        .init(command: .sendToDia, title: "Send to Dia", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.103", owner: "SHELL"),
        .init(command: .clearArchive, title: "Clear Archive", menu: "Archive", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.104", owner: "LIBRARY"),
        .init(command: .newLegacyBoostAdvanced, title: "New Legacy Boost (Advanced)", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.105", owner: "BOOSTS"),
        .init(command: .newSpace, title: "New Space…", menu: "Spaces", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.106", owner: "SHELL"),
        .init(command: .savePageAs, title: "Save Page As", menu: "File", key: "S", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.107", owner: "ENGINE/SHELL"),
        .init(command: .newNoteInSplit, title: "New Note (in Split)", menu: "File", key: "n", modifierMask: 786432, localizesKey: true, source: "menu.declaration.108", owner: "SPLIT"),
        .init(command: .addExtension, title: "Add Extension…", menu: "Extensions", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.109", owner: "EXTENSIONS"),
        .init(command: .captureFullPage, title: "Capture Full Page", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.110", owner: "CAPTURE"),
        .init(command: .findNext, title: "Find Next", menu: "Find", key: "g", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.111", owner: "SHELL"),
        .init(command: .newEasel, title: "New Easel", menu: "File", key: "E", modifierMask: 262144, localizesKey: true, source: "menu.declaration.112", owner: "LIBRARY"),
        .init(command: .toggleDeveloperMode, title: "Toggle Developer Mode", menu: "Developer", key: "d", modifierMask: 262144, localizesKey: true, source: "menu.declaration.113", owner: "ENGINE/SHELL"),
        .init(command: .contactTheTeam, title: "Contact the Team", menu: "Help", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.114", owner: "SHELL"),
        .init(command: .separatePageFromSplitView, title: "Separate Page from Split View", menu: "View", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.115", owner: "SPLIT"),
        .init(command: .javascriptConsole, title: "JavaScript Console", menu: "Developer", key: "j", modifierMask: 1572864, localizesKey: true, source: "menu.declaration.116", owner: "ENGINE/SHELL"),
        .init(command: .exit, title: "Exit", menu: "View", key: "\u{1b}", modifierMask: nil, localizesKey: true, source: "menu.declaration.117", owner: "SHELL"),
        .init(command: .checkForUpdates, title: "Check for Updates…", menu: "Orbit", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.118", owner: "SHELL"),
        .init(command: .resetTabToOriginalURL, title: "Reset Tab to Original URL", menu: "Tabs", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.119", owner: "ORG"),
        .init(command: .releaseNotes, title: "Release Notes", menu: "Help", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.120", owner: "SHELL"),
        .init(command: .cast, title: "Cast", menu: "View", key: "", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.121", owner: "SHELL"),
        .init(command: .inspectElements, title: "Inspect Elements", menu: "Developer", key: "c", modifierMask: 1572864, localizesKey: true, source: "menu.declaration.122", owner: "ENGINE/SHELL"),
        .init(command: .cut, title: "Cut", menu: "Edit", key: "x", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.123", owner: "SHELL"),
        .init(command: .nextTab, title: "Next Tab", menu: "Tabs", key: "\u{F701}", modifierMask: 1572864, localizesKey: true, source: "menu.declaration.124", owner: "ORG"),
        .init(command: .copyURLAsQuote, title: "Copy URL as Quote", menu: "Edit", key: "C", modifierMask: 1310720, localizesKey: true, source: "menu.declaration.125", owner: "EDITING"),
        .init(command: .editTheme, title: "Edit Theme…", menu: "Spaces", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.126", owner: "ORG"),
        .init(command: .clearCookiesAndRefresh, title: "Clear Cookies and Refresh", menu: "View", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.127", owner: "SHELL"),
        .init(command: .goForward, title: "Go Forward", menu: "Archive", key: "\u{F703}", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.128", owner: "SHELL"),
        .init(command: .importFromAnotherBrowser, title: "Import from Another Browser…", menu: "Orbit", key: "", modifierMask: nil, localizesKey: true, source: "menu import command", owner: "LIBRARY"),
        .init(command: .copy, title: "Copy", menu: "Edit", key: "c", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.129", owner: "SHELL"),
        .init(command: .developerTools, title: "Developer Tools", menu: "Developer", key: "i", modifierMask: 1572864, localizesKey: true, source: "menu.declaration.130", owner: "ENGINE/SHELL"),
        .init(command: .blankWindow, title: "Blank Window", menu: "File", key: "n", modifierMask: 1310720, localizesKey: true, source: "menu.declaration.131", owner: "ENGINE/SHELL"),
        .init(command: .openQuickWindowOrPeekIn, title: "Open Little Orbit or Peek in…", menu: "Tabs", key: "o", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.132", owner: "LITTLE/PEEK"),
        .init(command: .restoreData, title: "Restore Data", menu: "Help", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.133", owner: "SHELL"),
        .init(command: .viewEaselsNotes, title: "View Easels & Notes", menu: "Window", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.134", owner: "LIBRARY"),
        .init(command: .troubleshooting, title: "Troubleshooting", menu: "Help", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.135", owner: "SHELL"),
        .init(command: .newTab, title: "New Tab…", menu: "Tabs", key: "t", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.136", owner: "PALETTE"),
        .init(command: .item1, title: "Item 1", menu: "", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.137", owner: "SHELL"),
        .init(command: .item2, title: "Item 2", menu: "", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.138", owner: "SHELL"),
        .init(command: .item3, title: "Item 3", menu: "", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.139", owner: "SHELL"),
        .init(command: .zoom, title: "Zoom", menu: "Window", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.140", owner: "SHELL"),
        .init(command: .bringAllToFront, title: "Bring All to Front", menu: "Window", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.141", owner: "SHELL"),
        .init(command: .signOut, title: "Sign Out", menu: "Orbit", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.142", owner: "SHELL"),
        .init(command: .correctSpellingAutomatically, title: "Correct Spelling Automatically", menu: "Spelling", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.143", owner: "EDITING"),
        .init(command: .smartCopyPaste, title: "Smart Copy/Paste", menu: "Substitutions", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.144", owner: "EDITING"),
        .init(command: .underline, title: "Underline", menu: "Font", key: "u", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.145", owner: "EDITING"),
        .init(command: .textReplacement, title: "Text Replacement", menu: "Substitutions", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.146", owner: "EDITING"),
        .init(command: .bold, title: "Bold", menu: "Font", key: "b", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.147", owner: "EDITING"),
        .init(command: .stopSpeaking, title: "Stop Speaking", menu: "Speech", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.148", owner: "EDITING"),
        .init(command: .zoomOut, title: "Zoom Out", menu: "View", key: "-", modifierMask: 1179648, localizesKey: true, source: "menu.declaration.149", owner: "SHELL"),
        .init(command: .delete, title: "Delete", menu: "Edit", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.150", owner: "EDITING"),
        .init(command: .capitalize, title: "Capitalize", menu: "Transformations", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.151", owner: "EDITING"),
        .init(command: .startSpeaking, title: "Start Speaking", menu: "Speech", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.152", owner: "EDITING"),
        .init(command: .smartLinks, title: "Smart Links", menu: "Substitutions", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.153", owner: "EDITING"),
        .init(command: .makeLowerCase, title: "Make Lower Case", menu: "Transformations", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.154", owner: "EDITING"),
        .init(command: .undo, title: "Undo", menu: "Edit", key: "z", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.155", owner: "SHELL"),
        .init(command: .smartQuotes, title: "Smart Quotes", menu: "Substitutions", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.156", owner: "EDITING"),
        .init(command: .checkDocumentNow, title: "Check Document Now", menu: "Spelling", key: ";", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.157", owner: "EDITING"),
        .init(command: .allowJavaScriptFromAppleEvents, title: "Allow JavaScript from Apple Events", menu: "Developer", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.158", owner: "ENGINE/SHELL"),
        .init(command: .checkGrammarWithSpelling, title: "Check Grammar With Spelling", menu: "Spelling", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.159", owner: "EDITING"),
        .init(command: .zoomIn, title: "Zoom In", menu: "View", key: "=", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.160", owner: "SHELL"),
        .init(command: .zoomIn, title: "Zoom In", menu: "View", key: "=", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.161", owner: "SHELL"),
        .init(command: .checkSpellingWhileTyping, title: "Check Spelling While Typing", menu: "Spelling", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.162", owner: "EDITING"),
        .init(command: .smartDashes, title: "Smart Dashes", menu: "Substitutions", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.163", owner: "EDITING"),
        .init(command: .dataDetectors, title: "Data Detectors", menu: "Substitutions", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.164", owner: "EDITING"),
        .init(command: .makeUpperCase, title: "Make Upper Case", menu: "Transformations", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.165", owner: "EDITING"),
        .init(command: .italic, title: "Italic", menu: "Font", key: "i", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.166", owner: "EDITING"),
        .init(command: .showSubstitutions, title: "Show Substitutions", menu: "Substitutions", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.167", owner: "EDITING"),
        .init(command: .services, title: "Services", menu: "Orbit", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.168", owner: "SHELL"),
        .init(command: .find, title: "Find", menu: "Edit", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.169", owner: "SHELL"),
        .init(command: .spellingAndGrammar, title: "Spelling and Grammar", menu: "Edit", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.170", owner: "EDITING"),
        .init(command: .substitutions, title: "Substitutions", menu: "Edit", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.171", owner: "EDITING"),
        .init(command: .transformations, title: "Transformations", menu: "Edit", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.172", owner: "EDITING"),
        .init(command: .speech, title: "Speech", menu: "Edit", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.173", owner: "EDITING"),
        .init(command: .format, title: "Format", menu: "Edit", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.174", owner: "EDITING"),
        .init(command: .font, title: "Font", menu: "Format", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.175", owner: "EDITING"),
        .init(command: .appearance, title: "Appearance", menu: "View", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.176", owner: "THEME"),
        .init(command: .websitesEaselsAndNotesWillUse, title: "Websites, Easels, and Notes will use:", menu: "", key: "", modifierMask: nil, localizesKey: true, source: "menu.declaration.177", owner: "LIBRARY"),
        .init(command: .developer, title: "Developer", menu: "View", key: "", modifierMask: 1048576, localizesKey: true, source: "menu.declaration.178", owner: "SHELL"),
    ]

    static let supplemental: [BrowserCommandDefinition] = [
        .init(id: .openPasswordManager, title: "Manage Passwords", menu: "Command Bar", shortcuts: [],
              scope: .browser, requirement: .window, owner: "PASSWORDS", sources: ["Browser command"]),
        .init(id: .selectTab1, title: "Select Tab 1", menu: "Tabs", shortcuts: [.init(key: "1", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectSpace1, title: "Select Space 1", menu: "Tabs", shortcuts: [.init(key: "1", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectTab2, title: "Select Tab 2", menu: "Tabs", shortcuts: [.init(key: "2", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectSpace2, title: "Select Space 2", menu: "Tabs", shortcuts: [.init(key: "2", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectTab3, title: "Select Tab 3", menu: "Tabs", shortcuts: [.init(key: "3", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectSpace3, title: "Select Space 3", menu: "Tabs", shortcuts: [.init(key: "3", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectTab4, title: "Select Tab 4", menu: "Tabs", shortcuts: [.init(key: "4", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectSpace4, title: "Select Space 4", menu: "Tabs", shortcuts: [.init(key: "4", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectTab5, title: "Select Tab 5", menu: "Tabs", shortcuts: [.init(key: "5", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectSpace5, title: "Select Space 5", menu: "Tabs", shortcuts: [.init(key: "5", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectTab6, title: "Select Tab 6", menu: "Tabs", shortcuts: [.init(key: "6", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectSpace6, title: "Select Space 6", menu: "Tabs", shortcuts: [.init(key: "6", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectTab7, title: "Select Tab 7", menu: "Tabs", shortcuts: [.init(key: "7", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectSpace7, title: "Select Space 7", menu: "Tabs", shortcuts: [.init(key: "7", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectTab8, title: "Select Tab 8", menu: "Tabs", shortcuts: [.init(key: "8", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectSpace8, title: "Select Space 8", menu: "Tabs", shortcuts: [.init(key: "8", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectTab9, title: "Select Tab 9", menu: "Tabs", shortcuts: [.init(key: "9", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .selectSpace9, title: "Select Space 9", menu: "Tabs", shortcuts: [.init(key: "9", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["Browser command"]),
        .init(id: .closeSwitcherTab, title: "Close Selected Switcher Tab", menu: "Tabs", shortcuts: [.init(key: "w", modifiers: .init(rawValue: 262144))], scope: .switcher, requirement: .window, owner: "PALETTE", sources: ["Browser command"]),
        .init(id: .promoteQuickWindow, title: "Open Little Orbit in Last Space", menu: "Tabs", shortcuts: [.init(key: "o", modifiers: .init(rawValue: 1048576))], scope: .quickWindow, requirement: .window, owner: "LITTLE", sources: ["Browser command"]),
        .init(id: .chooseQuickWindowSpace, title: "Open Little Orbit in Space…", menu: "Tabs", shortcuts: [.init(key: "o", modifiers: .init(rawValue: 1179648))], scope: .quickWindow, requirement: .window, owner: "LITTLE", sources: ["Browser command"]),
        .init(id: .dismissPeek, title: "Close Peek", menu: "Tabs", shortcuts: [.init(key: "\u{1b}", modifiers: .init(rawValue: 0))], scope: .peek, requirement: .window, owner: "PEEK", sources: ["Browser command"]),
        .init(id: .cycleExtensions, title: "Cycle Pinned Extensions", menu: "Tabs", shortcuts: [.init(key: "e", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "EXTENSIONS", sources: ["Browser command"]),
        .init(id: .removeSuggestion, title: "Remove Suggestion", menu: "Tabs", shortcuts: [.init(key: "\u{7f}", modifiers: .init(rawValue: 1572864))], scope: .palette, requirement: .window, owner: "PALETTE", sources: ["Browser command"]),
        .init(id: .pasteAsNewTab, title: "Paste as New Tab", menu: "Tabs", shortcuts: [.init(key: "v", modifiers: .init(rawValue: 1572864))], scope: .browser, requirement: .window, owner: "PALETTE", sources: ["Browser command"]),
    ]

    static let featureDefinitions = BrowserSiteCommands.definitions + BrowserFavoritesCommands.definitions
        + SidebarListCommands.definitions + ArcImportCommands.definitions + BrowserSplitCommands.definitions
        + BrowserPageContextCommands.definitions + BrowserBookmarkCommands.definitions

    static let definitions: [BrowserCommandDefinition] = {
        var result: [BrowserCommandDefinition] = []
        for row in declarations {
            if let index = result.firstIndex(where: { $0.id == row.command }) {
                result[index].sources.append(row.source)
                if let shortcut = row.shortcut, !result[index].shortcuts.contains(shortcut) {
                    result[index].shortcuts.append(shortcut)
                }
            } else {
                result.append(.init(id: row.command, title: row.title, menu: row.menu,
                                    shortcuts: row.shortcut.map { [$0] } ?? [],
                                    scope: scope(for: row.command), requirement: requirement(for: row.command),
                                    owner: row.owner, sources: [row.source]))
            }
        }
        return result + supplemental + featureDefinitions + BrowserQuickWindowCommands.definitions
    }()

    private static func scope(for id: BrowserCommandID) -> BrowserCommandScope {
        switch id {
        case .copy, .cut, .paste, .pasteAndMatchStyle, .redo, .selectAll, .undo: return .responder
        default: return .browser
        }
    }

    private static func requirement(for id: BrowserCommandID) -> BrowserCommandRequirement {
        switch id {
        case .checkForUpdates, .aboutOrbit, .openCommandBar, .showAll, .hideOrbit, .newWindow, .newIncognitoWindow, .hideOtherWindows, .newTab, .quitOrbit: return .application
        case .zoomOut, .findPrevious, .duplicate, .zoomToActualSize, .find, .zoomIn, .findNext, .capture, .captureFullPage, .savePageAs: return .surface
        case .refreshThePage, .copyURL, .copyURLAsMarkdown, .share: return .url
        case .goBack: return .back
        case .goForward: return .forward
        case .stopLoading: return .loading
        case .restoreLastClosedTab: return .reopen
        case .redo, .selectAll, .pasteAndMatchStyle, .paste, .cut, .copy, .undo: return .responder
        default: return .window
        }
    }
}
