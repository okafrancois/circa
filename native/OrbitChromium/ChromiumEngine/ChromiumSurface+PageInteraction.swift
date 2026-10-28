import AppKit
import OrbitChromiumBridge
import BrowserCore
import BrowserEngine
import Foundation

extension ChromiumSurface {
    // MARK: Events

    func receivePageEvent(_ event: ChromiumEvent) {
        switch event.kind {
        case ACR_EVENT_JS_DIALOG: runJavaScriptDialog(event)
        case ACR_EVENT_JS_DIALOG_RESET:
            // The bridge dropped them: their answers are no longer accepted.
            pendingDialogRequests.removeAll()
            onEngineEvent?("js-dialog-reset", [:])
            delegate?.surfaceDidResetJavaScriptDialogs(self)
        case ACR_EVENT_AUTH: requestCredentials(event)
        case ACR_EVENT_FILE_DIALOG: runFileChooser(event)
        case ACR_EVENT_CONTEXT_MENU: showContextMenu(event)
        case ACR_EVENT_FULLSCREEN:
            isElementFullscreen = event.value == 1
            onEngineEvent?("fullscreen", ["fullscreen": String(isElementFullscreen)])
            delegate?.surface(self, didChangeElementFullscreen: isElementFullscreen)
        case ACR_EVENT_UNRESPONSIVE:
            isRendererUnresponsive = event.value == 1
            onEngineEvent?("unresponsive", ["unresponsive": String(isRendererUnresponsive)])
            delegate?.surface(self, rendererDidBecomeUnresponsive: isRendererUnresponsive)
        case ACR_EVENT_CLOSE_CANCELED:
            onEngineEvent?("close-canceled", [:])
            _ = finishCloseConfirmation(closed: false)
        default:
            break
        }
    }

    /// A request event for a disposed surface is answered at once (never left pending in CEF).
    static func refuseUnanswered(_ event: ChromiumEvent) {
        switch event.kind {
        case ACR_EVENT_JS_DIALOG: _ = ACRResolveJSDialog(event.requestID, event.value == 3 ? 1 : 0, nil)
        case ACR_EVENT_AUTH: _ = ACRResolveAuth(event.requestID, nil, nil)
        case ACR_EVENT_FILE_DIALOG: _ = ACRResolveFileDialog(event.requestID, nil, 0)
        case ACR_EVENT_CONTEXT_MENU: _ = ACRResolveContextMenu(event.requestID, -1)
        case ACR_EVENT_UNRESPONSIVE where event.value == 1: _ = ACRResolveUnresponsive(event.surfaceToken, 0)
        default: break
        }
    }

    /// A new document: the previous one's menu and renderer state are obsolete.
    func documentDidCommitForPageSurfaces() {
        rendererTermination = nil
        isRendererUnresponsive = false
        if let menu = openContextMenu {
            openContextMenu = nil
            _ = ACRResolveContextMenu(menu.id, -1)
        }
    }

    /// Disposal: every open question is answered now; a late delegate answer is ignored.
    func releasePageRequests() {
        for request in pendingDialogRequests { _ = ACRResolveJSDialog(request, 0, nil) }
        pendingDialogRequests.removeAll()
        for request in pendingPageRequests {
            _ = ACRResolveAuth(request, nil, nil)
            _ = ACRResolveFileDialog(request, nil, 0)
        }
        pendingPageRequests.removeAll()
        if let menu = openContextMenu { _ = ACRResolveContextMenu(menu.id, -1) }
        openContextMenu = nil
        if isRendererUnresponsive { _ = ACRResolveUnresponsive(token, 0) }
        // The shell disposed it while asking: it closes anyway.
        _ = finishCloseConfirmation(closed: true)
    }

    /// The browser is gone: the bridge already dropped its requests.
    func pageRequestsDidEnd() {
        pendingDialogRequests.removeAll()
        pendingPageRequests.removeAll()
        openContextMenu = nil
        isRendererUnresponsive = false
    }

    // MARK: JavaScript dialogs

    static func dialogKind(value: Int32, flags: Int32, defaultText: String?) -> BrowserJavaScriptDialog.Kind {
        switch value {
        case 1: .confirm
        case 2: .prompt(defaultText: defaultText ?? "")
        case 3: .beforeUnload(isReload: flags & 1 != 0)
        default: .alert
        }
    }

    /// Bridge answer (`accept`, `text`) for a contract response. A suppressed beforeunload proceeds,
    /// as Chromium does for a suppressed dialog; a suppressed alert, confirm or prompt is cancelled.
    static func bridgeAnswer(_ response: BrowserJavaScriptDialogResponse,
                             kind: BrowserJavaScriptDialog.Kind) -> (accept: Bool, text: String?) {
        switch response {
        case .accept(let text):
            if case .prompt = kind { return (true, text ?? "") }
            return (true, nil)
        case .cancel: return (false, nil)
        case .suppressed:
            if case .beforeUnload = kind { return (true, nil) }
            return (false, nil)
        }
    }

    private func runJavaScriptDialog(_ event: ChromiumEvent) {
        let request = event.requestID
        let kind = Self.dialogKind(value: event.value, flags: event.flags, defaultText: event.title)
        let dialog = BrowserJavaScriptDialog(kind: kind, message: event.detail ?? "",
                                             origin: BrowserJavaScriptDialog.origin(of: event.url.flatMap(URL.init(string:))))
        if case .beforeUnload = kind, closeConfirmation != nil { closeConfirmationAskedUser = true }
        onEngineEvent?("js-dialog", ["kind": "\(kind)", "request": String(request)])
        guard let delegate else {
            let answer = Self.bridgeAnswer(.suppressed, kind: kind)
            _ = ACRResolveJSDialog(request, answer.accept ? 1 : 0, answer.text)
            return
        }
        pendingDialogRequests.insert(request)
        Task { @MainActor [self] in
            let response = await delegate.surface(self, runJavaScriptDialog: dialog)
            // Disposed or reset meanwhile: already answered by the bridge or by dispose().
            guard pendingDialogRequests.remove(request) != nil else {
                onEngineEvent?("js-dialog-late-answer-ignored", ["request": String(request)])
                return
            }
            let answer = Self.bridgeAnswer(response, kind: kind)
            _ = ACRResolveJSDialog(request, answer.accept ? 1 : 0, answer.text)
            onEngineEvent?("js-dialog-resolved", ["request": String(request), "accept": String(answer.accept)])
            // Stay on a navigation's beforeunload: the requested destination never loads.
            if case .beforeUnload = kind, !answer.accept, closeConfirmation == nil {
                cancelStoppedNavigationTracking()
                onChange?()
            }
        }
    }

    // MARK: HTTP authentication

    struct AuthPayload: Decodable {
        let origin: String
        let host: String
        let port: Int
        let realm: String
        let scheme: String
        let proxy: Bool
    }

    static func challenge(from payload: Data?) -> BrowserAuthenticationChallenge? {
        guard let payload, let value = try? JSONDecoder().decode(AuthPayload.self, from: payload) else { return nil }
        let origin = BrowserJavaScriptDialog.origin(of: URL(string: value.origin)) ?? value.origin
        return BrowserAuthenticationChallenge(origin: origin, host: value.host, port: value.port,
                                              realm: value.realm.isEmpty ? nil : value.realm,
                                              scheme: value.scheme.isEmpty ? nil : value.scheme.lowercased(),
                                              isProxy: value.proxy)
    }

    private func requestCredentials(_ event: ChromiumEvent) {
        let request = event.requestID
        guard let delegate, let challenge = Self.challenge(from: event.payload) else {
            _ = ACRResolveAuth(request, nil, nil)
            return
        }
        pendingPageRequests.insert(request)
        // Never traced with the credentials; only that a challenge happened.
        onEngineEvent?("auth-challenge", ["proxy": String(challenge.isProxy), "request": String(request)])
        Task { @MainActor [self] in
            let credential = await delegate.surface(self, requestsCredentialsFor: challenge)
            guard pendingPageRequests.remove(request) != nil else { return }
            _ = ACRResolveAuth(request, credential?.user, credential?.password)
            onEngineEvent?("auth-resolved", ["provided": String(credential != nil)])
        }
    }

    // MARK: File choosers

    struct FileDialogPayload: Decodable {
        let mode: Int
        let title: String
        let defaultPath: String
        let acceptTypes: [String]
        let acceptExtensions: [String]
    }

    static func fileChooserRequest(from payload: Data?) -> BrowserFileChooserRequest? {
        guard let payload, let value = try? JSONDecoder().decode(FileDialogPayload.self, from: payload) else { return nil }
        let mode: BrowserFileChooserRequest.Mode = switch value.mode {
        case 1: .openMultiple
        case 2: .openFolder
        case 3: .save
        case 4: .openExistingFolder
        default: .open
        }
        // CEF expands each filter to a ";"-separated list of ".ext" (empty when unknown).
        let extensions = value.acceptExtensions
            .flatMap { $0.split(separator: ";") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
        var unique: [String] = []
        for item in extensions where !unique.contains(item) { unique.append(item) }
        return BrowserFileChooserRequest(mode: mode, title: value.title.isEmpty ? nil : value.title,
                                         defaultPath: value.defaultPath.isEmpty ? nil : value.defaultPath,
                                         acceptTypes: value.acceptTypes.map { $0.lowercased() }.filter { !$0.isEmpty },
                                         acceptExtensions: unique)
    }

    private func runFileChooser(_ event: ChromiumEvent) {
        let request = event.requestID
        guard let delegate, let chooser = Self.fileChooserRequest(from: event.payload) else {
            _ = ACRResolveFileDialog(request, nil, 0)
            return
        }
        pendingPageRequests.insert(request)
        onEngineEvent?("file-chooser", ["mode": "\(chooser.mode)", "request": String(request)])
        Task { @MainActor [self] in
            let files = await delegate.surface(self, runFileChooser: chooser) ?? []
            guard pendingPageRequests.remove(request) != nil else { return }
            let paths = files.filter(\.isFileURL).map { strdup($0.path) }
            defer { paths.forEach { free($0) } }
            paths.withUnsafeBufferPointer { buffer in
                buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { pointers in
                    _ = ACRResolveFileDialog(request, pointers.baseAddress, pointers.count)
                }
            }
            onEngineEvent?("file-chooser-resolved", ["count": String(paths.count)])
        }
    }

    // MARK: Context menus

    struct ContextMenuPayload: Decodable {
        let x: Double
        let y: Double
        let linkURL: String
        let sourceURL: String
        let pageURL: String
        let frameURL: String
        let hasImageContents: Bool
        let titleText: String
        let mediaType: Int
        let mediaFlags: Int
        let selectionText: String
        let misspelledWord: String
        let suggestions: [String]
        let isEditable: Bool
        let editFlags: Int
        let commands: [String: Int32]
        let extensionItems: [BrowserExtensionMenuItem]?
    }

    /// Contract command kinds a Chrome command name executes.
    static let commandNames: [BrowserContextMenuCommand.Kind: String] = [
        .undo: "IDC_CONTENT_CONTEXT_UNDO", .redo: "IDC_CONTENT_CONTEXT_REDO", .cut: "IDC_CONTENT_CONTEXT_CUT",
        .copy: "IDC_CONTENT_CONTEXT_COPY", .paste: "IDC_CONTENT_CONTEXT_PASTE",
        .pasteAndMatchStyle: "IDC_CONTENT_CONTEXT_PASTE_AND_MATCH_STYLE", .delete: "IDC_CONTENT_CONTEXT_DELETE",
        .selectAll: "IDC_CONTENT_CONTEXT_SELECTALL", .addToDictionary: "IDC_SPELLCHECK_ADD_TO_DICTIONARY",
        .copyImage: "IDC_CONTENT_CONTEXT_COPYIMAGE", .saveImage: "IDC_CONTENT_CONTEXT_SAVEIMAGEAS",
        .saveLink: "IDC_CONTENT_CONTEXT_SAVELINKAS", .saveMedia: "IDC_CONTENT_CONTEXT_SAVEAVAS",
        .mediaPlayPause: "IDC_CONTENT_CONTEXT_PLAYPAUSE", .mediaMute: "IDC_CONTENT_CONTEXT_MUTE",
        .mediaLoop: "IDC_CONTENT_CONTEXT_LOOP", .mediaControls: "IDC_CONTENT_CONTEXT_CONTROLS",
        .mediaPictureInPicture: "IDC_CONTENT_CONTEXT_PICTUREINPICTURE", .lookUp: "IDC_CONTENT_CONTEXT_LOOK_UP",
        .inspect: "IDC_CONTENT_CONTEXT_INSPECTELEMENT"
    ]

    /// Chrome command name for a contract command; spelling suggestions by their index (Chrome offers
    /// at most five).
    static func commandName(for command: BrowserContextMenuCommand, request: BrowserContextMenuRequest) -> String? {
        if case .replaceMisspelling(let word) = command {
            guard let index = request.spellingSuggestions.firstIndex(of: word), index < 5 else { return nil }
            return "IDC_SPELLCHECK_SUGGESTION_\(index)"
        }
        return commandNames[command.kind]
    }

    static func contextMenuRequest(from payload: Data?, documentGeneration: UInt64)
        -> (request: BrowserContextMenuRequest, commands: [String: Int32])? {
        guard let payload, let value = try? JSONDecoder().decode(ContextMenuPayload.self, from: payload) else { return nil }
        func url(_ string: String) -> URL? { string.isEmpty ? nil : URL(string: string) }
        let mediaKind: BrowserContextMenuRequest.MediaKind = switch value.mediaType {
        case 1: .image
        case 2: .video
        case 3: .audio
        case 4: .canvas
        case 5: .file
        case 6: .plugin
        default: .none
        }
        var edit: BrowserContextMenuRequest.EditFlags = []
        let editPairs: [(Int, BrowserContextMenuRequest.EditFlags)] = [
            (1 << 0, .canUndo), (1 << 1, .canRedo), (1 << 2, .canCut), (1 << 3, .canCopy), (1 << 4, .canPaste),
            (1 << 5, .canDelete), (1 << 6, .canSelectAll), (1 << 8, .canEditRichly)]
        for (bit, flag) in editPairs where value.editFlags & bit != 0 { edit.insert(flag) }
        var media: BrowserContextMenuRequest.MediaState = []
        let mediaPairs: [(Int, BrowserContextMenuRequest.MediaState)] = [
            (1 << 1, .paused), (1 << 2, .muted), (1 << 3, .loop), (1 << 5, .hasAudio),
            (1 << 6, .canToggleControls), (1 << 7, .controlsVisible), (1 << 10, .canPictureInPicture)]
        for (bit, flag) in mediaPairs where value.mediaFlags & bit != 0 { media.insert(flag) }
        var available: Set<BrowserContextMenuCommand.Kind> = []
        for (kind, name) in commandNames where value.commands[name] != nil { available.insert(kind) }
        if value.commands.keys.contains(where: { $0.hasPrefix("IDC_SPELLCHECK_SUGGESTION_") }) {
            available.insert(.replaceMisspelling)
        }
        if value.extensionItems?.isEmpty == false { available.insert(.extensionAction) }
        let request = BrowserContextMenuRequest(
            location: CGPoint(x: value.x, y: value.y), pageURL: url(value.pageURL), frameURL: url(value.frameURL),
            linkURL: url(value.linkURL), mediaKind: mediaKind, sourceURL: url(value.sourceURL),
            hasImageContents: value.hasImageContents, titleText: value.titleText.isEmpty ? nil : value.titleText,
            selectionText: value.selectionText, isEditable: value.isEditable, editFlags: edit, mediaState: media,
            misspelledWord: value.misspelledWord.isEmpty ? nil : value.misspelledWord,
            spellingSuggestions: Array(value.suggestions.prefix(5)), documentGeneration: documentGeneration,
            availableCommands: available, extensionItems: value.extensionItems ?? [])
        return (request, value.commands)
    }

    private func showContextMenu(_ event: ChromiumEvent) {
        if let previous = openContextMenu {
            openContextMenu = nil
            _ = ACRResolveContextMenu(previous.id, -1)
        }
        guard let delegate,
              let parsed = Self.contextMenuRequest(from: event.payload, documentGeneration: documentGeneration) else {
            _ = ACRResolveContextMenu(event.requestID, -1)
            return
        }
        openContextMenu = (event.requestID, parsed.commands, parsed.request)
        onEngineEvent?("context-menu", ["request": String(event.requestID), "commands": String(parsed.commands.count),
                                        "link": String(parsed.request.linkURL != nil),
                                        "editable": String(parsed.request.isEditable)])
        delegate.surface(self, showContextMenu: parsed.request)
    }

    public func performContextMenuCommand(_ command: BrowserContextMenuCommand, for request: BrowserContextMenuRequest) throws {
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        guard request.documentGeneration == documentGeneration, let menu = openContextMenu, menu.request == request else {
            throw BrowserEngineError.documentChanged
        }
        let id: Int32
        if case .extensionAction(let commandID) = command {
            guard request.extensionItems.contains(where: { $0.permits(commandID) }) else {
                throw BrowserEngineError.unsupportedOperation
            }
            id = commandID
        } else {
            guard request.availableCommands.contains(command.kind),
                  let name = Self.commandName(for: command, request: request), let nativeID = menu.commands[name] else {
                throw BrowserEngineError.unsupportedOperation
            }
            id = nativeID
        }
        openContextMenu = nil
        guard ACRResolveContextMenu(menu.id, id) == 1 else { throw BrowserEngineError.unsupportedOperation }
        onEngineEvent?("context-menu-command", ["command": command.kind.rawValue])
    }

    public func contextMenuDidClose(_ request: BrowserContextMenuRequest) {
        guard let menu = openContextMenu, menu.request == request else { return }
        openContextMenu = nil
        _ = ACRResolveContextMenu(menu.id, -1)
    }

    /// Laboratory and smoke observation: the open native context menu's offered commands.
    public var openContextMenuCommands: [String: Int32]? { openContextMenu?.commands }

    // MARK: Renderer

    static func termination(status: Int32) -> BrowserRendererTermination {
        switch status {
        case 0, 2: .crashed       // TS_ABNORMAL_TERMINATION, TS_PROCESS_CRASHED
        case 1: .killed           // TS_PROCESS_WAS_KILLED
        case 3: .outOfMemory      // TS_PROCESS_OOM
        default: .unknown         // TS_LAUNCH_FAILED, TS_INTEGRITY_FAILURE
        }
    }

    func rendererDidTerminate(status: Int32) {
        let termination = Self.termination(status: status)
        rendererTermination = termination
        isRendererUnresponsive = false
        isElementFullscreen = false
        delegate?.surface(self, rendererDidTerminate: termination)
    }

    // MARK: Commands

    public func exitElementFullscreen() {
        guard !isDisposed, isBrowserCreated else { return }
        _ = ACRExitFullscreen(token)
    }

    /// Native fullscreen state of the document (laboratory, smoke).
    public var nativeElementFullscreen: Bool? {
        guard !isDisposed, isBrowserCreated else { return nil }
        let value = ACRIsFullscreen(token)
        return value < 0 ? nil : value == 1
    }

    public var hasDevTools: Bool { !isDisposed && isBrowserCreated && ACRHasDevTools(token) == 1 }

    public func perform(_ command: BrowserPageCommand) throws {
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        guard isBrowserCreated else { throw BrowserEngineError.unsupportedOperation }
        let result: Int32 = switch command {
        case .print: ACRPrint(token)
        case .showDevTools: ACRShowDevTools(token, 0, 0, 0)
        case .inspectElements: ACRExecuteChromeCommand(token, "IDC_DEV_TOOLS_INSPECT")
        case .closeDevTools: ACRCloseDevTools(token)
        case .terminateUnresponsiveRenderer: ACRResolveUnresponsive(token, 1)
        case .waitForUnresponsiveRenderer: ACRResolveUnresponsive(token, 0)
        }
        if command == .waitForUnresponsiveRenderer || command == .terminateUnresponsiveRenderer {
            isRendererUnresponsive = false
        }
        onEngineEvent?("page-command", ["command": "\(command)", "result": String(result)])
        guard result == 1 else { throw BrowserEngineError.unsupportedOperation }
    }

    // MARK: beforeunload-aware close

    /// Hosted tabs run beforeunload through `TryCloseBrowser`; when the page agrees, Chrome closes
    /// the tab natively and the shell then disposes the surface. Without an answer and without a
    /// dialog for `confirmationGrace`, the close proceeds (a hung handler never traps the tab).
    public func confirmClose() async -> Bool {
        guard !isDisposed, isBrowserCreated, hostedWindowToken != 0, closeConfirmation == nil else {
            return closeConfirmation == nil
        }
        // TryCloseBrowser destroys a Chrome-style browser on approval. Downloads still need
        // that browser's callbacks; unload its document with native beforeunload instead.
        isConfirmingDownloadClose = hasActiveDownloads
        let request = isConfirmingDownloadClose ? ACRRequestDownloadSourceClose(token) : ACRRequestClose(token)
        switch request {
        case 1, 3:
            break
        default:
            isConfirmingDownloadClose = false
            onEngineEvent?("close-confirmed", ["immediate": "true"])
            return true
        }
        closeConfirmationAskedUser = false
        let grace = Self.confirmationGrace
        return await withCheckedContinuation { continuation in
            closeConfirmation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: grace)
                guard let self, self.closeConfirmation != nil, !self.closeConfirmationAskedUser,
                      !self.isConfirmingDownloadClose else { return }
                self.onEngineEvent?("close-confirmation-grace-elapsed", [:])
                _ = self.finishCloseConfirmation(closed: true)
            }
        }
    }

    static let confirmationGrace = Duration.seconds(5)

    /// Resumes `confirmClose`. True when one was waiting.
    @discardableResult
    func finishCloseConfirmation(closed: Bool) -> Bool {
        guard let continuation = closeConfirmation else { return false }
        closeConfirmation = nil
        isConfirmingDownloadClose = false
        closeConfirmationAskedUser = false
        if closed { closedByConfirmation = true }
        onEngineEvent?("close-confirmed", ["closed": String(closed)])
        continuation.resume(returning: closed)
        if closed, !isDisposed {
            // The shell disposes after a positive answer; never leave a natively closed surface live.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if let self, !self.isDisposed, !self.isBrowserCreated { self.dispose() }
            }
        }
        return true
    }
}
