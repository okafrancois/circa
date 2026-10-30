import AppKit

enum BrowserStandardActions {
    private static let responderSelectors: [BrowserCommandID: Selector] = [
        .undo: Selector(("undo:")), .redo: Selector(("redo:")),
        .cut: #selector(NSText.cut(_:)), .copy: #selector(NSText.copy(_:)), .paste: #selector(NSText.paste(_:)),
        .pasteAndMatchStyle: #selector(NSTextView.pasteAsPlainText(_:)), .delete: #selector(NSText.delete(_:)),
        .selectAll: #selector(NSText.selectAll(_:)),
        .jumpToSelection: #selector(NSResponder.centerSelectionInVisibleArea(_:)),
        .findAndReplace: #selector(NSTextView.performFindPanelAction(_:)),
        .useSelectionToFind: #selector(NSTextView.performFindPanelAction(_:)),
        .showSpellingAndGrammar: #selector(NSText.showGuessPanel(_:)), .checkDocumentNow: #selector(NSText.checkSpelling(_:)),
        .checkSpellingWhileTyping: #selector(NSTextView.toggleContinuousSpellChecking(_:)),
        .checkGrammarWithSpelling: #selector(NSTextView.toggleGrammarChecking(_:)),
        .correctSpellingAutomatically: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)),
        .showSubstitutions: #selector(NSTextView.orderFrontSubstitutionsPanel(_:)),
        .smartCopyPaste: #selector(NSTextView.toggleSmartInsertDelete(_:)),
        .smartQuotes: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)),
        .smartDashes: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)),
        .smartLinks: #selector(NSTextView.toggleAutomaticLinkDetection(_:)),
        .dataDetectors: #selector(NSTextView.toggleAutomaticDataDetection(_:)),
        .textReplacement: #selector(NSTextView.toggleAutomaticTextReplacement(_:)),
        .makeUpperCase: #selector(NSResponder.uppercaseWord(_:)), .makeLowerCase: #selector(NSResponder.lowercaseWord(_:)),
        .capitalize: #selector(NSResponder.capitalizeWord(_:)),
        .startSpeaking: #selector(NSTextView.startSpeaking(_:)), .stopSpeaking: #selector(NSTextView.stopSpeaking(_:)),
        .underline: #selector(NSText.underline(_:))
    ]

    /// Bold/Italic are font-manager trait toggles (NIB target NSFontManager, tags 2 and 1).
    private static let fontTraits: [BrowserCommandID: NSFontTraitMask] = [.bold: .boldFontMask, .italic: .italicFontMask]

    /// Actions implemented by the native responder chain, including their required sender tags.
    static let commandIDs = Set(responderSelectors.keys).union(fontTraits.keys)

    @MainActor
    static func sender(for id: BrowserCommandID) -> NSMenuItem? {
        guard let action = selector(for: id) else { return nil }
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.tag = tag(for: id)
        return item
    }

    /// Font traits are applied by the font manager to a validated changeFont: responder.
    static func validationSelector(for id: BrowserCommandID) -> Selector? {
        fontTraits[id] == nil ? selector(for: id) : #selector(NSTextView.changeFont(_:))
    }

    /// Window-level actions for a key window that is not a browser window (Settings, panels):
    /// they act on that window rather than on a background browser window's tab.
    private static let keyWindowSelectors: [BrowserCommandID: Selector] = [
        .closeWindow: #selector(NSWindow.performClose(_:)), .archiveTab: #selector(NSWindow.performClose(_:)),
        .minimizeWindow: #selector(NSWindow.performMiniaturize(_:)), .zoom: #selector(NSWindow.performZoom(_:)),
        .enterExitFullScreen: #selector(NSWindow.toggleFullScreen(_:))
    ]

    /// The nil-target (or font-manager) selector the menu item uses for `id`, if standard.
    static func selector(for id: BrowserCommandID) -> Selector? {
        if fontTraits[id] != nil { return #selector(NSFontManager.addFontTrait(_:)) }
        return responderSelectors[id]
    }

    /// Explicit target for a standard item; nil means the first responder.
    @MainActor
    static func target(for id: BrowserCommandID) -> AnyObject? { fontTraits[id] != nil ? NSFontManager.shared : nil }

    static func tag(for id: BrowserCommandID) -> Int {
        switch id {
        case .findAndReplace: return Int(NSTextFinder.Action.showReplaceInterface.rawValue)
        case .useSelectionToFind: return Int(NSFindPanelAction.setFindString.rawValue)
        default: return fontTraits[id].map { Int($0.rawValue) } ?? 0
        }
    }

    static func keyWindowSelector(for id: BrowserCommandID) -> Selector? { keyWindowSelectors[id] }
}
