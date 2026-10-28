import BrowserCore
import BrowserEngine

enum BrowserSplitCommands {
    private static let layoutSource = "Reconstruction: split layout actions; C19 measures two horizontal panes only"
    // No pane-cycling item or key is declared in 's MainMenu.nib (matrix in
    // docs/shortcuts-orbit-mapping-2026-10-24.md) and E6 app-focused-methods.json lists only add,
    // close, separate, maximize and note Split selectors. That does not rule out a dynamic Orbit
    // binding: the exact shortcut stays unresolved, so these commands ship palette-only.
    private static let cycleSource = "Reconstruction: keyboard pane cycling; Orbit binding unresolved (none declared in MainMenu.nib 1.170.0)"
    // Catalog titles stay English lookup keys. BrowserCommandDefinition.localizedTitle routes
    // them through BrowserText at presentation time, like the other feature catalogs.
    private static let rows: [(BrowserCommandID, String, String)] = [
        (.toggleSplitOrientation, "Change Split Orientation", layoutSource), (.swapSplitPanes, "Swap Split Panes", layoutSource),
        (.unsplitAllPanes, "Separate All Split Pages", layoutSource),
        (.focusNextSplitPane, "Focus Next Split Pane", cycleSource),
        (.focusPreviousSplitPane, "Focus Previous Split Pane", cycleSource)
    ]
    static let definitions: [BrowserCommandDefinition] = rows.map { id, title, source in
        BrowserCommandDefinition(id: id, title: title, menu: "View", shortcuts: [], scope: .browser,
                                 requirement: .surface, owner: "SPLIT", sources: [source])
    }

    @MainActor
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        typealias Controller = BrowserWindowController<Engine>
        func target(_ controller: Controller) -> BrowserOrganizationSplitItem? {
            let nodes = controller.sidebar.contextMenuNodes
            if !nodes.isEmpty {
                guard nodes.count == 1, case let .split(split)? = controller.session.organization?.item(for: nodes[0]) else { return nil }
                return split
            }
            return controller.session.activeSplit
        }
        func group(_ id: BrowserCommandID, _ action: @escaping (Controller, BrowserOrganizationSplitItem) -> Void) {
            try! registry.register(id, validate: { target($0) != nil && !$0.isPeekPresented }) { controller, _ in
                if let split = target(controller) { action(controller, split) }
            }
        }
        for (id, offset) in [(BrowserCommandID.focusNextSplitPane, 1), (.focusPreviousSplitPane, -1)] {
            try! registry.register(id, validate: { $0.canCycleSplitPanes && !$0.isPeekPresented }) { controller, _ in
                controller.focusSplitPane(offset: offset)
            }
        }
        try! registry.register(.addSplitView, validate: { $0.canAddSplitPane && !$0.isPeekPresented }) { [weak registry] controller, _ in
            controller.palette.registry = registry
            controller.addSplitFromSelection()
        }
        group(.closeThisSplitPane) { controller, split in
            if let active = split.activeTab ?? split.tabs.first { controller.session.closeSplitPane(active.id) }
        }
        group(.separatePageFromSplitView) { controller, split in
            if let active = split.activeTab ?? split.tabs.first { controller.session.separateSplitPane(active.id) }
        }
        group(.unsplitAllPanes) { $0.session.unsplit($1.group.id) }
        group(.expandCurrentSplit) { controller, split in
            controller.split.expandedGroup = controller.split.expandedGroup == split.group.id ? nil : split.group.id
            controller.renderSplit()
        }
        group(.toggleSplitOrientation) { controller, split in
            controller.session.orientSplit(split.group.id, to: split.group.orientation == .horizontal ? .vertical : .horizontal)
        }
        group(.swapSplitPanes) { controller, split in
            let active = split.activeTab ?? split.tabs[0]
            let index = split.group.tabIDs.firstIndex(of: active.id)!
            controller.session.swapSplitPanes(split.group.id, first: index, second: (index + 1) % split.tabs.count)
        }
    }
}
