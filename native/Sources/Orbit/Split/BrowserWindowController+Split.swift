import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

@MainActor
final class BrowserSplitPresentation {
    enum Key: Equatable {
        case single(ObjectIdentifier)
        case group(SplitGroupID)
    }

    private(set) var view = BrowserSplitView(frame: .zero)
    private var key: Key?
    var expandedGroup: SplitGroupID?
    var sharingPicker: NSSharingServicePicker?

    /// A complete outgoing wrapper can be retained by the content card while the engine paints.
    /// Intra-group focus keeps the existing wrapper, so no live pane changes its native parent.
    func presentation(for key: Key, configure: (BrowserSplitView) -> Void) -> BrowserSplitView {
        guard self.key != key else { return view }
        view.suspendInteraction()
        view = BrowserSplitView(frame: .zero)
        self.key = key
        configure(view)
        return view
    }

    func clear() {
        key = nil
        view.suspendInteraction()
    }
}

extension BrowserWindowController {
    func installSplit() {
        configureSplitView(split.view)
        peek.splitHandoff = { [weak self] transfer in
            guard let self, acceptsCommands, !session.hasPendingCommands,
                  engine.capabilities.contains(.liveSurfaceTransfer),
                  let selected = session.organization?.selectedTab,
                  selected.section != .favorites(session.activeProfileID!),
                  (session.activeSplit?.tabs.count ?? 1) < BrowserSplitGroup.maximumPanes,
                  transfer.profileID == session.activeProfileID else { return nil }
            let adoption = session.acceptSplitTransfer(transfer, bind: { [weak self] in self?.bindSurface($0) })
            if transfer.state != .pending { reconcileTransferredSurface(transfer.surface, after: adoption) }
            return adoption
        }
    }

    private func configureSplitView(_ view: BrowserSplitView) {
        view.onFocus = { [weak self] id in
            guard let self, acceptsCommands else { return }
            submitInput { controller in
                controller.session.selectTab(id)
                controller.session.performWindowAction { [weak controller] in controller?.focusSelectedDocument() }
            }
        }
        view.onNavigate = { [weak self] id, action in
            self?.submitInput { controller in
                guard let occurrence = controller.session.organization?.tab(id)?.occurrenceID,
                      let surface = controller.session.surface(for: occurrence) else { return }
                controller.session.selectTab(id)
                controller.session.performWindowAction { [weak controller, weak surface] in
                    guard let controller, let surface, controller.owns(surface) else { return }
                    switch action {
                    case .back:
                        if let url = surface.goBack() { controller.session.updateDestination(for: surface, to: url) }
                    case .forward:
                        if let url = surface.goForward() { controller.session.updateDestination(for: surface, to: url) }
                    case .reload: surface.reload()
                    case .address: controller.focusAddress()
                    case .siteControls:
                        guard controller.session.selectedSurface === surface,
                              let pane = controller.split.view.panes[id] else { return }
                        controller.siteControls.toggle(presentationAnchor: pane.siteControls)
                    case .menu:
                        guard controller.session.selectedSurface === surface,
                              let pane = controller.split.view.panes[id] else { return }
                        let menu = controller.makeSplitPaneMenu(id)
                        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: pane.splitToggle.bounds.height), in: pane.splitToggle)
                    }
                }
            }
        }
        view.onClose = { [weak self] id in self?.submitInput { $0.session.closeSplitPane(id) } }
        view.canDrop = { [weak self] payload in self?.canDropIntoSplit(payload) ?? false }
        view.onDrop = { [weak self] payload, orientation, leading in
            self?.submitInput { $0.dropIntoSplit(payload, orientation: orientation, leading: leading) }
        }
    }

    func renderSplit(retainingPreviousUntil capture: Task<Void, Never>? = nil) {
        let selected = session.selectedSurface
        for id in session.visibleOccurrenceIDs {
            if let surface = session.surface(for: id) { tabSuspension.prepareCover(for: surface) }
        }
        contentCard.splitTheme = windowShell.theme
        if let group = session.activeSplit, split.expandedGroup != group.group.id || selected == nil {
            let view = split.presentation(for: .group(group.group.id), configure: configureSplitView)
            // Every member keeps its slot: a member without a live surface here (in transit, not
            // yet loaded, open in another window) shows a placeholder instead of leaving a hole.
            let panes = group.tabs.map { tab -> BrowserSplitView.Pane in
                let surface = tab.occurrenceID.flatMap { session.surface(for: $0) }
                return .init(id: tab.id, view: surface?.hostView,
                             address: surface?.navigationState.url?.absoluteString ?? tab.url.absoluteString,
                             title: tab.title ?? surface?.navigationState.title,
                             isOpenInAnotherWindow: surface == nil && tab.isOpenInAnotherWindow,
                             canGoBack: surface?.navigationState.canGoBack ?? false,
                             canGoForward: surface?.navigationState.canGoForward ?? false)
            }
            let context = session.splitCommandContext
            view.onResize = { [weak self] ratios in
                self?.submitInput { $0.session.resizeSplit(group.group.id, ratios: ratios, validating: context, expectedGroup: group.group) }
            }
            view.present(group.group, panes: panes, active: group.activeTab?.id,
                               accent: OrbitSpaceThemes.accent(for: windowShell.theme))
            contentCard.present(view, isSplit: true, retainingPreviousUntil: capture)
        } else if let selected {
            if session.activeSplit == nil { split.expandedGroup = nil }
            let view = split.presentation(for: .single(ObjectIdentifier(selected)), configure: configureSplitView)
            contentCard.present(view, retainingPreviousUntil: capture)
            // Give the destination a window and its final geometry before moving the live host.
            // An off-window, zero-sized intermediate parent hides the native compositor.
            contentCard.layoutSubtreeIfNeeded()
            view.presentSingle(selected.hostView)
        } else {
            split.clear()
            contentCard.present(nil, retainingPreviousUntil: capture)
        }
    }

    var canAddSplitPane: Bool {
        guard let selected = session.organization?.selectedTab else { return false }
        if case .favorites = selected.section { return false }
        return (session.activeSplit?.tabs.count ?? 1) < BrowserSplitGroup.maximumPanes
    }

    func refuseSplitRename() { BrowserSplitFeedback.refuseRename(window) }

    var canCycleSplitPanes: Bool { (session.activeSplit?.tabs.count ?? 0) > 1 }

    /// Moves focus to the neighbouring pane in layout order, wrapping around, like a pane click.
    func focusSplitPane(offset: Int) {
        guard acceptsCommands, let split = session.activeSplit, split.tabs.count > 1 else { return }
        let ids = split.group.tabIDs
        let current = split.activeTab.flatMap { ids.firstIndex(of: $0.id) } ?? 0
        let target = ids[((current + offset) % ids.count + ids.count) % ids.count]
        session.selectTab(target)
        session.performWindowAction { [weak self] in self?.focusSelectedDocument() }
    }

    func addSplitFromSelection(at index: Int? = nil) {
        guard acceptsCommands, canAddSplitPane else { return }
        let ids = sidebar.selection.orderedNodes(in: session.organization!).compactMap(\.tabID)
        if ids.count >= 2 { session.createSplit(ids) }
        else {
            session.addSplitPane(at: index)
            session.performWindowAction { [weak self] in
                guard let self, session.activeSplit != nil,
                      session.organization?.selectedTab?.url.absoluteString == "about:blank" else { return }
                palette.present(.currentTab, emptyAddress: true)
            }
        }
    }

    func canDropIntoSplit(_ payload: SidebarDragPayload) -> Bool {
        guard acceptsCommands, let organization = session.organization, let selected = organization.selectedTab,
              payload.sourceWindow == id, payload.profileID == organization.profileID,
              payload.spaceID == organization.spaceID, payload.nodes.count == 1,
              let tabID = payload.nodes.first?.tabID, tabID != selected.id,
              let tab = organization.tab(tabID), tab.section == selected.section,
              organization.split(containing: tabID) == nil else { return false }
        if case .favorites = selected.section { return false }
        return (session.activeSplit?.tabs.count ?? 1) < BrowserSplitGroup.maximumPanes
    }

    func dropIntoSplit(_ payload: SidebarDragPayload, orientation: BrowserSplitOrientation, leading: Bool) {
        guard canDropIntoSplit(payload), let tab = payload.nodes.first?.tabID,
              let selected = session.organization?.selectedTab else { return }
        if let group = session.activeSplit {
            session.addSplitPane(tab, to: group.group.id, at: leading ? 0 : group.tabs.count, orientation: orientation)
        } else { session.createSplit(leading ? [tab, selected.id] : [selected.id, tab], orientation: orientation) }
    }
}


extension BrowserWindowController {
    /// A group is never split into independent single-tab adoptions. The receiver keeps one
    /// provisional event holder per live document until the shared model transaction resolves.
    func moveSplitGroup(_ group: BrowserSplitGroup, to destination: BrowserWindowController, activate: Bool = true) -> Task<[TabOccurrenceID]?, Never>? {
        guard destination !== self, destination.engine === engine,
              engine.capabilities.contains(.liveSurfaceTransfer), acceptsCommands, destination.acceptsCommands,
              session.activeProfileID == destination.session.activeProfileID else { return nil }
        let surfaces = group.tabIDs.compactMap { id -> Surface? in
            guard let occurrence = session.organization?.tab(id)?.occurrenceID else { return nil }
            return session.surface(for: occurrence)
        }
        guard surfaces.count == group.tabIDs.count,
              let destinationWindowID = destination.prepareEngineMove(surfaces) else { return nil }  // All or none.
        let selected = session.organization?.selectedTab?.id
        let focus = selected.flatMap { group.tabIDs.contains($0) ? $0 : nil } ?? group.tabIDs.first
        guard let transfers = session.releaseSurfaces(surfaces, rebind: { [weak self] in self?.bindSurface($0) }) else {
            engine.shellDidFinishMovingSurfaces(surfaces, toWindow: destinationWindowID, committed: false)
            return nil
        }
        surfaces.forEach { surfaceDidLeave($0) }
        let adoption = destination.session.acceptSplitGroupTransfers(transfers, group: group,
            activating: activate ? focus : nil, bind: { [weak destination] in destination?.bindSurface($0) })
        for (index, surface) in surfaces.enumerated() {
            let member = Task<TabOccurrenceID?, Never> {
                guard let ids = await adoption.value, ids.indices.contains(index) else { return nil }
                return ids[index]
            }
            destination.reconcileTransferredSurface(surface, after: member)
        }
        settleEngineMove(surfaces, toWindow: destinationWindowID, after: adoption) { $0 != nil }
        return adoption
    }
}

@MainActor
enum BrowserSplitFeedback {
    /// Replaceable by hidden tests, which must stay silent.
    static var refuseRename: (NSWindow?) -> Void = { window in
        NSSound.beep()
        guard let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: BrowserSplitStrings.groupRenameRefused,
            .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
