import AppKit
import BrowserCore
import BrowserEngine
import OSLog

@MainActor
final class BrowserPaletteController<Engine: BrowserEngine> {
    private weak var owner: BrowserWindowController<Engine>?
    weak var registry: BrowserCommandRegistry<BrowserWindowController<Engine>>?
    let view = BrowserPaletteView(frame: .zero)
    private(set) var target: BrowserCommandTarget?
    private var context: BrowserContext?
    private var hasCapturedContext = false
    private var sourceContext: BrowserContext?
    private(set) var mode: BrowserPaletteMode = .newTab
    private var opensEmptyAddress = false
    private(set) var results: [BrowserPaletteResult] = []
    private(set) var selection = BrowserPaletteSelection()
    private var candidates: [BrowserPaletteResult] = []
    private var preparedCandidates: [BrowserPaletteRanking.PreparedCandidate] = []
    private var history: [BrowserHistorySuggestion] = []
    private var availableActions: [BrowserPaletteResult] = []
    private var queryTask: Task<Void, Never>?
    private var documentTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var warmupTask: Task<Void, Never>?
    private var previousOccurrence: TabOccurrenceID?
    private var acceptTask: Task<Void, Never>?
    private var acceptInvocation = UUID()
    private var generation = UUID()
    private var inputRevision = UUID()
    private var presentation = UUID()
    private(set) var presentationSequence: UInt64 = 0
    private weak var previousResponder: NSResponder?
    private let faviconCache = BrowserPaletteFaviconCache()
    private static var signposter: OSSignposter { OSSignposter(subsystem: "local.orbit", category: "palette") }
    private(set) var lastRenderMilliseconds = 0.0
    private(set) var lastAsyncRenderMilliseconds = 0.0
    private(set) var completedQuery = ""
    private var lastQuery = ""
    private(set) var draft = ""
    private(set) var siteSearch: BrowserPaletteSiteSearch?
    private var selectionWasMoved = false
    var isPresented: Bool { !view.isHidden }
    var isAccepting: Bool { acceptTask != nil }

    var faviconCacheStatistics: [String: Int] { faviconCache.cacheStatistics }

    func waitForResults() async {
        await presentationTask?.value
        await warmupTask?.value
        await documentTask?.value
        await queryTask?.value
    }
    func waitForAcceptance() async { await acceptTask?.value }

    init(owner: BrowserWindowController<Engine>) {
        self.owner = owner
        view.onQuery = { [weak self] in self?.query($0) }
        view.onMove = { [weak self] in self?.move($0) }
        view.onDismiss = { [weak self] in self?.dismiss() }
        view.onCancel = { [weak self] in self?.leaveSiteSearch() ?? false }
        view.onTab = { [weak self] in self?.enterSiteSearch() ?? false }
        view.onEmptyBackspace = { [weak self] in self?.leaveSiteSearch() ?? false }
        view.onAccept = { [weak self] in self?.accept(modifiers: $0) }
        view.onSelect = { [weak self] index in
            guard let self else { return }
            selection.select(index, count: results.count)
            accept()
        }
        faviconCache.onChange = { [weak self] in
            guard let self, isPresented else { return }
            renderResults()
        }
    }

    func present(_ requestedMode: BrowserPaletteMode, emptyAddress: Bool = false) {
        guard let owner, owner.acceptsCommands, let registry, !owner.session.isClosed else { return }
        if isPresented, mode == requestedMode { dismiss(); return }
        presentationSequence &+= 1
        if !isPresented {
            let responder = owner.window?.firstResponder
            let field = (responder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : nil }
            previousResponder = field ?? responder
            previousOccurrence = owner.session.snapshot?.selectedOccurrenceID
        }
        queryTask?.cancel()
        documentTask?.cancel()
        presentationTask?.cancel()
        warmupTask?.cancel()
        acceptTask?.cancel()
        acceptTask = nil
        acceptInvocation = UUID()
        presentation = UUID()
        generation = UUID()
        let ticket = presentation
        siteSearch = nil
        view.setSiteSearch(nil, animated: false)
        mode = requestedMode
        opensEmptyAddress = emptyAddress
        owner.hideLibrary(focus: false)
        owner.dismissPeek()
        hasCapturedContext = false
        context = owner.session.paletteContext
        sourceContext = context
        target = nil
        installCandidates(owner.session.organization.map(BrowserPaletteRanking.localCandidates) ?? [])
        history = []
        availableActions = registry.definitions.sorted {
            BrowserDailyCommands.priority($0.id) < BrowserDailyCommands.priority($1.id)
        }.filter {
            $0.scope != .responder && $0.id != .newTab && $0.id != .openCommandBar && registry.isImplemented($0.id)
                && OrbitCommandCatalog.isCommandBarAction($0)
        }.map {
            .init(id: "command:\($0.id.rawValue)", title: $0.localizedTitle, detail: $0.id == .manageExtensions && owner.engine.extensionManagement == nil
                    ? uiText("Extensions require an updated Chromium build.") : BrowserDailyCommands.detail($0.id), section: .commands, action: .command($0.id),
                  searchAliases: BrowserDailyCommands.aliases($0.id), shortcut: $0.shortcuts.first?.displayLabel ?? "")
        }
        view.accent = OrbitSpaceThemes.accent(for: owner.resolvedSpaceTheme(for: context?.spaceID)).selection
        view.input.stringValue = mode == .currentTab && !emptyAddress ? owner.session.selectedSurface?.navigationState.url?.absoluteString ?? "" : ""
        view.isHidden = false
        view.superview?.addSubview(view, positioned: .above, relativeTo: nil)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        owner.window?.makeFirstResponder(view.input)
        view.input.currentEditor()?.selectAll(nil)
        query(view.input.stringValue, userInitiated: false)
        let firstQuery = inputRevision
        let boundary = owner.session.captureContextInCommandOrder()
        presentationTask = Task { [weak self, weak owner] in
            let ready = await boundary.value
            guard let self, let owner, let ready, !Task.isCancelled, isPresented, presentation == ticket else { return }
            context = ready
            hasCapturedContext = true
            let sources = owner.session.paletteContext ?? ready
            sourceContext = sources
            if requestedMode == .currentTab, !emptyAddress, inputRevision == firstQuery {
                view.input.stringValue = ready.selectedOccurrenceID.flatMap { owner.session.surface(for: $0)?.navigationState.url?.absoluteString } ?? ""
                view.input.currentEditor()?.selectAll(nil)
                draft = view.input.stringValue
            }
            query(draft, preserveSelection: true, userInitiated: false)
            loadDocument(for: sources)
            warmupTask = Task { [weak self, weak owner] in
                guard let owner else { return }
                await owner.historyObserver.prepareSuggestions(for: sources.profileID)
                guard let self, !Task.isCancelled, isPresented, presentation == ticket, sourceContext?.profileID == sources.profileID else { return }
                query(draft, preserveSelection: true, userInitiated: false)
            }

        }
    }

    /// Loading/redirects/revisions are unrelated to the user's draft. Only retirement ends it.
    var isCurrent: Bool {
        guard let owner else { return false }
        return owner.acceptsCommands && !owner.session.isClosed
    }

    func renderContext() {
        guard isPresented else { return }
        guard isCurrent else { dismiss(returnFocus: false); return }
        guard let ready = owner?.session.paletteContext else { return }
        // Command-L edits one occurrence. A replacement selection ends that editing intent;
        // keeping a stale draft would leave Return permanently unable to act.
        if mode == .currentTab, hasCapturedContext, !isAccepting,
           ready.selectedOccurrenceID != context?.selectedOccurrenceID || ready.spaceID != context?.spaceID || ready.profileID != context?.profileID {
            dismiss()
            return
        }
        if ready.profileID != sourceContext?.profileID || ready.spaceID != sourceContext?.spaceID {
            let changedProfile = ready.profileID != sourceContext?.profileID
            sourceContext = ready
            if changedProfile { history = []; faviconCache.clear() }
            installCandidates(owner?.session.organization.map(BrowserPaletteRanking.localCandidates) ?? [])
            loadDocument(for: ready)
            query(draft, preserveSelection: !changedProfile, userInitiated: false)
        } else { renderResults() }
    }

    private func loadDocument(for ready: BrowserContext) {
        documentTask?.cancel()
        let ticket = presentation
        documentTask = Task { [weak self, weak owner] in
            guard let owner else { return }
            let document = await owner.session.paletteDocument()
            guard let self, let registry, !Task.isCancelled, isPresented, presentation == ticket,
                  sourceContext?.profileID == ready.profileID else { return }
            let windows = registry.router.windows.values
            let mapping = Dictionary(uniqueKeysWithValues: windows.compactMap { window -> (WindowID, UUID)? in
                guard let id = window.session.snapshot?.id else { return nil }; return (id, window.id)
            })
            let computed = await Task.detached(priority: .userInitiated) {
                let candidates = BrowserPaletteRanking.candidates(document: document, profileID: ready.profileID,
                    windowID: ready.windowID, spaceID: ready.spaceID, windowIDs: mapping)
                return (candidates, candidates.map(BrowserPaletteRanking.PreparedCandidate.init))
            }.value
            guard !Task.isCancelled, isPresented, presentation == ticket,
                  sourceContext?.profileID == ready.profileID, sourceContext?.spaceID == ready.spaceID else { return }
            candidates = computed.0
            preparedCandidates = computed.1
            rebuild(preserveSelection: true)
        }
    }

    private func installCandidates(_ next: [BrowserPaletteResult]) {
        candidates = next
        preparedCandidates = next.map(BrowserPaletteRanking.PreparedCandidate.init)
    }

    func query(_ text: String, preserveSelection: Bool = false, userInitiated: Bool = true) {
        guard isPresented, isCurrent else { return }
        let clock = ContinuousClock()
        let start = clock.now
        let signpost = Self.signposter.beginInterval("PaletteFirstDisplay")
        defer {
            view.layoutSubtreeIfNeeded()
            let duration = start.duration(to: clock.now)
            lastRenderMilliseconds = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
            Self.signposter.endInterval("PaletteFirstDisplay", signpost)
        }
        draft = text
        if view.input.stringValue != text { view.input.stringValue = text }
        if userInitiated {
            selectionWasMoved = false
            inputRevision = UUID()
            // New editing intent revokes an acceptance which has not committed yet. A committed
            // navigation may complete, but its receipt cannot dismiss this newer draft.
            acceptTask?.cancel()
            acceptTask = nil
            acceptInvocation = UUID()
        }
        let extendsQuery = BrowserSuggestionText.fold(text).hasPrefix(BrowserSuggestionText.fold(lastQuery))
        history = extendsQuery ? history.filter { BrowserSuggestionText.matches(text, title: $0.title, url: $0.url) } : []
        lastQuery = text
        generation = UUID()
        let token = generation
        queryTask?.cancel()
        if siteSearch == nil, let owner, let profileID = sourceContext?.profileID {
            let cached = owner.historyObserver.cachedSuggestions(for: profileID, query: text)
            history = BrowserPaletteRanking.rankedHistory(history + cached, query: text)
        }
        rebuild(preserveSelection: preserveSelection)
        guard siteSearch == nil, let owner, let profileID = sourceContext?.profileID else { return }
        queryTask = Task { [weak self, weak owner] in
            guard let owner, !Task.isCancelled else { return }
            let suggestions: [BrowserHistorySuggestion]
            do { suggestions = try await owner.historyObserver.suggestions(for: profileID, query: text) }
            catch { return }
            guard let self, !Task.isCancelled, generation == token, isPresented, isCurrent,
                  sourceContext?.profileID == profileID else { return }
            let interval = Self.signposter.beginInterval("PaletteAsyncRender")
            let clock = ContinuousClock()
            let renderStart = clock.now
            history = BrowserPaletteRanking.rankedHistory(suggestions + owner.historyObserver.cachedSuggestions(for: profileID, query: text), query: text)
            completedQuery = text
            rebuild(preserveSelection: true)
            view.layoutSubtreeIfNeeded()
            let renderTime = renderStart.duration(to: clock.now)
            lastAsyncRenderMilliseconds = Double(renderTime.components.seconds) * 1000 + Double(renderTime.components.attoseconds) / 1e15
            Self.signposter.endInterval("PaletteAsyncRender", interval)
        }
    }

    private func rebuild(preserveSelection: Bool) {
        guard let owner else { return }
        let selectedID = preserveSelection && selectionWasMoved && results.indices.contains(selection.index) ? results[selection.index].id : nil
        results = siteSearch?.results(query: draft) ?? BrowserPaletteRanking.results(query: draft, mode: mode, resolver: owner.addressResolver,
                                                candidates: opensEmptyAddress ? candidates.filter { $0.url?.absoluteString != "about:blank" } : candidates,
                                                history: history, actions: opensEmptyAddress && draft.isEmpty ? [] : availableActions,
                                                prepared: opensEmptyAddress ? preparedCandidates.filter { $0.result.url?.absoluteString != "about:blank" } : preparedCandidates)
        if let selectedID, let index = results.firstIndex(where: { $0.id == selectedID }) { selection.select(index, count: results.count) }
        else { selection.reset() }
        renderResults()
    }

    private func renderResults() {
        guard let owner, let registry else { return }
        var icons: [String: NSImage] = [:]
        let profileID = sourceContext?.profileID
        let historyIcons = Dictionary(history.compactMap { item -> (String, URL)? in
            guard let reference = item.faviconReference else { return nil }
            return (BrowserPaletteRanking.canonicalURL(item.url), reference)
        }, uniquingKeysWith: { first, _ in first })
        for result in results {
            if case .tab(let id, let windowID, _) = result.action,
               let controller = windowID.flatMap({ registry.router.windows[$0] }) ?? (windowID == nil ? owner : nil),
               let occurrence = controller.session.organization?.tab(id)?.occurrenceID,
               let surface = controller.session.surface(for: occurrence), surface.profileID == profileID {
                let state = surface.navigationState
                if let image = state.faviconImage, image.sourceURL == state.faviconURL {
                    icons[result.id] = faviconCache.image(for: image)
                } else if let reference = state.faviconURL {
                    icons[result.id] = faviconCache.image(for: reference)
                }
            }
            if icons[result.id] == nil,
               let reference = result.faviconReference ?? result.url.flatMap({ historyIcons[BrowserPaletteRanking.canonicalURL($0)] }) {
                icons[result.id] = faviconCache.image(for: reference)
            }
            // Known profile-local pixels must survive a cold palette decode or LRU eviction.
            // The shared sidebar working set also restores disk-backed icons in this render.
            if icons[result.id] == nil, result.section != .search, let profileID, let home = result.url {
                icons[result.id] = owner.sidebarIcons.memoryCache.image(profile: profileID, home: home)
            }
        }
        view.siteSearchHint = siteSearch == nil ? BrowserPaletteSiteSearch.matching(draft) : nil
        view.favicons = icons
        view.render(results, selected: selection.index)
        if results.indices.contains(selection.index), siteSearch == nil {
            view.completeURL(for: results[selection.index], draft: draft)
        }
    }

    func move(_ delta: Int) {
        selectionWasMoved = true
        selection.move(delta, count: results.count)
        view.input.stringValue = draft
        if let editor = view.input.currentEditor() as? NSTextView, !editor.hasMarkedText() {
            editor.string = draft
            editor.setSelectedRange(NSRange(location: (draft as NSString).length, length: 0))
        }
        view.updateSelection(selection.index)
        if results.indices.contains(selection.index), siteSearch == nil {
            view.completeURL(for: results[selection.index], draft: draft)
        }
    }

    @discardableResult
    func enterSiteSearch() -> Bool {
        guard isPresented, siteSearch == nil, let site = BrowserPaletteSiteSearch.matching(draft) else { return false }
        siteSearch = site
        history = []
        view.setSiteSearch(site, animated: true)
        query("")
        return true
    }

    @discardableResult
    func leaveSiteSearch() -> Bool {
        guard isPresented, siteSearch != nil else { return false }
        siteSearch = nil
        history = []
        view.setSiteSearch(nil, animated: true)
        query("")
        return true
    }

    func accept(modifiers: NSEvent.ModifierFlags = []) {
        guard isPresented, isCurrent, acceptTask == nil, results.indices.contains(selection.index), let owner else { return }
        // Alternate Return selectors are consumed by the field. Their unverified disposition
        // remains inactive, without inserting a newline or losing the current draft.
        guard !modifiers.contains(.option), !modifiers.contains(.control) else { return }
        let acceptedResultID = results[selection.index].id
        let ticket = presentation
        let queryToken = inputRevision
        let newTab = mode == .newTab || modifiers.contains(.command)
        let capturedMode = mode
        // Extension commands retain their displayed document before any presentation or
        // session await. This snapshot is not a grant; registry delivery still validates it.
        let acceptedSurface = owner.session.selectedSurface
        let acceptedCommandTarget = owner.commandState.context.map {
            BrowserCommandTarget(windowID: owner.id, context: $0, policy: .document)
        }
        let invocation = UUID()
        acceptInvocation = invocation
        acceptTask = Task { [weak self, weak owner] in
            guard let self, let owner else { return }
            defer {
                if acceptInvocation == invocation {
                    acceptTask = nil
                    renderContext()
                }
            }
            await presentationTask?.value
            guard !Task.isCancelled, presentation == ticket, inputRevision == queryToken, isPresented,
                  let context, let result = results.first(where: { $0.id == acceptedResultID }) else { return }
            let action: BrowserPaletteAction
            if modifiers.contains(.command), case .tab = result.action, let url = result.url {
                action = .navigate(url)
            } else { action = result.action }
            switch action {
            case .navigate(let url):
                owner.hideLibrary(focus: false)
                let accepted = owner.session.navigateFromPalette(from: context, newTab: newTab) { [weak owner] surface in
                    guard let owner else { return }
                    if BrowserPaletteRanking.recordsTypedVisit(result) { owner.historyObserver.markTypedNavigation(surface, url: url) }
                    if !newTab, surface.navigationState.url == url { surface.reload() }
                    else { surface.navigate(to: url) }
                    owner.session.updateDestination(for: surface, to: url)
                }
                let didNavigate = await withTaskCancellationHandler { await accepted.value } onCancel: { accepted.cancel() }
                if didNavigate, inputRevision == queryToken { finishAccept(ticket: ticket, returnFocus: true) }
            case .archive(let id):
                guard let sourceContext else { return }
                owner.hideLibrary(focus: false)
                if await owner.session.restoreFromPalette(id, from: sourceContext).value, inputRevision == queryToken { finishAccept(ticket: ticket, returnFocus: true) }
            case .tab(let id, let windowID, let spaceID):
                guard let registry,
                      let destination = windowID.flatMap({ registry.router.windows[$0] }) ?? (windowID == nil ? owner : nil),
                      let destinationContext = destination.session.paletteContext,
                      destinationContext.profileID == sourceContext?.profileID else { return }
                owner.hideLibrary(focus: false)
                destination.hideLibrary(focus: false)
                if await destination.session.selectFromPalette(id, from: destinationContext, spaceID: spaceID).value {
                    guard inputRevision == queryToken else { return }
                    finishAccept(ticket: ticket, returnFocus: destination === owner)
                    if destination !== owner, owner.window?.isKeyWindow == true { owner.focusSelectedDocument() }
                    if destination !== owner, owner.window?.isVisible == true { destination.showWindow(nil); destination.window?.makeKeyAndOrderFront(nil); destination.focusSelectedDocument() }
                }
            case .command(let id):
                let requiresOriginalSurface = id == .manageExtensions || id == .addExtension
                guard owner.session.paletteContext?.profileID == context.profileID,
                      owner.session.paletteContext?.spaceID == context.spaceID else { return }
                for _ in 0..<3 {
                    await owner.session.waitForQueuedCommands()
                    guard isPresented, presentation == ticket, inputRevision == queryToken, !Task.isCancelled, let registry,
                          (!requiresOriginalSurface && capturedMode == .newTab) || owner.session.paletteContext?.selectedOccurrenceID == context.selectedOccurrenceID,
                          owner.session.paletteContext?.profileID == context.profileID,
                          owner.session.paletteContext?.spaceID == context.spaceID,
                          let capture = registry.capturePaletteTarget(windowID: owner.id) else { return }
                    if requiresOriginalSurface {
                        guard let acceptedCommandTarget,
                              owner.session.selectedSurface === acceptedSurface,
                              acceptedCommandTarget.matches(capture.context) else { return }
                    }
                    target = capture
                    let global = registry.definition(id)?.requirement == .application
                    if global {
                        guard registry.capturePaletteTarget()?.windowID == owner.id,
                              registry.router.selectedWindowID == owner.id,
                              !registry.router.hasPendingSelectedWindowCommands else { return }
                    }
                    owner.hideLibrary(focus: false)
                    let editor = view.input.currentEditor()
                    var wasDelivered = false
                    let accepted = registry.dispatch(id, origin: .palette, target: global ? nil : capture, onDelivered: { [weak self, weak owner] in
                        wasDelivered = true
                        guard let self, inputRevision == queryToken else { return }
                        let restore = owner?.window?.firstResponder === editor
                        finishAccept(ticket: ticket, returnFocus: restore)
                    })
                    guard accepted else { return } // Disabled commands retain the draft.
                    await registry.router.waitForPendingCommands()
                    if wasDelivered || !isPresented { return }
                    // Ordinary commands may retry after publication. Extension commands must
                    // still match the original document/surface on every iteration.
                }

            }
        }
    }

    private func finishAccept(ticket: UUID, returnFocus: Bool) {
        guard presentation == ticket else { return }
        dismiss(returnFocus: false)
        if returnFocus, let owner {
            owner.session.performWindowAction { [weak owner] in
                guard let owner, owner.window?.isKeyWindow == true else { return }
                owner.focusSelectedDocument()
            }
        }
    }

    func dismiss(returnFocus: Bool = true) {
        let wasPresented = isPresented
        view.isHidden = true
        siteSearch = nil
        view.setSiteSearch(nil, animated: false)
        queryTask?.cancel()
        documentTask?.cancel()
        presentationTask?.cancel()
        warmupTask?.cancel()
        acceptTask?.cancel()
        acceptTask = nil
        acceptInvocation = UUID()
        generation = UUID()
        presentation = UUID()
        target = nil
        context = nil
        sourceContext = nil
        candidates = []
        preparedCandidates = []
        history = []
        results = []
        if wasPresented, returnFocus, let owner, owner.window?.isKeyWindow == true {
            let sameOccurrence = owner.session.snapshot?.selectedOccurrenceID == previousOccurrence
            if sameOccurrence, let view = previousResponder as? NSView, view.window === owner.window,
               !view.isHiddenOrHasHiddenAncestor {
                if owner.window?.makeFirstResponder(view) != true { owner.focusSelectedDocument() }
            } else { owner.focusSelectedDocument() }
        }
        previousResponder = nil
        previousOccurrence = nil
    }
}
