import AppKit
import BrowserCore
import BrowserShell
import QuartzCore

/// Local event routing is limited to the sidebar Space body, never the engine's history-swipe region.
@MainActor
final class SidebarSpaceSwipeController {
    weak var sidebar: BrowserSidebarView?
    var allowsInput: () -> Bool = { true }
    /// The Library owns only the extra page before the first Space.
    var handleLibraryBoundary: ((NSEvent, Bool) -> Bool)?
    var loadDocument: (() async -> BrowserSessionDocument)?
    var resolveTheme: (SpaceID) -> OrbitTokens.SpaceTheme = { _ in .default }
    var onThemeProgress: ((SpaceSwipeThemeBlend?) -> Void)?
    var onRelease: ((SpaceID, SpaceID, BrowserSessionDocument) -> Void)?
    var commit: ((SpaceID, BrowserCatalogSnapshot, SpaceSwipeAdmission, @escaping @MainActor () -> Bool, @escaping @MainActor (Bool) -> Void) -> Void)?
    let scrollInput = SidebarScrollInputRouter()
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var gesture: SpaceSwipeGesture?
    private var catalog: BrowserCatalogSnapshot?
    private var source: SpaceID?
    private var sourceWindow: NSWindow?
    private var size = NSSize.zero
    private var token = UUID()
    private var documentTask: Task<Void, Never>?
    private var document: BrowserSessionDocument?
    private var documentIsStale = false
    private var preparationTask: Task<Void, Never>?
    private var preparationContext: (BrowserCatalogSnapshot, SpaceID)?
    private var preparedDocument: BrowserSessionDocument?
    private var programmaticTarget: SpaceID?
    private var favoritePreviews: [SpaceID: SpaceSwipeFavoritesPreview] = [:]
    private var previewContents: [SpaceID: SidebarListContent] = [:]
    private var link: OrbitCoreVideoMotionDriver?
    private var motionTime: CFTimeInterval?
    private var motion: SidebarSlotMotion?
    private var releaseTarget: SpaceID?
    private var createsSpaceOnSettlement = false
    private(set) var isCreationPageVisible = false
    private var creationSource: SpaceID?
    private var beganOnCreationPage = false
    private var presentsCreation = false
    private var trackingCreationEdge = false
    private var creationEdgeProgress: CGFloat = 0
    private var creationEdgeY: CGFloat = 0
    private var creationConfirmationStart: CFTimeInterval?
    private var creationSettlement: SpaceCreationSettlement?

    /// Commands and overscroll enter the same trailing creation page.
    func presentCreationPage() {
        guard let sidebar, !isCreationPageVisible, let context = sidebar.swipeContext,
              environmentCanBegin(sidebar) else { return }
        cancel()
        source = context.1; catalog = context.0; sourceWindow = sidebar.window
        size = sidebar.bounds.size
        capturedThemes = [context.1: resolveTheme(context.1)]
        presentsCreation = true
        show(offset: 0)
        settle(destination: nil, velocity: 0, createsSpace: true)
    }

    func dismissCreationPage() {
        guard isCreationPageVisible || presentsCreation, let sidebar, let context = sidebar.swipeContext else { return }
        let start = isActive ? offset : -sidebar.swipeWidth
        isCreationPageVisible = true; creationSource = context.1
        cancel(preservePresentation: true)
        source = context.1; catalog = context.0; sourceWindow = sidebar.window
        size = sidebar.bounds.size; offset = start
        beganOnCreationPage = true; presentsCreation = true
        capturedThemes = [context.1: resolveTheme(context.1)]
        sidebar.newSpaceSwipePage?.closePickers()
        settle(destination: nil, velocity: 0)
    }

    func retireCreationPage() {
        isCreationPageVisible = false; creationSource = nil
        cancel()
    }
    private var admission: SpaceSwipeAdmission?
    private var commitDispatched = false
    private var selectionPublished = false
    private var settlementWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextGestureEvents: [(event: NSEvent, inside: Bool)] = []
    private var nextGestureTask: Task<Void, Never>?
    private var inputEpoch = UUID()
    private final class RecognitionAuthority {
        let catalog: BrowserCatalogSnapshot
        var spaceID: SpaceID
        var profileID: ProfileID
        init(catalog: BrowserCatalogSnapshot, spaceID: SpaceID, profileID: ProfileID) {
            self.catalog = catalog; self.spaceID = spaceID; self.profileID = profileID
        }
    }
    private var recognitionAuthority: RecognitionAuthority?
    private var capturedThemes: [SpaceID: OrbitTokens.SpaceTheme] = [:]
    private(set) var offset: CGFloat = 0
    private(set) var isSettling = false
    private var swallowingMomentum = false
    var automaticallyAdvances = true
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() }
    var isActive: Bool { gesture != nil || isSettling }

    /// Keep surface creation, CEF activation, session publication and its layouts out of the
    /// interactive spring. Cancellation releases the command too; its admission is then revoked.
    func waitForSettlement() async {
        guard motion != nil else { return }
        await withCheckedContinuation { settlementWaiters.append($0) }
    }

    private func releaseSettlementWaiters() {
        let waiters = settlementWaiters
        settlementWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func attach(to view: BrowserSidebarView) {
        detach()
        sidebar = view
        guard let window = view.window else { return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didResizeNotification, NSWindow.willBeginSheetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.route(event) == nil }
            return consumed ? nil : event
        }
    }

    func detach() {
        preparationTask?.cancel(); preparationTask = nil; preparationContext = nil
        retireCreationPage()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    func validate(catalog: BrowserCatalogSnapshot?, active: SpaceID?) {
        if isCreationPageVisible, active != creationSource || catalog != sidebar?.swipeContext?.0 {
            retireCreationPage()
        }
        if !isActive, let catalog, let active { prepareNeighbors(catalog: catalog, active: active) }
        if let authority = recognitionAuthority {
            let ownedPublication = isActive && commitDispatched && !selectionPublished
                && active == releaseTarget && source == authority.spaceID
            guard let sidebar, environmentCanBegin(sidebar), catalog == authority.catalog,
                  let active, let profile = catalog?.spaces.first(where: { $0.id == active })?.profileID,
                  (active == authority.spaceID && profile == authority.profileID) || ownedPublication else {
                cancel(); return
            }
            if ownedPublication { authority.spaceID = active; authority.profileID = profile }
        }
        guard isActive else { return }
        // After publication, the old source is an external replacement, not a valid fallback.
        let matchesSelection = selectionPublished ? active == releaseTarget : (active == source || active == releaseTarget)
        if catalog != self.catalog || !matchesSelection || !environmentIsCurrent {
            cancel()
        }
    }

    func layoutChanged() {
        guard isActive || recognitionAuthority != nil, let sidebar else { return }
        if sidebar.bounds.size != size { cancel() }
    }

    /// Construct metadata-only native pages while idle. They stay detached, so neutral and
    /// vertical gestures never expose a second list. Tracking still reads a fresh document.
    private func prepareNeighbors(catalog: BrowserCatalogSnapshot, active: SpaceID) {
        guard let loadDocument,
              preparationContext?.0 != catalog || preparationContext?.1 != active else { return }
        preparationTask?.cancel()
        preparedDocument = nil
        preparationContext = (catalog, active)
        preparationTask = Task { [weak self] in
            let document = await loadDocument()
            guard !Task.isCancelled, let self, !isActive, let sidebar,
                  sidebar.swipeContext?.0 == catalog, sidebar.swipeContext?.1 == active,
                  document.spaces == catalog.spaces else { return }
            self.preparedDocument = document
            SpaceSwipeTrace.interval("SwipePrepareNeighbors") {
                sidebar.prepareSpaceSwipeNeighbors(document: document, active: active, resolveTheme: resolveTheme)
                sidebar.prepareNewSpaceSwipePage()
            }
        }
    }

    /// Footer clicks share the prepainted, display-linked presentation. In particular, CEF
    /// publication waits for its spring instead of blocking the middle of an ordinary slide.
    /// A cold or invalidated preparation falls back to the session's normal activation path.
    @discardableResult
    func switchToSpace(_ target: SpaceID) -> Bool {
        if isCreationPageVisible { retireCreationPage() }
        guard let sidebar, !isActive, environmentCanBegin(sidebar), let context = sidebar.swipeContext,
              let from = context.0.spaces.firstIndex(where: { $0.id == context.1 }),
              let to = context.0.spaces.firstIndex(where: { $0.id == target }), from != to,
              preparationContext?.0 == context.0, preparationContext?.1 == context.1,
              let preparedDocument, preparedDocument.spaces == context.0.spaces else { return false }
        cancel()
        source = context.1
        catalog = context.0
        sourceWindow = sidebar.window
        size = sidebar.bounds.size
        document = preparedDocument
        capturedThemes = Dictionary(uniqueKeysWithValues: context.0.spaces.map { ($0.id, resolveTheme($0.id)) })
        programmaticTarget = target
        // Keep direction at the zero-displacement endpoint without introducing a visible jump.
        offset = to > from ? -0.000001 : 0.000001
        show(offset: offset)
        settle(destination: target, velocity: 0)
        return true
    }

    private var environmentIsCurrent: Bool {
        guard let sidebar, let sourceWindow, sidebar.window === sourceWindow,
              !sidebar.isPresentationHidden, sidebar.bounds.size == size,
              sourceWindow.isKeyWindow, sourceWindow.attachedSheet == nil, NSApp.modalWindow == nil,
              sidebar.swipeCanInteract, allowsInput() else { return false }
        return true
    }

    private func route(_ event: NSEvent) -> NSEvent? {
        var buffered = false
        switch scrollInput.replay(event) {
        case .deliver: return event
        case .recognize: buffered = true
        case .discard: return nil
        case .unrelated: break
        }
        guard let sidebar, event.window === sidebar.window else { return event }
        if event.type == .keyDown, event.keyCode == 53, isCreationPageVisible || presentsCreation,
           (sidebar.window?.firstResponder as? NSTextView)?.hasMarkedText() != true {
            if let page = sidebar.newSpaceSwipePage, page.hasPicker {
                page.closePickers(); page.focusName()
            } else { dismissCreationPage() }
            return nil
        }
        if event.type != .scrollWheel {
            if isActive || scrollInput.hasOwnedSequence || recognitionAuthority != nil { cancel() }
            return event
        }
        guard !event.phase.isEmpty || !event.momentumPhase.isEmpty else { return event }
        if isActive && !environmentIsCurrent { cancel(); return event }
        let inside = sidebar.swipeContains(event.locationInWindow)
        guard inside || isActive || scrollInput.hasOwnedSequence else { return event }
        return arbitrateScroll(event, inside: inside, buffered: buffered) ? nil : event
    }

    /// Production arbitration boundary: reserve pending input, then either own horizontal
    /// motion or replay the original stream to AppKit's native vertical scrolling path.
    func routeScroll(_ event: NSEvent, inside: Bool) -> Bool {
        switch scrollInput.replay(event) {
        case .deliver: return false
        case .discard: return true
        case .recognize: return arbitrateScroll(event, inside: inside, buffered: true)
        case .unrelated: return arbitrateScroll(event, inside: inside)
        }
    }

    private func arbitrateScroll(_ event: NSEvent, inside: Bool, buffered: Bool = false) -> Bool {
        guard event.hasPreciseScrollingDeltas,
              !event.phase.isEmpty || !event.momentumPhase.isEmpty else { return false }
        if event.phase.contains(.began), !buffered {
            scrollInput.retireConsumedRecognition()
            recognitionAuthority = nil
        }
        if !inside, event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            cancel()
            scrollInput.releaseUnownedSequence()
            swallowingMomentum = false
            return false
        }
        return scrollInput.route(event, inside: inside, captureOwner: { [weak self] in
            guard let self, let sidebar, environmentCanBegin(sidebar),
                  let window = sidebar.window, let context = sidebar.swipeContext else { return nil }
            let page = sidebar.page
            let size = sidebar.bounds.size
            return { [weak self, weak sidebar, weak window, weak page] in
                guard let self, let sidebar, let window, let page else { return false }
                return sidebar.window === window && sidebar.page === page && sidebar.bounds.size == size
                    && sidebar.swipeContext?.0 == context.0 && sidebar.swipeContext?.1 == context.1
                    && !sidebar.isPresentationHidden && environmentCanBegin(sidebar)
            }
        }, recognize: { [weak self] in
            guard let self else { return .inactive }
            let consumed = handleScroll(event, inside: inside)
            if consumed || isSettling { return .horizontal }
            return gesture?.intent == .pending ? .pending : .inactive
        }, cancelRecognition: { [weak self] in self?.cancel(preserveScrollInput: true) })
    }

    /// The monitor and synthetic phased-event tests share this handler after window hit testing.
    func handleScroll(_ event: NSEvent, inside: Bool) -> Bool {
        guard !event.phase.isEmpty || !event.momentumPhase.isEmpty else { return false }
        if !isCreationPageVisible, !presentsCreation, handleLibraryBoundary?(event, inside) == true { return true }
        guard let sidebar, event.hasPreciseScrollingDeltas else { return false }
        SpaceSwipeTrace.input(phase: event.phase.rawValue, momentum: event.momentumPhase.rawValue, deltaX: event.scrollingDeltaX)
        if isActive && !environmentIsCurrent { cancel(); return false }
        // While activation is deliberately waiting for our spring, another contact can take
        // that still-unadmitted presentation back immediately. Once the store admits it, the
        // existing ordered replay below preserves the committed destination instead.
        if event.phase.contains(.began), inside, !settlementWaiters.isEmpty,
           admission?.revoke() == true {
            commitDispatched = false
        }
        // A new physical stream is ordered after this release's actual publication. Retain
        // every phase instead of losing its Began while the store command is still in flight.
        if !nextGestureEvents.isEmpty || (commitDispatched && !selectionPublished && event.phase.contains(.began)) {
            guard nextGestureEvents.count < SidebarScrollInputRouter.maximumPendingEvents else {
                cancel(); return true
            }
            nextGestureEvents.append((event, inside))
            if selectionPublished || !commitDispatched { scheduleNextGesture() }
            return true
        }
        if !event.momentumPhase.isEmpty {
            let consumed = swallowingMomentum
            if event.momentumPhase.contains(.ended) { swallowingMomentum = false }
            return consumed
        }
        if event.phase.contains(.began) {
            // Retake the last position submitted to AppKit. The analytic spring can be
            // ahead of the last display callback, especially while publication does work.
            // Sampling its future value here turns a zero-delta Began into a visible jump.
            swallowingMomentum = false
            guard environmentCanBegin(sidebar), inside,
                  let context = sidebar.swipeContext else { return false }
            let retained = isSettling ? (creationSettlement?.state(at: motionTime ?? clock()) ?? motion?.state(at: motionTime ?? clock())) : nil
            let retainedOffset = isSettling ? offset : nil
            let retainedDocument = document
            let retainedThemes = capturedThemes
            let published = selectionPublished
            let rebased = published ? sidebar.rebaseSpaceSwipeForRetake() : nil
            cancel(preservePresentation: retained != nil, preserveScrollInput: true)
            capturedThemes = retained == nil ? Dictionary(uniqueKeysWithValues: context.0.spaces.map { ($0.id, resolveTheme($0.id)) }) : retainedThemes
            source = context.1
            catalog = context.0
            sourceWindow = sidebar.window
            size = sidebar.bounds.size
            beganOnCreationPage = isCreationPageVisible || (retainedOffset != nil && sidebar.newSpaceSwipePage != nil)
            creationEdgeY = sidebar.convert(event.locationInWindow, from: nil).y
            presentsCreation = beganOnCreationPage || (retainedOffset != nil && sidebar.newSpaceSwipePage != nil)
            let presentationOffset = rebased ?? retainedOffset ?? (beganOnCreationPage ? -sidebar.swipeWidth : 0)
            offset = presentationOffset
            gesture = SpaceSwipeGesture(displacement: Double(presentationOffset + (beganOnCreationPage ? sidebar.swipeWidth : 0)), velocity: retained?.velocity ?? 0)
            // Metadata already prepared while idle must be available to the first contact
            // and to a fast release, before the actor's fresh read has a chance to complete.
            document = retainedDocument ?? (preparationContext?.0 == context.0 && preparationContext?.1 == context.1 ? preparedDocument : nil)
            let identity = token
            documentTask = Task { [weak self] in
                guard let self, let loadDocument else { return }
                let signposter = SpaceSwipeTrace.signposter
                let load = signposter.isEnabled
                    ? signposter.beginInterval("SwipeDocumentLoad", id: signposter.makeSignpostID()) : nil
                let document = await loadDocument()
                if let load { signposter.endInterval("SwipeDocumentLoad", load) }
                guard self.token == identity, self.isActive, self.environmentIsCurrent else { return }
                guard document.spaces == self.catalog?.spaces else {
                    self.documentIsStale = true
                    return
                }
                self.document = document
                self.previewContents.removeAll()
                self.favoritePreviews.removeAll()
                if self.isSettling { self.show(offset: self.offset) } else { self.draw() }
            }
        }
        guard var gesture, !isSettling else { return isSettling && swallowingMomentum }
        // Orbit's pager initializes on Began and consumes displacement only on Changed
        // . Keep raw vectors for axis arbitration.
        gesture.update(x: event.scrollingDeltaX, y: event.scrollingDeltaY, time: event.timestamp,
                       translationScale: event.phase.contains(.changed) ? OrbitTokens.Motion.spaceSwipeScrollScale : 0)
        self.gesture = gesture
        if gesture.intent == .vertical {
            cancel(preserveScrollInput: true)
            return false
        }
        let horizontal = gesture.intent == .horizontal
        if horizontal { swallowingMomentum = true; draw() }
        if event.phase.contains(.cancelled) || event.phase.contains(.ended), !horizontal {
            if offset != 0 { settle(destination: nil, velocity: 0, createsSpace: beganOnCreationPage) }
            else { cancel(preserveScrollInput: true) }
            return false
        }
        if beganOnCreationPage, event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let back = !event.phase.contains(.cancelled) && gesture.destination(width: Double(sidebar.swipeWidth),
                hasPrevious: true, hasNext: false, at: event.timestamp) == -1
            settle(destination: nil, velocity: gesture.releaseVelocity(at: event.timestamp), createsSpace: !back)
        } else if event.phase.contains(.cancelled) {
            settle(destination: nil, velocity: 0)
        } else if event.phase.contains(.ended) {
            let neighbors = neighbors()
            let direction = gesture.destination(width: Double(sidebar.swipeWidth), hasPrevious: neighbors.0 != nil,
                                                hasNext: neighbors.1 != nil || canCreateNextSpace, at: event.timestamp)
            let target = direction.map { $0 < 0 ? neighbors.0 : neighbors.1 } ?? nil
            // Paint metadata can arrive late; the store still atomically validates the
            // captured catalog and context when admitting the selection.
            settle(destination: documentIsStale ? nil : target, velocity: gesture.releaseVelocity(at: event.timestamp),
                   createsSpace: !documentIsStale && direction == 1 && neighbors.1 == nil && canCreateNextSpace)
        }
        return horizontal
    }

    private func environmentCanBegin(_ sidebar: BrowserSidebarView) -> Bool {
        sidebar.swipeCanInteract && allowsInput() && sidebar.window?.isKeyWindow == true && sidebar.window?.attachedSheet == nil && NSApp.modalWindow == nil
    }

    private func neighbors() -> (SpaceID?, SpaceID?) {
        guard let spaces = catalog?.spaces, let index = spaces.firstIndex(where: { $0.id == source }) else { return (nil, nil) }
        return (index > 0 ? spaces[index - 1].id : nil, index + 1 < spaces.count ? spaces[index + 1].id : nil)
    }

    private var canCreateNextSpace: Bool {
        guard let spaces = catalog?.spaces, let source else { return false }
        return spaces.last?.id == source && sidebar?.onNewSpace != nil
    }

    private func draw() {
        guard let sidebar, let gesture, gesture.intent == .horizontal else { return }
        if beganOnCreationPage {
            offset = -sidebar.swipeWidth + CGFloat(gesture.offset(width: Double(sidebar.swipeWidth), hasPrevious: true, hasNext: false))
            show(offset: offset)
            return
        }
        let adjacent = neighbors()
        if !presentsCreation, adjacent.1 == nil, canCreateNextSpace, gesture.displacement < 0 {
            trackingCreationEdge = true
            creationEdgeProgress = SpaceCreationMotion.edgeProgress(displacement: CGFloat(gesture.displacement), width: sidebar.swipeWidth)
            offset = SpaceCreationMotion.edgeOffset(displacement: CGFloat(gesture.displacement))
            sidebar.showNewSpaceEdge(offset: offset, progress: creationEdgeProgress, at: creationEdgeY)
            return
        }
        trackingCreationEdge = false
        offset = CGFloat(gesture.offset(width: Double(sidebar.swipeWidth), hasPrevious: adjacent.0 != nil,
                                       hasNext: adjacent.1 != nil || canCreateNextSpace))
        show(offset: offset)
    }

    private func show(offset: CGFloat) {
        SpaceSwipeTrace.interval("SwipeFrame") { present(offset: offset) }
    }

    private func present(offset: CGFloat) {
        guard let sidebar else { return }
        let adjacent = neighbors()
        if trackingCreationEdge {
            let fraction = creationConfirmationStart.map { min(1, max(0, ((motionTime ?? clock()) - $0) / SpaceCreationMotion.confirmationDuration)) } ?? 0
            sidebar.showNewSpaceEdge(offset: offset, progress: creationEdgeProgress, at: creationEdgeY, confirmation: fraction)
            return
        }
        if presentsCreation || (offset < 0 && programmaticTarget == nil && adjacent.1 == nil && canCreateNextSpace) {
            presentsCreation = true
            if let source, let theme = capturedThemes[source] {
                let destination = sidebar.newSpaceSwipePage.map { OrbitSpaceThemes.rendered($0.theme) } ?? OrbitSpaceThemes.rendered(BrowserSpaceThemePresets.default)
                onThemeProgress?(.init(source: theme, destination: destination, progress: abs(offset) / max(1, sidebar.swipeWidth)))
            }
            sidebar.showNewSpaceSwipe(offset: offset)
            if beganOnCreationPage, !createsSpaceOnSettlement, offset > -60 {
                sidebar.showNewSpaceEdge(offset: offset, progress: 1, at: creationEdgeY, confirmation: 1)
            }
            return
        }
        let target = programmaticTarget ?? (offset > 0 ? adjacent.0 : adjacent.1)
        let space = catalog?.spaces.first { $0.id == target }
        var content: SidebarListContent?
        if let target, let document {
            if previewContents[target] == nil {
                previewContents[target] = SpaceSwipeTrace.interval("SwipePreviewContent") {
                    SpaceSwipePreview.content(document: document, spaceID: target, windowID: sidebar.organization?.windowID, icon: sidebar.previewIcon)
                }
            }
            content = previewContents[target]
        }
        if let target, favoritePreviews[target] == nil, let document {
            favoritePreviews[target] = SpaceSwipePreview.favorites(document: document, spaceID: target, windowID: sidebar.organization?.windowID, icon: sidebar.previewIcon)
        }
        let destinationTheme = target.flatMap { capturedThemes[$0] }
        if let source, let sourceTheme = capturedThemes[source] {
            // Click settlement and contact tracking share Orbit's pager-driven paint input.
            // Theme publication does not wait for selection admission or a progress threshold.
            // Reversing past an edge must replace the preceding valid-neighbor blend.
            SpaceSwipeTrace.interval("SwipeThemeBlend") {
                onThemeProgress?(.init(source: sourceTheme, destination: destinationTheme ?? sourceTheme,
                                       progress: destinationTheme == nil ? 0 : abs(offset) / max(1, sidebar.swipeWidth)))
            }
        }
        SpaceSwipeTrace.interval("SwipeSidebarLayout") {
            sidebar.showSpaceSwipe(offset: offset, space: space, content: content,
                                   destinationAccent: destinationTheme.map { OrbitSpaceThemes.accent(for: $0) },
                                   favorites: target.flatMap { favoritePreviews[$0] })
        }
    }

    private func settle(destination: SpaceID?, velocity: Double, createsSpace: Bool = false) {
        guard let sidebar else { cancel(); return }
        createsSpaceOnSettlement = createsSpace
        releaseTarget = destination
        isSettling = true
        let end: CGFloat = createsSpace ? -sidebar.swipeWidth : destination == nil ? 0 : (offset > 0 ? sidebar.swipeWidth : -sidebar.swipeWidth)
        motionTime = clock()
        let confirmsEdge = trackingCreationEdge && createsSpace
        creationConfirmationStart = confirmsEdge ? motionTime : nil
        let start = motionTime! + (confirmsEdge ? SpaceCreationMotion.confirmationDuration : 0)
        motion = SidebarSlotMotion(from: offset, to: end, at: start,
                                   spring: presentsCreation || trackingCreationEdge ? SpaceCreationMotion.spring : OrbitTokens.Motion.spaceSwitchSidebar,
                                   velocity: trackingCreationEdge ? 0 : velocity)
        if createsSpace || beganOnCreationPage {
            creationSettlement = SpaceCreationSettlement(from: offset, target: end, start: start)
        }
        if confirmsEdge { creationEdgeProgress = 1 }
        // Only an explicit ended event reaches a non-nil destination. Dispatch before settlement.
        if let destination, !commitDispatched, let catalog {
            if let source, let document { onRelease?(source, destination, document) }
            commitDispatched = true
            let identity = token
            let admission = SpaceSwipeAdmission()
            self.admission = admission
            guard let commit else { fallbackFromRefusal(); return }
            // Events, not an interval: the completion may report more than once.
            if SpaceSwipeTrace.signposter.isEnabled {
                SpaceSwipeTrace.signposter.emitEvent("SwipeCommitDispatch")
            }
            commit(destination, catalog, admission, { [weak self] in
                self?.token == identity && self?.environmentIsCurrent == true
            }, { [weak self] accepted in
                if SpaceSwipeTrace.signposter.isEnabled {
                    SpaceSwipeTrace.signposter.emitEvent("SwipeCommitResult", "accepted \(accepted)")
                }
                guard let self, self.token == identity else { return }
                if !accepted { self.fallbackFromRefusal() }
            })
        }
        guard isSettling else { return }
        if OrbitMotionPreferences.prefersReducedMotion || sidebar.window?.isVisible != true {
            trackingCreationEdge = false
            offset = end
            show(offset: end)
            completeSettlement()
            return
        }
        startDisplayLink(in: sidebar)
    }

    private func startDisplayLink(in sidebar: BrowserSidebarView) {
        guard automaticallyAdvances else { return }
        link?.stop()
        let link = OrbitCoreVideoMotionDriver(time: motionTime ?? clock())
        link.onFrame = { [weak self, weak link] in
            guard let self, let link else { return }
            let creation = self.presentsCreation || self.trackingCreationEdge || self.beganOnCreationPage
            _ = self.advance(to: creation ? self.clock() + SpaceCreationMotion.presentationLead : link.time)
        }
        self.link = link
        if !link.start() {
            offset = motion?.target ?? offset
            show(offset: offset)
            completeSettlement()
        }
    }

    private func fallbackFromRefusal() {
        if selectionPublished { cancel(); return }
        admission?.revoke()
        admission = nil
        commitDispatched = false
        releaseTarget = nil
        settle(destination: nil, velocity: 0)
        if !nextGestureEvents.isEmpty { scheduleNextGesture() }
    }

    @discardableResult
    func advance(to time: CFTimeInterval) -> Bool {
        guard environmentIsCurrent, let motion else { cancel(); return false }
        motionTime = time
        if let start = creationConfirmationStart {
            if time < start + SpaceCreationMotion.confirmationDuration {
                show(offset: offset); return true
            }
            trackingCreationEdge = false
            presentsCreation = true
        }
        offset = OrbitMotionPreferences.prefersReducedMotion ? motion.target : (creationSettlement?.state(at: time).value ?? motion.value(at: time))
        if trackingCreationEdge, !createsSpaceOnSettlement {
            creationEdgeProgress = max(0, min(creationEdgeProgress, abs(offset) / 18))
        }
        show(offset: offset)
        if OrbitMotionPreferences.prefersReducedMotion || (creationSettlement?.isSettled(at: time) ?? motion.isSettled(at: time)) {
            completeSettlement(); return false
        }
        return true
    }

    private func completeSettlement() {
        link?.stop(); link = nil; motion = nil; motionTime = nil; creationSettlement = nil
        releaseSettlementWaiters()
        if createsSpaceOnSettlement {
            isCreationPageVisible = true
            creationSource = source
            cancel(preservePresentation: true)
            sidebar?.showNewSpaceSwipe(offset: -(sidebar?.swipeWidth ?? 0))
            sidebar?.settleNewSpacePage()
            return
        }
        if beganOnCreationPage {
            isCreationPageVisible = false; creationSource = nil
            sidebar?.newSpaceSwipePage?.closePickers()
        }
        if releaseTarget == nil || selectionPublished {
            if nextGestureEvents.isEmpty { cancel(preserveQueuedReplay: true) }
            else { scheduleNextGesture() }
        }
        // Selection is already dispatched. A late publication must adopt without a second slide.
    }

    /// Publish the destination's live rows while preserving both list presentation transforms.
    func willRender(active: SpaceID?) -> Bool {
        guard isSettling, commitDispatched, let target = releaseTarget, active == target else { return false }
        if !selectionPublished {
            SpaceSwipeTrace.interval("SwipeAdoptDestination") { sidebar?.adoptSpaceSwipeDestination(target) }
            selectionPublished = true
        }
        if !nextGestureEvents.isEmpty { scheduleNextGesture() }
        else if motion == nil { cancel(preserveQueuedReplay: true) }
        return true
    }

    private func scheduleNextGesture() {
        guard nextGestureTask == nil, !nextGestureEvents.isEmpty,
              selectionPublished || !commitDispatched else { return }
        // Bind synchronously to this predecessor's result. Reading the current sidebar after
        // yielding could authorize an unrelated publication that replaced that result.
        guard let catalog, let expected = selectionPublished ? releaseTarget : source,
              let profile = catalog.spaces.first(where: { $0.id == expected })?.profileID else { cancel(); return }
        let authority = recognitionAuthority ?? RecognitionAuthority(catalog: catalog, spaceID: expected, profileID: profile)
        authority.spaceID = expected
        authority.profileID = profile
        recognitionAuthority = authority
        let identity = token
        nextGestureTask = Task { [weak self] in
            await Task.yield()
            guard let self, self.token == identity else { return }
            self.nextGestureTask = nil
            guard self.environmentIsCurrent, self.selectionPublished || !self.commitDispatched,
                  let sidebar = self.sidebar, let window = sidebar.window,
                  sidebar.swipeContext?.0 == authority.catalog,
                  sidebar.swipeContext?.1 == authority.spaceID else { self.cancel(); return }
            let events = self.nextGestureEvents.map(\.event)
            self.nextGestureEvents.removeAll()
            let epoch = self.inputEpoch
            let size = sidebar.bounds.size
            let replayed = self.scrollInput.replayForRecognition(events, isCurrent: { [weak self, weak sidebar, weak window] in
                guard let self, let sidebar, let window else { return false }
                return self.inputEpoch == epoch && sidebar.window === window && sidebar.bounds.size == size
                    && sidebar.swipeContext?.0 == authority.catalog && sidebar.swipeContext?.1 == authority.spaceID
                    && sidebar.swipeContext?.0.spaces.first(where: { $0.id == authority.spaceID })?.profileID == authority.profileID
                    && !sidebar.isPresentationHidden
                    && self.environmentCanBegin(sidebar)
            })
            if !replayed { self.cancel(); return }
            if self.motion == nil { self.cancel(preserveQueuedReplay: true) }
        }
    }

    func cancel(preservePresentation: Bool = false, preserveScrollInput: Bool = false, preserveQueuedReplay: Bool = false) {
        let internalRetirement = preserveScrollInput || preserveQueuedReplay
        if !internalRetirement { inputEpoch = UUID(); recognitionAuthority = nil }
        if !preserveScrollInput { scrollInput.invalidate(preserveRecognition: preserveQueuedReplay) }
        nextGestureTask?.cancel(); nextGestureTask = nil
        nextGestureEvents.removeAll()
        admission?.revoke(); admission = nil
        token = UUID()
        documentTask?.cancel(); documentTask = nil; document = nil; previewContents.removeAll(); favoritePreviews.removeAll()
        documentIsStale = false
        link?.stop(); link = nil; motion = nil; motionTime = nil; creationSettlement = nil
        gesture = nil; isSettling = false; releaseTarget = nil
        createsSpaceOnSettlement = false
        beganOnCreationPage = false; presentsCreation = false
        trackingCreationEdge = false; creationEdgeProgress = 0; creationConfirmationStart = nil
        programmaticTarget = nil
        sourceWindow = nil; source = nil; catalog = nil; offset = 0
        commitDispatched = false; selectionPublished = false; capturedThemes.removeAll()
        releaseSettlementWaiters()
        if !preservePresentation {
            if isCreationPageVisible {
                sidebar?.showNewSpaceSwipe(offset: -(sidebar?.swipeWidth ?? 0))
            } else {
                sidebar?.finishSpaceSwipe(committed: nil)
                onThemeProgress?(nil)
            }
        }
    }
}
