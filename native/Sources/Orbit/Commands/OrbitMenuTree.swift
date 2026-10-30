// Declarative menu order, presentation flags and key equivalents.

struct OrbitMenuItemSpec: Sendable {
    let command: BrowserCommandID
    let title: String
    var key = ""
    var modifierMask: UInt = 0
    var isHidden = false
    var isAlternate = false
    var allowsKeyEquivalentWhenHidden = false
    var isOn = false
    var tag = 0
}

struct OrbitSubmenuSpec: Sendable {
    let command: BrowserCommandID?
    let title: String
    /// The NSMenu's own title, which may differ from its item (Spelling, untitled Appearance).
    let menuTitle: String
    var systemName: String?
    var isHidden = false
    let children: [OrbitMenuNode]
}

enum OrbitMenuNode: Sendable {
    case item(OrbitMenuItemSpec)
    case separator
    /// A title row with no action or shortcut (AppKit auto-disables it).
    case header(command: BrowserCommandID, title: String)
    case submenu(OrbitSubmenuSpec)
}

enum OrbitMenuTree {
    static let allowsKeyEquivalentLocalization = true
    static let allowsKeyEquivalentMirroring = true
    static let bar: [OrbitMenuNode] = [
        .submenu(.init(command: nil, title: "Circa", menuTitle: "Circa", systemName: "_NSAppleMenu", children: [
            .item(.init(command: .aboutOrbit, title: "About Circa")),
            .separator,
            .item(.init(command: .preferences, title: "Preferences…", key: ",", modifierMask: 1048576)),
            .item(.init(command: .shareOrbit, title: "Share Circa")),
            .item(.init(command: .setAsDefaultBrowser, title: "Set as Default Browser")),
            .separator,
            .item(.init(command: .importFromAnotherBrowser, title: "Import from Another Browser…")),
            .item(.init(command: .checkForUpdates, title: "Check for Updates…")),
            .separator,
            .submenu(.init(command: .services, title: "Services", menuTitle: "Services", systemName: "_NSServicesMenu", children: [])),
            .item(.init(command: .privacyPolicy, title: "Privacy Policy")),
            .separator,
            .item(.init(command: .hideOrbit, title: "Hide Circa", key: "h", modifierMask: 1048576)),
            .item(.init(command: .hideOtherWindows, title: "Hide Other Windows", key: "h", modifierMask: 1572864)),
            .item(.init(command: .showAll, title: "Show All")),
            .separator,
            .item(.init(command: .signOut, title: "Sign Out")),
            .separator,
            .item(.init(command: .quitOrbit, title: "Quit Circa", key: "q", modifierMask: 1048576)),
        ])),
        .submenu(.init(command: nil, title: "File", menuTitle: "File", children: [
            .item(.init(command: .newTab, title: "New Tab…", key: "t", modifierMask: 1048576)),
            .item(.init(command: .newWindow, title: "New Window", key: "n", modifierMask: 1048576)),
            .item(.init(command: .blankWindow, title: "Blank Window", key: "n", modifierMask: 1310720)),
            .item(.init(command: .newIncognitoWindow, title: "New Incognito Window", key: "N", modifierMask: 1048576)),
            .item(.init(command: .newQuickWindowWindow, title: "New Little Circa Window", key: "n", modifierMask: 1572864)),
            .item(.init(command: .restoreLastClosedTab, title: "Restore Last Closed Tab", key: "T", modifierMask: 1048576)),
            .separator,
            .item(.init(command: .openFile, title: "Open File…")),
            .item(.init(command: .openCommandBar, title: "Open Command Bar", key: "l", modifierMask: 1048576)),
            .separator,
            .item(.init(command: .newBoost, title: "New Boost", isHidden: true)),
            .item(.init(command: .editBoost, title: "Edit Boost", isHidden: true)),
            .item(.init(command: .newLegacyBoostAdvanced, title: "New Legacy Boost (Advanced)", isHidden: true)),
            .item(.init(command: .boostGallery, title: "Boost Gallery", isHidden: true)),
            .item(.init(command: .newProfile, title: "New Profile")),
            .item(.init(command: .newNote, title: "New Note", key: "N", modifierMask: 262144)),
            .item(.init(command: .newNoteInSplit, title: "New Note (in Split)", key: "n", modifierMask: 786432, isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .newEasel, title: "New Easel", key: "E", modifierMask: 262144)),
            .separator,
            .item(.init(command: .closeWindow, title: "Close Window", key: "W", modifierMask: 1048576)),
            .item(.init(command: .archiveTab, title: "Archive Tab", key: "w", modifierMask: 1048576, allowsKeyEquivalentWhenHidden: true)),
            .separator,
            .item(.init(command: .share, title: "Share…")),
            .item(.init(command: .sendToDia, title: "Send to Dia")),
            .item(.init(command: .capture, title: "Capture…", key: "2", modifierMask: 1179648)),
            .item(.init(command: .captureFullPage, title: "Capture Full Page")),
            .item(.init(command: .captureInPortraitMode, title: "Capture in Portrait Mode", allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .savePageAs, title: "Save Page As", key: "S", modifierMask: 1048576)),
            .item(.init(command: .print, title: "Print", key: "p", modifierMask: 1048576)),
        ])),
        .submenu(.init(command: nil, title: "Edit", menuTitle: "Edit", children: [
            .item(.init(command: .undo, title: "Undo", key: "z", modifierMask: 1048576)),
            .item(.init(command: .redo, title: "Redo", key: "Z", modifierMask: 1048576)),
            .separator,
            .item(.init(command: .cut, title: "Cut", key: "x", modifierMask: 1048576)),
            .item(.init(command: .copy, title: "Copy", key: "c", modifierMask: 1048576)),
            .item(.init(command: .copyURL, title: "Copy URL", key: "C", modifierMask: 1048576)),
            .item(.init(command: .copyURLAsMarkdown, title: "Copy URL as Markdown", key: "C", modifierMask: 1572864)),
            .item(.init(command: .copyURLAsQuote, title: "Copy URL as Quote", key: "C", modifierMask: 1310720)),
            .item(.init(command: .paste, title: "Paste", key: "v", modifierMask: 1048576)),
            .item(.init(command: .pasteAndMatchStyle, title: "Paste and Match Style", key: "V", modifierMask: 1048576)),
            .item(.init(command: .delete, title: "Delete")),
            .item(.init(command: .selectAll, title: "Select All", key: "a", modifierMask: 1048576)),
            .separator,
            .submenu(.init(command: .find, title: "Find", menuTitle: "Find", children: [
                .item(.init(command: .find, title: "Find…", key: "f", modifierMask: 1048576, tag: 1)),
                .item(.init(command: .findAndReplace, title: "Find and Replace", key: "f", modifierMask: 1572864, tag: 12)),
                .item(.init(command: .findNext, title: "Find Next", key: "g", modifierMask: 1048576, tag: 2)),
                .item(.init(command: .findPrevious, title: "Find Previous", key: "G", modifierMask: 1048576, tag: 3)),
                .item(.init(command: .useSelectionToFind, title: "Use Selection to Find", tag: 7)),
                .item(.init(command: .jumpToSelection, title: "Jump to Selection", key: "j", modifierMask: 1048576)),
            ])),
            .submenu(.init(command: .spellingAndGrammar, title: "Spelling and Grammar", menuTitle: "Spelling", children: [
                .item(.init(command: .showSpellingAndGrammar, title: "Show Spelling and Grammar", key: ":", modifierMask: 1048576)),
                .item(.init(command: .checkDocumentNow, title: "Check Document Now", key: ";", modifierMask: 1048576)),
                .separator,
                .item(.init(command: .checkSpellingWhileTyping, title: "Check Spelling While Typing")),
                .item(.init(command: .checkGrammarWithSpelling, title: "Check Grammar With Spelling")),
                .item(.init(command: .correctSpellingAutomatically, title: "Correct Spelling Automatically")),
            ])),
            .submenu(.init(command: .substitutions, title: "Substitutions", menuTitle: "Substitutions", children: [
                .item(.init(command: .showSubstitutions, title: "Show Substitutions")),
                .separator,
                .item(.init(command: .smartCopyPaste, title: "Smart Copy/Paste")),
                .item(.init(command: .smartQuotes, title: "Smart Quotes")),
                .item(.init(command: .smartDashes, title: "Smart Dashes")),
                .item(.init(command: .smartLinks, title: "Smart Links")),
                .item(.init(command: .dataDetectors, title: "Data Detectors")),
                .item(.init(command: .textReplacement, title: "Text Replacement")),
            ])),
            .submenu(.init(command: .transformations, title: "Transformations", menuTitle: "Transformations", children: [
                .item(.init(command: .makeUpperCase, title: "Make Upper Case")),
                .item(.init(command: .makeLowerCase, title: "Make Lower Case")),
                .item(.init(command: .capitalize, title: "Capitalize")),
            ])),
            .submenu(.init(command: .speech, title: "Speech", menuTitle: "Speech", children: [
                .item(.init(command: .startSpeaking, title: "Start Speaking")),
                .item(.init(command: .stopSpeaking, title: "Stop Speaking")),
            ])),
            .submenu(.init(command: .format, title: "Format", menuTitle: "Format", children: [
                .submenu(.init(command: .font, title: "Font", menuTitle: "Font", systemName: "_NSFontMenu", children: [
                    .item(.init(command: .bold, title: "Bold", key: "b", modifierMask: 1048576, tag: 2)),
                    .item(.init(command: .italic, title: "Italic", key: "i", modifierMask: 1048576, tag: 1)),
                    .item(.init(command: .underline, title: "Underline", key: "u", modifierMask: 1048576)),
                ])),
            ])),
        ])),
        .submenu(.init(command: nil, title: "View", menuTitle: "View", children: [
            .submenu(.init(command: .appearance, title: "Appearance", menuTitle: "", children: [
                .header(command: .websitesEaselsAndNotesWillUse, title: "Websites, Easels, and Notes will use:"),
                .item(.init(command: .automatic, title: "Automatic", isOn: true)),
                .item(.init(command: .light, title: "Light")),
                .item(.init(command: .dark, title: "Dark")),
            ])),
            .separator,
            .item(.init(command: .showHideSidebar, title: "Show/Hide Sidebar", key: "s", modifierMask: 1048576)),
            .item(.init(command: .showHideToolbar, title: "Show/Hide Toolbar", key: "D", modifierMask: 1048576, isHidden: true)),
            .item(.init(command: .expandPinnedSection, title: "Expand Pinned Section", isHidden: true)),
            .item(.init(command: .collapsePinnedSection, title: "Collapse Pinned Section", isHidden: true)),
            .item(.init(command: .revealCurrentTab, title: "Reveal Current Tab", key: " ", modifierMask: 262144, isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .separator,
            .item(.init(command: .stopLoading, title: "Stop Loading", key: ".", modifierMask: 1048576)),
            .item(.init(command: .refreshThePage, title: "Refresh the Page", key: "r", modifierMask: 1048576)),
            .item(.init(command: .forceRefreshThePage, title: "Force Refresh the Page", key: "R", modifierMask: 1048576, isAlternate: true)),
            .item(.init(command: .clearCookiesAndRefresh, title: "Clear Cookies and Refresh")),
            .item(.init(command: .clearCacheAndRefresh, title: "Clear Cache and Refresh")),
            .separator,
            .item(.init(command: .addSplitView, title: "Add Split View", key: "=", modifierMask: 393216)),
            .item(.init(command: .closeThisSplitPane, title: "Close this Split Pane", key: "-", modifierMask: 393216)),
            .item(.init(command: .separatePageFromSplitView, title: "Separate Page from Split View")),
            .item(.init(command: .expandCurrentSplit, title: "Expand Current Split")),
            .separator,
            .item(.init(command: .zoomToActualSize, title: "Zoom to Actual Size", key: "0", modifierMask: 1048576)),
            .item(.init(command: .zoomIn, title: "Zoom In", key: "+", modifierMask: 1048576)),
            .item(.init(command: .zoomIn, title: "Zoom In", key: "=", modifierMask: 1048576, isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .zoomIn, title: "Zoom In", key: "=", modifierMask: 1048576, isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .zoomOut, title: "Zoom Out", key: "-", modifierMask: 1048576, allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .zoomOut, title: "Zoom Out", key: "-", modifierMask: 1179648, isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .separator,
            .item(.init(command: .cast, title: "Cast")),
            .separator,
            .submenu(.init(command: .developer, title: "Developer", menuTitle: "Developer", children: [
                .item(.init(command: .viewSource, title: "View Source", key: "u", modifierMask: 1572864)),
                .item(.init(command: .developerTools, title: "Developer Tools", key: "i", modifierMask: 1572864)),
                .item(.init(command: .developerTools, title: "Developer Tools", key: "\u{F70F}", isHidden: true, allowsKeyEquivalentWhenHidden: true)),
                .item(.init(command: .inspectElements, title: "Inspect Elements", key: "c", modifierMask: 1572864)),
                .item(.init(command: .javascriptConsole, title: "JavaScript Console", key: "j", modifierMask: 1572864)),
                .item(.init(command: .networkInspector, title: "Network Inspector")),
                .item(.init(command: .allowJavaScriptFromAppleEvents, title: "Allow JavaScript from Apple Events")),
                .item(.init(command: .toggleDeveloperMode, title: "Toggle Developer Mode", key: "d", modifierMask: 262144)),
            ])),
            .separator,
            .item(.init(command: .enterExitFullScreen, title: "Enter/Exit Full Screen", key: "f", modifierMask: 1310720)),
            .item(.init(command: .exit, title: "Exit", key: "\u{1B}", allowsKeyEquivalentWhenHidden: true)),
        ])),
        .submenu(.init(command: nil, title: "Spaces", menuTitle: "Spaces", children: [
            .item(.init(command: .newSpace, title: "New Space…")),
            .item(.init(command: .editTheme, title: "Edit Theme…")),
            .item(.init(command: .renameSpace, title: "Rename Space")),
            .item(.init(command: .changeProfile, title: "Change Profile")),
            .separator,
            .item(.init(command: .nextSpace, title: "Next Space", key: "\u{F703}", modifierMask: 1572864)),
            .item(.init(command: .previousSpace, title: "Previous Space", key: "\u{F702}", modifierMask: 1572864)),
            .separator,
            .item(.init(command: .manageSpaces, title: "Manage Spaces…")),
        ])),
        .submenu(.init(command: nil, title: "Tabs", menuTitle: "Tabs", children: [
            .item(.init(command: .newTab, title: "New Tab…", key: "t", modifierMask: 1048576)),
            .item(.init(command: .newChatGPTMessage, title: "New ChatGPT Message…", key: "g", modifierMask: 1572864, isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .joinMeeting, title: "Join Meeting", key: "j", modifierMask: 1310720, isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .peekEmail, title: "Peek Email…", key: "E", modifierMask: 1048576, isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .pinUnpinTab, title: "Pin/Unpin Tab", key: "d", modifierMask: 1048576)),
            .item(.init(command: .openQuickWindowOrPeekIn, title: "Open Little Circa or Peek in…", key: "o", modifierMask: 1048576, allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .newFolder, title: "New Folder…", key: "N", modifierMask: 1048576)),
            .item(.init(command: .duplicate, title: "Duplicate", isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .renameCurrentItem, title: "Rename Current Item", isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .collapseAllFolders, title: "Collapse All Folders", isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .expandAllFolders, title: "Expand All Folders", isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .separator,
            .item(.init(command: .nextTab, title: "Next Tab", key: "\u{F701}", modifierMask: 1572864)),
            .item(.init(command: .previousTab, title: "Previous Tab", key: "\u{F700}", modifierMask: 1572864)),
            .item(.init(command: .tabSwitcherForward, title: "Tab Switcher (forward)", key: "\u{9}", modifierMask: 262144, isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .tabSwitcherBackward, title: "Tab Switcher (backward)", key: "\u{19}", modifierMask: 393216, isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .cycleTabForward, title: "Cycle Tab Forward", key: "\u{F703}", modifierMask: 1310720, isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .cycleTabBackward, title: "Cycle Tab Backward", key: "\u{F702}", modifierMask: 1310720, isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .revealTabInSidebar, title: "Reveal Tab in Sidebar")),
            .separator,
            .item(.init(command: .clearUnpinnedTabs, title: "Clear Unpinned Tabs", key: "K", modifierMask: 1048576)),
            .item(.init(command: .resetAllTabsInThisSpace, title: "Reset all tabs in this Space")),
            .item(.init(command: .resetTabToOriginalURL, title: "Reset Tab to Original URL", isHidden: true, allowsKeyEquivalentWhenHidden: true)),
        ])),
        .submenu(.init(command: nil, title: "Archive", menuTitle: "Archive", children: [
            .item(.init(command: .goBack, title: "Go Back", key: "[", modifierMask: 1048576)),
            .item(.init(command: .goBack, title: "Go Back", key: "\u{F702}", modifierMask: 1048576, isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .item(.init(command: .goForward, title: "Go Forward", key: "]", modifierMask: 1048576)),
            .item(.init(command: .goForward, title: "Go Forward", key: "\u{F703}", modifierMask: 1048576, isHidden: true, allowsKeyEquivalentWhenHidden: true)),
            .separator,
            .item(.init(command: .viewHistory, title: "View History", key: "y", modifierMask: 1048576)),
            .item(.init(command: .viewArchive, title: "View Archive")),
            .item(.init(command: .clearArchive, title: "Clear Archive")),
        ])),
        .submenu(.init(command: nil, title: "Extensions", menuTitle: "Extensions", children: [
            .item(.init(command: .addExtension, title: "Add Extension…")),
            .item(.init(command: .manageExtensions, title: "Manage Extensions…")),
        ])),
        .submenu(.init(command: nil, title: "Window", menuTitle: "Window", systemName: "_NSWindowsMenu", children: [
            .item(.init(command: .minimizeWindow, title: "Minimize Window", key: "m", modifierMask: 1048576)),
            .item(.init(command: .zoom, title: "Zoom")),
            .separator,
            .item(.init(command: .viewLibrary, title: "View Library", key: "L", modifierMask: 1048576)),
            .item(.init(command: .viewDownloads, title: "View Downloads", key: "J", modifierMask: 1048576)),
            .item(.init(command: .viewEaselsNotes, title: "View Easels & Notes")),
            .item(.init(command: .viewMedia, title: "View Media")),
            .item(.init(command: .viewBoosts, title: "View Boosts", isHidden: true)),
            .separator,
            .item(.init(command: .bringAllToFront, title: "Bring All to Front")),
        ])),
        .submenu(.init(command: nil, title: "Help", menuTitle: "Help", systemName: "_NSHelpMenu", children: [
            .item(.init(command: .gettingStarted, title: "Getting Started")),
            .item(.init(command: .essentialKeyboardShortcuts, title: "Essential Keyboard Shortcuts")),
            .item(.init(command: .releaseNotes, title: "Release Notes")),
            .item(.init(command: .contactTheTeam, title: "Contact the Team")),
            .item(.init(command: .visitHelpCenter, title: "Circa Help")),
            .item(.init(command: .restoreData, title: "Restore Data")),
            .item(.init(command: .exportOrbitNotes, title: "Export Circa Notes")),
            .separator,
            .submenu(.init(command: .troubleshooting, title: "Troubleshooting", menuTitle: "Troubleshooting", children: [
                .item(.init(command: .recordTrace, title: "Record Trace")),
                .item(.init(command: .cancelTrace, title: "Cancel Trace", isHidden: true)),
                .item(.init(command: .openTaskManager, title: "Open Task Manager")),
                .separator,
                .item(.init(command: .revealOrbitData, title: "Reveal Circa Data")),
                .item(.init(command: .copyOrbitInfo, title: "Copy Circa Info")),
            ])),
        ])),
    ]
}
