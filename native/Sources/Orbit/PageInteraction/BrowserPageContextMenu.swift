import AppKit
import BrowserEngine

/// Page context menu (CH-ESSENTIALS): Chromium's menu, reconstructed in AppKit from the engine's
/// `BrowserContextMenuRequest`, with Chromium's labels as packaged in (the engine framework
/// `locale.pak`, including Orbit's "Open Link in Split View"). Items are registry commands (menu
/// "Page Context", never in the menu bar or the palette) dispatched with a target captured when the
/// menu opens; page commands go back to the engine for the same document only.
/// Not offered: Open Link in New Window and Incognito, profiles, Save As (CORE-SAVE-PAGE deferred),
/// translate, cast, QR code, Copy Link to Highlight, Search Image. No Peek item: no Orbit evidence.
enum BrowserPageContextMenuModel {
    struct Item: Equatable {
        let command: BrowserCommandID
        /// Replaces the definition's title (words, quoted selection).
        var title: String? = nil
        var isChecked = false
        var isEnabled = true
    }

    struct Context: Equatable {
        var canGoBack = false
        var canGoForward = false
        var canPrint = false
        var canInspect = false
        var searchEngineName = "Google"
    }

    /// Chromium's grouping and order (RenderViewContextMenu::InitMenu, macOS additions).
    static func groups(for request: BrowserContextMenuRequest, context: Context) -> [[Item]] {
        let available = request.availableCommands
        func engine(_ command: BrowserCommandID, _ kind: BrowserContextMenuCommand.Kind, title: String? = nil,
                    checked: Bool = false) -> Item? {
            available.contains(kind) ? Item(command: command, title: title, isChecked: checked) : nil
        }
        var groups: [[Item]] = []
        let selection = request.selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = selection.count > 50 ? String(selection.prefix(50)) + "…" : selection

        if request.isEditable, request.misspelledWord != nil {
            let suggestions = request.spellingSuggestions.prefix(5).enumerated().compactMap { index, word in
                available.contains(.replaceMisspelling) ? Item(command: spellingCommands[index], title: word) : nil
            }
            if !suggestions.isEmpty { groups.append(suggestions) }
            if let add = engine(.pageAddToDictionary, .addToDictionary) { groups.append([add]) }
        }

        if let link = request.linkURL {
            var open: [Item] = [Item(command: .pageOpenLinkInNewTab)]
            if ["http", "https"].contains(link.scheme?.lowercased() ?? "") { open.append(Item(command: .pageOpenLinkInSplitView)) }
            groups.append(open)
            var save: [Item] = []
            if let item = engine(.pageSaveLinkAs, .saveLink) { save.append(item) }
            save.append(link.scheme?.lowercased() == "mailto" ? Item(command: .pageCopyEmailAddress) : Item(command: .pageCopyLinkAddress))
            groups.append(save)
        }

        switch request.mediaKind {
        case .image where request.sourceURL != nil || request.hasImageContents:
            var items: [Item] = []
            if request.sourceURL != nil { items.append(Item(command: .pageOpenImageInNewTab)) }
            if let item = engine(.pageSaveImageAs, .saveImage) { items.append(item) }
            if let item = engine(.pageCopyImage, .copyImage) { items.append(item) }
            if request.sourceURL != nil { items.append(Item(command: .pageCopyImageAddress)) }
            if !items.isEmpty { groups.append(items) }
        case .video, .audio:
            let video = request.mediaKind == .video
            var controls: [Item] = []
            if let item = engine(.pageMediaLoop, .mediaLoop, checked: request.mediaState.contains(.loop)) { controls.append(item) }
            if let item = engine(.pageMediaShowControls, .mediaControls, checked: request.mediaState.contains(.controlsVisible)) {
                controls.append(item)
            }
            if video, let item = engine(.pageMediaPictureInPicture, .mediaPictureInPicture) { controls.append(item) }
            if !controls.isEmpty { groups.append(controls) }
            var items: [Item] = []
            if request.sourceURL != nil {
                items.append(Item(command: .pageOpenMediaInNewTab,
                                  title: uiText(video ? "Open Video in New Tab" : "Open Audio in New Tab")))
            }
            if let item = engine(.pageSaveMediaAs, .saveMedia, title: uiText(video ? "Save Video As…" : "Save Audio As…")) {
                items.append(item)
            }
            if request.sourceURL != nil {
                items.append(Item(command: .pageCopyMediaAddress,
                                  title: uiText(video ? "Copy Video Address" : "Copy Audio Address")))
            }
            if !items.isEmpty { groups.append(items) }
        default:
            break
        }

        if !selection.isEmpty, !request.isEditable {
            if let item = engine(.pageLookUp, .lookUp, title: uiFormat("Look Up “%@”", quoted)) { groups.append([item]) }
            var items: [Item] = []
            if let item = engine(.pageCopy, .copy) { items.append(item) }
            items.append(Item(command: .pageSearchSelection,
                              title: uiFormat("Search %@ for “%@”", context.searchEngineName, quoted)))
            groups.append(items)
        }

        if request.isEditable {
            if !selection.isEmpty, let item = engine(.pageLookUp, .lookUp, title: uiFormat("Look Up “%@”", quoted)) {
                groups.append([item])
            }
            groups.append([Item(command: .pageEmojiAndSymbols)])
            let flags = request.editFlags
            let history = [engine(.pageUndo, .undo).map { item in var copy = item; copy.isEnabled = flags.contains(.canUndo); return copy },
                           engine(.pageRedo, .redo).map { item in var copy = item; copy.isEnabled = flags.contains(.canRedo); return copy }]
                .compactMap { $0 }
            if !history.isEmpty { groups.append(history) }
            let pairs: [(BrowserCommandID, BrowserContextMenuCommand.Kind, BrowserContextMenuRequest.EditFlags)] = [
                (.pageCut, .cut, .canCut), (.pageCopy, .copy, .canCopy), (.pagePaste, .paste, .canPaste),
                (.pagePasteAndMatchStyle, .pasteAndMatchStyle, .canPaste), (.pageSelectAll, .selectAll, .canSelectAll)]
            let edit = pairs.compactMap { command, kind, flag -> Item? in
                guard var item = engine(command, kind) else { return nil }
                item.isEnabled = flags.contains(flag)
                return item
            }
            if !edit.isEmpty { groups.append(edit) }
        }

        let isPage = request.linkURL == nil && request.mediaKind == .none && selection.isEmpty && !request.isEditable
        if isPage {
            groups.append([Item(command: .pageBack, isEnabled: context.canGoBack),
                           Item(command: .pageForward, isEnabled: context.canGoForward),
                           Item(command: .pageReload)])
            if request.pageURL != nil { groups.append([Item(command: .pageShare)]) }
            var page: [Item] = []
            if context.canPrint { page.append(Item(command: .pagePrint)) }
            if request.pageURL.map(BrowserPageContextCommands.canViewSource) == true { page.append(Item(command: .pageViewSource)) }
            if !page.isEmpty { groups.append(page) }
        }
        if context.canInspect, available.contains(.inspect) { groups.append([Item(command: .pageInspect)]) }
        return groups.filter { !$0.isEmpty }
    }

    static let spellingCommands: [BrowserCommandID] = [
        .pageSpellingSuggestion0, .pageSpellingSuggestion1, .pageSpellingSuggestion2,
        .pageSpellingSuggestion3, .pageSpellingSuggestion4
    ]
}

/// The open page context menu of a window: the document it belongs to and the request it shows.
/// Commands of the menu act on this document only, never on a newer selection.
@MainActor
final class BrowserPageInteractionState {
    struct Menu {
        weak var surface: AnyObject?
        let surfaceKey: ObjectIdentifier
        let request: BrowserContextMenuRequest
        /// Retains the registry menu controller while AppKit shows its items.
        var owner: AnyObject?
        /// A page command reached the engine (it then releases the native menu itself).
        var deliveredEngineCommand = false
    }

    struct Fullscreen {
        let surfaceKey: ObjectIdentifier
        let enteredNativeFullScreen: Bool
        let sidebarWasVisible: Bool
        /// The window leaving native fullscreen by itself (green button, ⌃⌘F) ends element fullscreen.
        var windowObserver: NSObjectProtocol?
    }

    var menu: Menu?
    var fullscreen: Fullscreen?
    /// Surfaces whose unresponsive question is shown.
    var unresponsive: Set<ObjectIdentifier> = []
    /// Hidden smoke and tests: observes menus instead of showing them (never set by the product).
    var menuObserver: ((BrowserContextMenuRequest, [[BrowserPageContextMenuModel.Item]]) -> Void)?
}

/// Registry definitions and handlers of the page context menu and of the page commands of the menu
/// bar (Print ⌘P, Developer Tools ⌥⌘I, Inspect Elements ⌥⌘C, View Source ⌥⌘U).
enum BrowserPageContextCommands {
    static let menu = "Page Context"

    private static func page(_ id: BrowserCommandID, _ title: String) -> BrowserCommandDefinition {
        .init(id: id, title: title, menu: menu, shortcuts: [], scope: .browser, requirement: .window, owner: "CH-ESSENTIALS",
              sources: ["Page context command"])
    }

    static let definitions: [BrowserCommandDefinition] = [
        page(.pageShare, "Share…"),
        page(.pageOpenLinkInNewTab, "Open Link in New Tab"),
        page(.pageOpenLinkInSplitView, "Open Link in Split View"),
        page(.pageSaveLinkAs, "Save Link As…"),
        page(.pageCopyLinkAddress, "Copy Link Address"),
        page(.pageCopyEmailAddress, "Copy Email Address"),
        page(.pageOpenImageInNewTab, "Open Image in New Tab"),
        page(.pageSaveImageAs, "Save Image As…"),
        page(.pageCopyImage, "Copy Image"),
        page(.pageCopyImageAddress, "Copy Image Address"),
        page(.pageOpenMediaInNewTab, "Open Video in New Tab"),
        page(.pageSaveMediaAs, "Save Video As…"),
        page(.pageCopyMediaAddress, "Copy Video Address"),
        page(.pageMediaLoop, "Loop"),
        page(.pageMediaShowControls, "Show All Controls"),
        page(.pageMediaPictureInPicture, "Picture in Picture"),
        page(.pageLookUp, "Look Up"),
        page(.pageSearchSelection, "Search"),
        page(.pageSpellingSuggestion0, "Spelling Suggestion"),
        page(.pageSpellingSuggestion1, "Spelling Suggestion"),
        page(.pageSpellingSuggestion2, "Spelling Suggestion"),
        page(.pageSpellingSuggestion3, "Spelling Suggestion"),
        page(.pageSpellingSuggestion4, "Spelling Suggestion"),
        page(.pageAddToDictionary, "Add to Dictionary"),
        page(.pageEmojiAndSymbols, "Emoji & Symbols"),
        page(.pageUndo, "Undo"),
        page(.pageRedo, "Redo"),
        page(.pageCut, "Cut"),
        page(.pageCopy, "Copy"),
        page(.pagePaste, "Paste"),
        page(.pagePasteAndMatchStyle, "Paste and Match Style"),
        page(.pageSelectAll, "Select All"),
        page(.pageBack, "Back"),
        page(.pageForward, "Forward"),
        page(.pageReload, "Reload"),
        page(.pagePrint, "Print…"),
        page(.pageViewSource, "View Page Source"),
        page(.pageInspect, "Inspect")
    ]

    /// Engine page command of a registry command, with the request's suggestions for spelling.
    static func engineCommand(for id: BrowserCommandID, request: BrowserContextMenuRequest) -> BrowserContextMenuCommand? {
        if let index = BrowserPageContextMenuModel.spellingCommands.firstIndex(of: id) {
            guard index < request.spellingSuggestions.count else { return nil }
            return .replaceMisspelling(request.spellingSuggestions[index])
        }
        switch id {
        case .pageSaveLinkAs: return .saveLink
        case .pageSaveImageAs: return .saveImage
        case .pageCopyImage: return .copyImage
        case .pageSaveMediaAs: return .saveMedia
        case .pageMediaLoop: return .mediaLoop
        case .pageMediaShowControls: return .mediaControls
        case .pageMediaPictureInPicture: return .mediaPictureInPicture
        case .pageLookUp: return .lookUp
        case .pageAddToDictionary: return request.misspelledWord.map { .addToDictionary($0) }
        case .pageUndo: return .undo
        case .pageRedo: return .redo
        case .pageCut: return .cut
        case .pageCopy: return .copy
        case .pagePaste: return .paste
        case .pagePasteAndMatchStyle: return .pasteAndMatchStyle
        case .pageSelectAll: return .selectAll
        case .pageInspect: return .inspect
        default: return nil
        }
    }

    /// `view-source:` documents exist for web pages only (Chromium engine).
    static func canViewSource(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    static func viewSourceURL(for url: URL) -> URL? {
        canViewSource(url) ? URL(string: "view-source:" + url.absoluteString) : nil
    }

    @MainActor
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        for definition in definitions {
            try! registry.register(definition.id, validate: { $0.pageInteraction.menu != nil }) { controller, _ in
                controller.performPageContextCommand(definition.id)
            }
        }
        // Menu bar page commands of Orbit's catalog (M-901, M-285/M-1473, M-1380, M-655).
        try! registry.register(.print, validate: { $0.canPerformPageCommand(.print) }) { controller, _ in
            controller.performPageCommand(.print)
        }
        try! registry.register(.developerTools, validate: { $0.canPerformPageCommand(.showDevTools) }) { controller, _ in
            controller.performPageCommand(.showDevTools)
        }
        try! registry.register(.inspectElements, validate: { $0.canPerformPageCommand(.inspectElements) }) { controller, _ in
            controller.performPageCommand(.inspectElements)
        }
        try! registry.register(.viewSource, validate: { $0.canViewPageSource }) { controller, _ in
            controller.viewPageSource()
        }
    }
}

/// The page menu of a Little Orbit window (no command registry of its own there): the same model and
/// labels, performed through a closure for the captured document.
@MainActor
final class BrowserQuickWindowPageMenu: NSObject {
    private let groups: [[BrowserPageContextMenuModel.Item]]
    private let perform: (BrowserCommandID) -> Bool
    private var delivered = false
    var extensionItems: [BrowserExtensionMenuItem] = []
    var performExtension: ((Int32) -> Bool)?

    init(groups: [[BrowserPageContextMenuModel.Item]], perform: @escaping (BrowserCommandID) -> Bool) {
        self.groups = groups
        self.perform = perform
    }

    /// Shows the menu at `location` (top-left origin) and returns whether a page command reached the
    /// engine.
    func popUp(at location: CGPoint, in view: NSView) -> Bool {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let titles = Dictionary(uniqueKeysWithValues: BrowserPageContextCommands.definitions.map { ($0.id, $0.localizedTitle) })
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for item in group {
                let menuItem = NSMenuItem(title: item.title ?? titles[item.command] ?? item.command.rawValue,
                                          action: #selector(choose(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = item.command.rawValue
                menuItem.state = item.isChecked ? .on : .off
                menuItem.isEnabled = item.isEnabled
                menu.addItem(menuItem)
            }
        }
        let point = NSPoint(x: location.x, y: view.isFlipped ? location.y : view.bounds.height - location.y)
        let extensions = BrowserExtensionContextMenu { [weak self] id in
            guard let self else { return }
            delivered = (performExtension?(id) ?? false) || delivered
        }
        extensions.append(extensionItems, to: menu)
        withExtendedLifetime(extensions) { menu.popUp(positioning: nil, at: point, in: view) }
        return delivered
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = BrowserCommandID(rawValue: raw) else { return }
        delivered = perform(id) || delivered
    }
}
