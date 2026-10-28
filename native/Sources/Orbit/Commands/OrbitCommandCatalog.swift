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
    // SB-LIST sidebar context menus (reconstruction, see SidebarListCommands).
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
    // CORE-IMPORT (reconstruction, see ArcImportCommands).
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
        .init(command: .boostGallery, title: "Boost Gallery", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "M-8", owner: "BOOSTS"),
        .init(command: .showHideSidebar, title: "Show/Hide Sidebar", menu: "View", key: "s", modifierMask: 1048576, localizesKey: true, source: "M-33", owner: "SHELL"),
        .init(command: .newChatGPTMessage, title: "New ChatGPT Message…", menu: "Tabs", key: "g", modifierMask: 1572864, localizesKey: true, source: "M-52", owner: "OUT-OF-SCOPE-AI"),
        .init(command: .goForward, title: "Go Forward", menu: "Archive", key: "]", modifierMask: 1048576, localizesKey: true, source: "M-61", owner: "SHELL"),
        .init(command: .cancelTrace, title: "Cancel Trace", menu: "Troubleshooting", key: "", modifierMask: nil, localizesKey: true, source: "M-75", owner: "SHELL"),
        .init(command: .changeProfile, title: "Change Profile", menu: "Spaces", key: "", modifierMask: nil, localizesKey: true, source: "M-84", owner: "ORG"),
        .init(command: .zoomOut, title: "Zoom Out", menu: "View", key: "-", modifierMask: 1048576, localizesKey: true, source: "M-93", owner: "SHELL"),
        .init(command: .visitHelpCenter, title: "Visit Help Center", menu: "Help", key: "", modifierMask: nil, localizesKey: true, source: "M-103", owner: "SHELL"),
        .init(command: .aboutOrbit, title: "About Orbit", menu: "Orbit", key: "", modifierMask: nil, localizesKey: true, source: "M-115", owner: "SHELL"),
        .init(command: .redo, title: "Redo", menu: "Edit", key: "Z", modifierMask: 1048576, localizesKey: true, source: "M-124", owner: "SHELL"),
        .init(command: .collapseAllFolders, title: "Collapse All Folders", menu: "Tabs", key: "", modifierMask: nil, localizesKey: true, source: "M-134", owner: "ORG"),
        .init(command: .renameCurrentItem, title: "Rename Current Item", menu: "Tabs", key: "", modifierMask: nil, localizesKey: true, source: "M-142", owner: "ORG"),
        .init(command: .viewDownloads, title: "View Downloads", menu: "Window", key: "J", modifierMask: 1048576, localizesKey: true, source: "M-150", owner: "SHELL"),
        .init(command: .expandAllFolders, title: "Expand All Folders", menu: "Tabs", key: "", modifierMask: nil, localizesKey: true, source: "M-164", owner: "ORG"),
        .init(command: .cycleTabBackward, title: "Cycle Tab Backward", menu: "Tabs", key: "\u{F702}", modifierMask: 1310720, localizesKey: true, source: "M-172", owner: "ORG"),
        .init(command: .pinUnpinTab, title: "Pin/Unpin Tab", menu: "Tabs", key: "d", modifierMask: 1048576, localizesKey: true, source: "M-181", owner: "ORG"),
        .init(command: .addSplitView, title: "Add Split View", menu: "View", key: "=", modifierMask: 393216, localizesKey: true, source: "M-194", owner: "SPLIT"),
        .init(command: .tabSwitcherBackward, title: "Tab Switcher (backward)", menu: "Tabs", key: "\u{19}", modifierMask: 393216, localizesKey: true, source: "M-207", owner: "PALETTE"),
        .init(command: .peekEmail, title: "Peek Email…", menu: "Tabs", key: "E", modifierMask: 1048576, localizesKey: true, source: "M-219", owner: "MAIL"),
        .init(command: .closeThisSplitPane, title: "Close this Split Pane", menu: "View", key: "-", modifierMask: 393216, localizesKey: true, source: "M-228", owner: "SPLIT"),
        .init(command: .openCommandBar, title: "Open Command Bar", menu: "File", key: "l", modifierMask: 1048576, localizesKey: true, source: "M-240", owner: "PALETTE"),
        .init(command: .setAsDefaultBrowser, title: "Set as Default Browser", menu: "Orbit", key: "", modifierMask: 1048576, localizesKey: true, source: "M-249", owner: "SHELL"),
        .init(command: .capture, title: "Capture…", menu: "File", key: "2", modifierMask: 1179648, localizesKey: true, source: "M-263", owner: "CAPTURE"),
        .init(command: .recordTrace, title: "Record Trace", menu: "Troubleshooting", key: "", modifierMask: nil, localizesKey: true, source: "M-276", owner: "SHELL"),
        .init(command: .developerTools, title: "Developer Tools", menu: "Developer", key: "\u{F70F}", modifierMask: nil, localizesKey: true, source: "M-285", owner: "ENGINE/SHELL"),
        .init(command: .showSpellingAndGrammar, title: "Show Spelling and Grammar", menu: "Spelling", key: ":", modifierMask: 1048576, localizesKey: true, source: "M-294", owner: "EDITING"),
        .init(command: .dark, title: "Dark", menu: "", key: "", modifierMask: nil, localizesKey: true, source: "M-305", owner: "THEME"),
        .init(command: .essentialKeyboardShortcuts, title: "Essential Keyboard Shortcuts", menu: "Help", key: "", modifierMask: nil, localizesKey: true, source: "M-321", owner: "SETTINGS"),
        .init(command: .resetAllTabsInThisSpace, title: "Reset all tabs in this Space", menu: "Tabs", key: "", modifierMask: nil, localizesKey: true, source: "M-334", owner: "ORG"),
        .init(command: .showAll, title: "Show All", menu: "Orbit", key: "", modifierMask: nil, localizesKey: true, source: "M-344", owner: "SHELL"),
        .init(command: .privacyPolicy, title: "Privacy Policy", menu: "Orbit", key: "", modifierMask: nil, localizesKey: true, source: "M-353", owner: "SHELL"),
        .init(command: .goBack, title: "Go Back", menu: "Archive", key: "\u{F702}", modifierMask: 1048576, localizesKey: true, source: "M-361", owner: "SHELL"),
        .init(command: .shareOrbit, title: "Share Orbit", menu: "Orbit", key: "", modifierMask: nil, localizesKey: true, source: "M-369", owner: "SHELL"),
        .init(command: .openTaskManager, title: "Open Task Manager", menu: "Troubleshooting", key: "", modifierMask: nil, localizesKey: true, source: "M-382", owner: "SHELL"),
        .init(command: .newProfile, title: "New Profile", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "M-393", owner: "ENGINE/SHELL"),
        .init(command: .copyURLAsMarkdown, title: "Copy URL as Markdown", menu: "Edit", key: "C", modifierMask: 1572864, localizesKey: true, source: "M-402", owner: "EDITING"),
        .init(command: .editBoost, title: "Edit Boost", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "M-416", owner: "BOOSTS"),
        .init(command: .enterExitFullScreen, title: "Enter/Exit Full Screen", menu: "View", key: "f", modifierMask: 1310720, localizesKey: true, source: "M-428", owner: "SHELL"),
        .init(command: .renameSpace, title: "Rename Space", menu: "Spaces", key: "", modifierMask: nil, localizesKey: true, source: "M-442", owner: "ORG"),
        .init(command: .viewLibrary, title: "View Library", menu: "Window", key: "L", modifierMask: 1048576, localizesKey: true, source: "M-451", owner: "LIBRARY"),
        .init(command: .newQuickWindowWindow, title: "New Little Orbit Window", menu: "File", key: "n", modifierMask: 1572864, localizesKey: true, source: "M-463", owner: "LITTLE/PEEK"),
        .init(command: .hideOrbit, title: "Hide Orbit", menu: "Orbit", key: "h", modifierMask: 1048576, localizesKey: true, source: "M-477", owner: "SHELL"),
        .init(command: .findPrevious, title: "Find Previous", menu: "Find", key: "G", modifierMask: 1048576, localizesKey: true, source: "M-487", owner: "SHELL"),
        .init(command: .clearUnpinnedTabs, title: "Clear Unpinned Tabs", menu: "Tabs", key: "K", modifierMask: 1048576, localizesKey: true, source: "M-498", owner: "ORG"),
        .init(command: .stopLoading, title: "Stop Loading", menu: "View", key: ".", modifierMask: 1048576, localizesKey: true, source: "M-512", owner: "SHELL"),
        .init(command: .networkInspector, title: "Network Inspector", menu: "Developer", key: "", modifierMask: nil, localizesKey: true, source: "M-521", owner: "ENGINE/SHELL"),
        .init(command: .selectAll, title: "Select All", menu: "Edit", key: "a", modifierMask: 1048576, localizesKey: true, source: "M-533", owner: "SHELL"),
        .init(command: .jumpToSelection, title: "Jump to Selection", menu: "Find", key: "j", modifierMask: 1048576, localizesKey: true, source: "M-543", owner: "EDITING"),
        .init(command: .manageSpaces, title: "Manage Spaces…", menu: "Spaces", key: "", modifierMask: nil, localizesKey: true, source: "M-554", owner: "ORG"),
        .init(command: .duplicate, title: "Duplicate", menu: "Tabs", key: "", modifierMask: nil, localizesKey: true, source: "M-566", owner: "SHELL"),
        .init(command: .closeWindow, title: "Close Window", menu: "File", key: "W", modifierMask: 1048576, localizesKey: true, source: "M-574", owner: "SHELL"),
        .init(command: .copyOrbitInfo, title: "Copy Orbit Info", menu: "Troubleshooting", key: "", modifierMask: nil, localizesKey: true, source: "M-585", owner: "SHELL"),
        .init(command: .revealOrbitData, title: "Reveal Orbit Data", menu: "Troubleshooting", key: "", modifierMask: nil, localizesKey: true, source: "M-594", owner: "SHELL"),
        .init(command: .share, title: "Share…", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "M-602", owner: "SHELL"),
        .init(command: .expandPinnedSection, title: "Expand Pinned Section", menu: "View", key: "", modifierMask: nil, localizesKey: true, source: "M-617", owner: "THEME"),
        .init(command: .expandCurrentSplit, title: "Expand Current Split", menu: "View", key: "", modifierMask: nil, localizesKey: true, source: "M-629", owner: "SPLIT"),
        .init(command: .automatic, title: "Automatic", menu: "", key: "", modifierMask: nil, localizesKey: true, source: "M-640", owner: "THEME"),
        .init(command: .viewSource, title: "View Source", menu: "Developer", key: "u", modifierMask: 1572864, localizesKey: true, source: "M-655", owner: "ENGINE/SHELL"),
        .init(command: .viewMedia, title: "View Media", menu: "Window", key: "", modifierMask: nil, localizesKey: true, source: "M-668", owner: "SHELL"),
        .init(command: .newWindow, title: "New Window", menu: "File", key: "n", modifierMask: 1048576, localizesKey: true, source: "M-678", owner: "SHELL"),
        .init(command: .newNote, title: "New Note", menu: "File", key: "N", modifierMask: 262144, localizesKey: true, source: "M-690", owner: "SHELL"),
        .init(command: .refreshThePage, title: "Refresh the Page", menu: "View", key: "r", modifierMask: 1048576, localizesKey: true, source: "M-704", owner: "SHELL"),
        .init(command: .restoreLastClosedTab, title: "Restore Last Closed Tab", menu: "File", key: "T", modifierMask: 1048576, localizesKey: true, source: "M-717", owner: "SHELL"),
        .init(command: .hideOtherWindows, title: "Hide Other Windows", menu: "Orbit", key: "h", modifierMask: 1572864, localizesKey: true, source: "M-731", owner: "SHELL"),
        .init(command: .pasteAndMatchStyle, title: "Paste and Match Style", menu: "Edit", key: "V", modifierMask: 1048576, localizesKey: true, source: "M-740", owner: "SHELL"),
        .init(command: .revealTabInSidebar, title: "Reveal Tab in Sidebar", menu: "Tabs", key: "", modifierMask: nil, localizesKey: true, source: "M-752", owner: "ORG"),
        .init(command: .zoomToActualSize, title: "Zoom to Actual Size", menu: "View", key: "0", modifierMask: 1048576, localizesKey: true, source: "M-764", owner: "SHELL"),
        .init(command: .revealCurrentTab, title: "Reveal Current Tab", menu: "View", key: " ", modifierMask: 262144, localizesKey: true, source: "M-778", owner: "SHELL"),
        .init(command: .gettingStarted, title: "Getting Started", menu: "Help", key: "", modifierMask: nil, localizesKey: true, source: "M-787", owner: "SHELL"),
        .init(command: .find, title: "Find…", menu: "Find", key: "f", modifierMask: 1048576, localizesKey: true, source: "M-799", owner: "SHELL"),
        .init(command: .nextSpace, title: "Next Space", menu: "Spaces", key: "\u{F703}", modifierMask: 1572864, localizesKey: true, source: "M-808", owner: "SHELL"),
        .init(command: .findAndReplace, title: "Find and Replace", menu: "Find", key: "f", modifierMask: 1572864, localizesKey: true, source: "M-822", owner: "EDITING"),
        .init(command: .newTab, title: "New Tab…", menu: "File", key: "t", modifierMask: 1048576, localizesKey: true, source: "M-830", owner: "PALETTE"),
        .init(command: .collapsePinnedSection, title: "Collapse Pinned Section", menu: "View", key: "", modifierMask: nil, localizesKey: true, source: "M-840", owner: "THEME"),
        .init(command: .previousTab, title: "Previous Tab", menu: "Tabs", key: "\u{F700}", modifierMask: 1572864, localizesKey: true, source: "M-852", owner: "ORG"),
        .init(command: .viewBoosts, title: "View Boosts", menu: "Window", key: "", modifierMask: nil, localizesKey: true, source: "M-862", owner: "BOOSTS"),
        .init(command: .cycleTabForward, title: "Cycle Tab Forward", menu: "Tabs", key: "\u{F703}", modifierMask: 1310720, localizesKey: true, source: "M-871", owner: "ORG"),
        .init(command: .newBoost, title: "New Boost", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "M-879", owner: "BOOSTS"),
        .init(command: .copyURL, title: "Copy URL", menu: "Edit", key: "C", modifierMask: 1048576, localizesKey: true, source: "M-890", owner: "SHELL"),
        .init(command: .print, title: "Print", menu: "File", key: "p", modifierMask: 1048576, localizesKey: true, source: "M-901", owner: "ENGINE/SHELL"),
        .init(command: .captureInPortraitMode, title: "Capture in Portrait Mode", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "M-914", owner: "CAPTURE"),
        .init(command: .useSelectionToFind, title: "Use Selection to Find", menu: "Find", key: "", modifierMask: nil, localizesKey: true, source: "M-926", owner: "EDITING"),
        .init(command: .viewArchive, title: "View Archive", menu: "Archive", key: "", modifierMask: nil, localizesKey: true, source: "M-935", owner: "LIBRARY"),
        .init(command: .goBack, title: "Go Back", menu: "Archive", key: "[", modifierMask: 1048576, localizesKey: true, source: "M-946", owner: "SHELL"),
        .init(command: .newFolder, title: "New Folder…", menu: "Tabs", key: "N", modifierMask: 1048576, localizesKey: true, source: "M-959", owner: "ORG"),
        .init(command: .archiveTab, title: "Archive Tab", menu: "File", key: "w", modifierMask: 1048576, localizesKey: true, source: "M-968", owner: "SHELL"),
        .init(command: .manageExtensions, title: "Manage Extensions…", menu: "Extensions", key: "", modifierMask: nil, localizesKey: true, source: "M-978", owner: "EXTENSIONS"),
        .init(command: .quitOrbit, title: "Quit Orbit", menu: "Orbit", key: "q", modifierMask: 1048576, localizesKey: true, source: "M-988", owner: "SHELL"),
        .init(command: .minimizeWindow, title: "Minimize Window", menu: "Window", key: "m", modifierMask: 1048576, localizesKey: true, source: "M-999", owner: "SHELL"),
        .init(command: .preferences, title: "Preferences…", menu: "Orbit", key: ",", modifierMask: 1048576, localizesKey: true, source: "M-1009", owner: "SETTINGS"),
        .init(command: .tabSwitcherForward, title: "Tab Switcher (forward)", menu: "Tabs", key: "\t", modifierMask: 262144, localizesKey: true, source: "M-1018", owner: "PALETTE"),
        .init(command: .newIncognitoWindow, title: "New Incognito Window", menu: "File", key: "N", modifierMask: 1048576, localizesKey: true, source: "M-1029", owner: "ENGINE/SHELL"),
        .init(command: .forceRefreshThePage, title: "Force Refresh the Page", menu: "View", key: "R", modifierMask: 1048576, localizesKey: true, source: "M-1039", owner: "SHELL"),
        .init(command: .zoomIn, title: "Zoom In", menu: "View", key: "+", modifierMask: 1048576, localizesKey: true, source: "M-1051", owner: "SHELL"),
        .init(command: .exportOrbitNotes, title: "Export Orbit Notes", menu: "Help", key: "", modifierMask: nil, localizesKey: true, source: "M-1061", owner: "SHELL"),
        .init(command: .paste, title: "Paste", menu: "Edit", key: "v", modifierMask: 1048576, localizesKey: true, source: "M-1074", owner: "SHELL"),
        .init(command: .clearCacheAndRefresh, title: "Clear Cache and Refresh", menu: "View", key: "", modifierMask: nil, localizesKey: true, source: "M-1083", owner: "SHELL"),
        .init(command: .showHideToolbar, title: "Show/Hide Toolbar", menu: "View", key: "D", modifierMask: 1048576, localizesKey: true, source: "M-1095", owner: "THEME"),
        .init(command: .previousSpace, title: "Previous Space", menu: "Spaces", key: "\u{F702}", modifierMask: 1572864, localizesKey: true, source: "M-1108", owner: "SHELL"),
        .init(command: .light, title: "Light", menu: "", key: "", modifierMask: nil, localizesKey: true, source: "M-1121", owner: "THEME"),
        .init(command: .joinMeeting, title: "Join Meeting", menu: "Tabs", key: "j", modifierMask: 1310720, localizesKey: true, source: "M-1136", owner: "CALENDAR"),
        .init(command: .viewHistory, title: "View History", menu: "Archive", key: "y", modifierMask: 1048576, localizesKey: true, source: "M-1144", owner: "HISTORY"),
        .init(command: .sendToDia, title: "Send to Dia", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "M-1157", owner: "SHELL"),
        .init(command: .clearArchive, title: "Clear Archive", menu: "Archive", key: "", modifierMask: nil, localizesKey: true, source: "M-1171", owner: "LIBRARY"),
        .init(command: .newLegacyBoostAdvanced, title: "New Legacy Boost (Advanced)", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "M-1182", owner: "BOOSTS"),
        .init(command: .newSpace, title: "New Space…", menu: "Spaces", key: "", modifierMask: nil, localizesKey: true, source: "M-1195", owner: "SHELL"),
        .init(command: .savePageAs, title: "Save Page As", menu: "File", key: "S", modifierMask: 1048576, localizesKey: true, source: "M-1207", owner: "ENGINE/SHELL"),
        .init(command: .newNoteInSplit, title: "New Note (in Split)", menu: "File", key: "n", modifierMask: 786432, localizesKey: true, source: "M-1220", owner: "SPLIT"),
        .init(command: .addExtension, title: "Add Extension…", menu: "Extensions", key: "", modifierMask: nil, localizesKey: true, source: "M-1232", owner: "EXTENSIONS"),
        .init(command: .captureFullPage, title: "Capture Full Page", menu: "File", key: "", modifierMask: nil, localizesKey: true, source: "M-1242", owner: "CAPTURE"),
        .init(command: .findNext, title: "Find Next", menu: "Find", key: "g", modifierMask: 1048576, localizesKey: true, source: "M-1254", owner: "SHELL"),
        .init(command: .newEasel, title: "New Easel", menu: "File", key: "E", modifierMask: 262144, localizesKey: true, source: "M-1263", owner: "LIBRARY"),
        .init(command: .toggleDeveloperMode, title: "Toggle Developer Mode", menu: "Developer", key: "d", modifierMask: 262144, localizesKey: true, source: "M-1276", owner: "ENGINE/SHELL"),
        .init(command: .contactTheTeam, title: "Contact the Team", menu: "Help", key: "", modifierMask: nil, localizesKey: true, source: "M-1288", owner: "SHELL"),
        .init(command: .separatePageFromSplitView, title: "Separate Page from Split View", menu: "View", key: "", modifierMask: nil, localizesKey: true, source: "M-1300", owner: "SPLIT"),
        .init(command: .javascriptConsole, title: "JavaScript Console", menu: "Developer", key: "j", modifierMask: 1572864, localizesKey: true, source: "M-1312", owner: "ENGINE/SHELL"),
        .init(command: .exit, title: "Exit", menu: "View", key: "\u{1b}", modifierMask: nil, localizesKey: true, source: "M-1324", owner: "SHELL"),
        .init(command: .checkForUpdates, title: "Check for Updates…", menu: "Orbit", key: "", modifierMask: nil, localizesKey: true, source: "M-1337", owner: "SHELL"),
        .init(command: .resetTabToOriginalURL, title: "Reset Tab to Original URL", menu: "Tabs", key: "", modifierMask: nil, localizesKey: true, source: "M-1348", owner: "ORG"),
        .init(command: .releaseNotes, title: "Release Notes", menu: "Help", key: "", modifierMask: nil, localizesKey: true, source: "M-1359", owner: "SHELL"),
        .init(command: .cast, title: "Cast", menu: "View", key: "", modifierMask: 1048576, localizesKey: true, source: "M-1371", owner: "SHELL"),
        .init(command: .inspectElements, title: "Inspect Elements", menu: "Developer", key: "c", modifierMask: 1572864, localizesKey: true, source: "M-1380", owner: "ENGINE/SHELL"),
        .init(command: .cut, title: "Cut", menu: "Edit", key: "x", modifierMask: 1048576, localizesKey: true, source: "M-1393", owner: "SHELL"),
        .init(command: .nextTab, title: "Next Tab", menu: "Tabs", key: "\u{F701}", modifierMask: 1572864, localizesKey: true, source: "M-1402", owner: "ORG"),
        .init(command: .copyURLAsQuote, title: "Copy URL as Quote", menu: "Edit", key: "C", modifierMask: 1310720, localizesKey: true, source: "M-1412", owner: "EDITING"),
        .init(command: .editTheme, title: "Edit Theme…", menu: "Spaces", key: "", modifierMask: nil, localizesKey: true, source: "M-1424", owner: "ORG"),
        .init(command: .clearCookiesAndRefresh, title: "Clear Cookies and Refresh", menu: "View", key: "", modifierMask: nil, localizesKey: true, source: "M-1436", owner: "SHELL"),
        .init(command: .goForward, title: "Go Forward", menu: "Archive", key: "\u{F703}", modifierMask: 1048576, localizesKey: true, source: "M-1447", owner: "SHELL"),
        .init(command: .importFromAnotherBrowser, title: "Import from Another Browser…", menu: "Orbit", key: "", modifierMask: nil, localizesKey: true, source: "menu import command", owner: "LIBRARY"),
        .init(command: .copy, title: "Copy", menu: "Edit", key: "c", modifierMask: 1048576, localizesKey: true, source: "M-1465", owner: "SHELL"),
        .init(command: .developerTools, title: "Developer Tools", menu: "Developer", key: "i", modifierMask: 1572864, localizesKey: true, source: "M-1473", owner: "ENGINE/SHELL"),
        .init(command: .blankWindow, title: "Blank Window", menu: "File", key: "n", modifierMask: 1310720, localizesKey: true, source: "M-1485", owner: "ENGINE/SHELL"),
        .init(command: .openQuickWindowOrPeekIn, title: "Open Little Orbit or Peek in…", menu: "Tabs", key: "o", modifierMask: 1048576, localizesKey: true, source: "M-1495", owner: "LITTLE/PEEK"),
        .init(command: .restoreData, title: "Restore Data", menu: "Help", key: "", modifierMask: nil, localizesKey: true, source: "M-1504", owner: "SHELL"),
        .init(command: .viewEaselsNotes, title: "View Easels & Notes", menu: "Window", key: "", modifierMask: nil, localizesKey: true, source: "M-1516", owner: "LIBRARY"),
        .init(command: .troubleshooting, title: "Troubleshooting", menu: "Help", key: "", modifierMask: nil, localizesKey: true, source: "M-1601", owner: "SHELL"),
        .init(command: .newTab, title: "New Tab…", menu: "Tabs", key: "t", modifierMask: 1048576, localizesKey: true, source: "M-1693", owner: "PALETTE"),
        .init(command: .item1, title: "Item 1", menu: "", key: "", modifierMask: nil, localizesKey: true, source: "M-1700", owner: "SHELL"),
        .init(command: .item2, title: "Item 2", menu: "", key: "", modifierMask: nil, localizesKey: true, source: "M-1704", owner: "SHELL"),
        .init(command: .item3, title: "Item 3", menu: "", key: "", modifierMask: nil, localizesKey: true, source: "M-1708", owner: "SHELL"),
        .init(command: .zoom, title: "Zoom", menu: "Window", key: "", modifierMask: nil, localizesKey: true, source: "M-1726", owner: "SHELL"),
        .init(command: .bringAllToFront, title: "Bring All to Front", menu: "Window", key: "", modifierMask: nil, localizesKey: true, source: "M-1732", owner: "SHELL"),
        .init(command: .signOut, title: "Sign Out", menu: "Orbit", key: "", modifierMask: nil, localizesKey: true, source: "M-1753", owner: "SHELL"),
        .init(command: .correctSpellingAutomatically, title: "Correct Spelling Automatically", menu: "Spelling", key: "", modifierMask: nil, localizesKey: true, source: "M-1769", owner: "EDITING"),
        .init(command: .smartCopyPaste, title: "Smart Copy/Paste", menu: "Substitutions", key: "", modifierMask: nil, localizesKey: true, source: "M-1789", owner: "EDITING"),
        .init(command: .underline, title: "Underline", menu: "Font", key: "u", modifierMask: 1048576, localizesKey: true, source: "M-1797", owner: "EDITING"),
        .init(command: .textReplacement, title: "Text Replacement", menu: "Substitutions", key: "", modifierMask: nil, localizesKey: true, source: "M-1815", owner: "EDITING"),
        .init(command: .bold, title: "Bold", menu: "Font", key: "b", modifierMask: 1048576, localizesKey: true, source: "M-1839", owner: "EDITING"),
        .init(command: .stopSpeaking, title: "Stop Speaking", menu: "Speech", key: "", modifierMask: nil, localizesKey: true, source: "M-1867", owner: "EDITING"),
        .init(command: .zoomOut, title: "Zoom Out", menu: "View", key: "-", modifierMask: 1179648, localizesKey: true, source: "M-1881", owner: "SHELL"),
        .init(command: .delete, title: "Delete", menu: "Edit", key: "", modifierMask: nil, localizesKey: true, source: "M-1885", owner: "EDITING"),
        .init(command: .capitalize, title: "Capitalize", menu: "Transformations", key: "", modifierMask: nil, localizesKey: true, source: "M-1910", owner: "EDITING"),
        .init(command: .startSpeaking, title: "Start Speaking", menu: "Speech", key: "", modifierMask: nil, localizesKey: true, source: "M-1947", owner: "EDITING"),
        .init(command: .smartLinks, title: "Smart Links", menu: "Substitutions", key: "", modifierMask: nil, localizesKey: true, source: "M-1974", owner: "EDITING"),
        .init(command: .makeLowerCase, title: "Make Lower Case", menu: "Transformations", key: "", modifierMask: nil, localizesKey: true, source: "M-1980", owner: "EDITING"),
        .init(command: .undo, title: "Undo", menu: "Edit", key: "z", modifierMask: 1048576, localizesKey: true, source: "M-1992", owner: "SHELL"),
        .init(command: .smartQuotes, title: "Smart Quotes", menu: "Substitutions", key: "", modifierMask: nil, localizesKey: true, source: "M-2017", owner: "EDITING"),
        .init(command: .checkDocumentNow, title: "Check Document Now", menu: "Spelling", key: ";", modifierMask: 1048576, localizesKey: true, source: "M-2023", owner: "EDITING"),
        .init(command: .allowJavaScriptFromAppleEvents, title: "Allow JavaScript from Apple Events", menu: "Developer", key: "", modifierMask: nil, localizesKey: true, source: "M-2038", owner: "ENGINE/SHELL"),
        .init(command: .checkGrammarWithSpelling, title: "Check Grammar With Spelling", menu: "Spelling", key: "", modifierMask: nil, localizesKey: true, source: "M-2044", owner: "EDITING"),
        .init(command: .zoomIn, title: "Zoom In", menu: "View", key: "=", modifierMask: 1048576, localizesKey: true, source: "M-2070", owner: "SHELL"),
        .init(command: .zoomIn, title: "Zoom In", menu: "View", key: "=", modifierMask: 1048576, localizesKey: true, source: "M-2083", owner: "SHELL"),
        .init(command: .checkSpellingWhileTyping, title: "Check Spelling While Typing", menu: "Spelling", key: "", modifierMask: nil, localizesKey: true, source: "M-2087", owner: "EDITING"),
        .init(command: .smartDashes, title: "Smart Dashes", menu: "Substitutions", key: "", modifierMask: nil, localizesKey: true, source: "M-2093", owner: "EDITING"),
        .init(command: .dataDetectors, title: "Data Detectors", menu: "Substitutions", key: "", modifierMask: nil, localizesKey: true, source: "M-2109", owner: "EDITING"),
        .init(command: .makeUpperCase, title: "Make Upper Case", menu: "Transformations", key: "", modifierMask: nil, localizesKey: true, source: "M-2127", owner: "EDITING"),
        .init(command: .italic, title: "Italic", menu: "Font", key: "i", modifierMask: 1048576, localizesKey: true, source: "M-2139", owner: "EDITING"),
        .init(command: .showSubstitutions, title: "Show Substitutions", menu: "Substitutions", key: "", modifierMask: nil, localizesKey: true, source: "M-2151", owner: "EDITING"),
        .init(command: .services, title: "Services", menu: "Orbit", key: "", modifierMask: nil, localizesKey: true, source: "M-2177", owner: "SHELL"),
        .init(command: .find, title: "Find", menu: "Edit", key: "", modifierMask: nil, localizesKey: true, source: "M-2212", owner: "SHELL"),
        .init(command: .spellingAndGrammar, title: "Spelling and Grammar", menu: "Edit", key: "", modifierMask: nil, localizesKey: true, source: "M-2220", owner: "EDITING"),
        .init(command: .substitutions, title: "Substitutions", menu: "Edit", key: "", modifierMask: nil, localizesKey: true, source: "M-2230", owner: "EDITING"),
        .init(command: .transformations, title: "Transformations", menu: "Edit", key: "", modifierMask: nil, localizesKey: true, source: "M-2239", owner: "EDITING"),
        .init(command: .speech, title: "Speech", menu: "Edit", key: "", modifierMask: nil, localizesKey: true, source: "M-2247", owner: "EDITING"),
        .init(command: .format, title: "Format", menu: "Edit", key: "", modifierMask: nil, localizesKey: true, source: "M-2255", owner: "EDITING"),
        .init(command: .font, title: "Font", menu: "Format", key: "", modifierMask: nil, localizesKey: true, source: "M-2263", owner: "EDITING"),
        .init(command: .appearance, title: "Appearance", menu: "View", key: "", modifierMask: nil, localizesKey: true, source: "M-2280", owner: "THEME"),
        .init(command: .websitesEaselsAndNotesWillUse, title: "Websites, Easels, and Notes will use:", menu: "", key: "", modifierMask: nil, localizesKey: true, source: "M-2286", owner: "LIBRARY"),
        .init(command: .developer, title: "Developer", menu: "View", key: "", modifierMask: 1048576, localizesKey: true, source: "M-2296", owner: "SHELL"),
    ]

    static let supplemental: [BrowserCommandDefinition] = [
        .init(id: .selectTab1, title: "Select Tab 1", menu: "Tabs", shortcuts: [.init(key: "1", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["O22; archived official notes"]),
        .init(id: .selectSpace1, title: "Select Space 1", menu: "Tabs", shortcuts: [.init(key: "1", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["I-LEGACY; archived requirement"]),
        .init(id: .selectTab2, title: "Select Tab 2", menu: "Tabs", shortcuts: [.init(key: "2", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["O22; archived official notes"]),
        .init(id: .selectSpace2, title: "Select Space 2", menu: "Tabs", shortcuts: [.init(key: "2", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["I-LEGACY; archived requirement"]),
        .init(id: .selectTab3, title: "Select Tab 3", menu: "Tabs", shortcuts: [.init(key: "3", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["O22; archived official notes"]),
        .init(id: .selectSpace3, title: "Select Space 3", menu: "Tabs", shortcuts: [.init(key: "3", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["I-LEGACY; archived requirement"]),
        .init(id: .selectTab4, title: "Select Tab 4", menu: "Tabs", shortcuts: [.init(key: "4", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["O22; archived official notes"]),
        .init(id: .selectSpace4, title: "Select Space 4", menu: "Tabs", shortcuts: [.init(key: "4", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["I-LEGACY; archived requirement"]),
        .init(id: .selectTab5, title: "Select Tab 5", menu: "Tabs", shortcuts: [.init(key: "5", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["O22; archived official notes"]),
        .init(id: .selectSpace5, title: "Select Space 5", menu: "Tabs", shortcuts: [.init(key: "5", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["I-LEGACY; archived requirement"]),
        .init(id: .selectTab6, title: "Select Tab 6", menu: "Tabs", shortcuts: [.init(key: "6", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["O22; archived official notes"]),
        .init(id: .selectSpace6, title: "Select Space 6", menu: "Tabs", shortcuts: [.init(key: "6", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["I-LEGACY; archived requirement"]),
        .init(id: .selectTab7, title: "Select Tab 7", menu: "Tabs", shortcuts: [.init(key: "7", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["O22; archived official notes"]),
        .init(id: .selectSpace7, title: "Select Space 7", menu: "Tabs", shortcuts: [.init(key: "7", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["I-LEGACY; archived requirement"]),
        .init(id: .selectTab8, title: "Select Tab 8", menu: "Tabs", shortcuts: [.init(key: "8", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["O22; archived official notes"]),
        .init(id: .selectSpace8, title: "Select Space 8", menu: "Tabs", shortcuts: [.init(key: "8", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["I-LEGACY; archived requirement"]),
        .init(id: .selectTab9, title: "Select Tab 9", menu: "Tabs", shortcuts: [.init(key: "9", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "ORG", sources: ["O22; archived official notes"]),
        .init(id: .selectSpace9, title: "Select Space 9", menu: "Tabs", shortcuts: [.init(key: "9", modifiers: .init(rawValue: 262144))], scope: .browser, requirement: .window, owner: "ORG", sources: ["I-LEGACY; archived requirement"]),
        .init(id: .closeSwitcherTab, title: "Close Selected Switcher Tab", menu: "Tabs", shortcuts: [.init(key: "w", modifiers: .init(rawValue: 262144))], scope: .switcher, requirement: .window, owner: "PALETTE", sources: ["O23; archived official notes"]),
        .init(id: .promoteQuickWindow, title: "Open Little Orbit in Last Space", menu: "Tabs", shortcuts: [.init(key: "o", modifiers: .init(rawValue: 1048576))], scope: .quickWindow, requirement: .window, owner: "LITTLE", sources: ["O21; archived official notes"]),
        .init(id: .chooseQuickWindowSpace, title: "Open Little Orbit in Space…", menu: "Tabs", shortcuts: [.init(key: "o", modifiers: .init(rawValue: 1179648))], scope: .quickWindow, requirement: .window, owner: "LITTLE", sources: ["O22; archived official notes"]),
        .init(id: .dismissPeek, title: "Close Peek", menu: "Tabs", shortcuts: [.init(key: "\u{1b}", modifiers: .init(rawValue: 0))], scope: .peek, requirement: .window, owner: "PEEK", sources: ["I-LEGACY; archived requirement"]),
        .init(id: .cycleExtensions, title: "Cycle Pinned Extensions", menu: "Tabs", shortcuts: [.init(key: "e", modifiers: .init(rawValue: 1048576))], scope: .browser, requirement: .window, owner: "EXTENSIONS", sources: ["O22/O23; archived official notes"]),
        .init(id: .removeSuggestion, title: "Remove Suggestion", menu: "Tabs", shortcuts: [.init(key: "\u{7f}", modifiers: .init(rawValue: 1572864))], scope: .palette, requirement: .window, owner: "PALETTE", sources: ["O23; archived official notes"]),
        .init(id: .pasteAsNewTab, title: "Paste as New Tab", menu: "Tabs", shortcuts: [.init(key: "v", modifiers: .init(rawValue: 1572864))], scope: .browser, requirement: .window, owner: "PALETTE", sources: ["O23; archived official notes"]),
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
