import AppKit
import BrowserCore
import BrowserEngine
import Combine
import BrowserShell
import SwiftUI

/// CMD deliberately leaves standard shortcuts to auxiliary key windows. Handle native Close
/// here, before the browser menu's Archive Tab equivalent, without a second event monitor.
@MainActor
final class BrowserSettingsWindow: OrbitDaylightWindow {
    var selectCategory: ((BrowserSettingsSection) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let recorder = firstResponder as? BrowserShortcutRecorderView, recorder.isRecording { return recorder.record(event) }
        let composing = (firstResponder as? NSTextInputClient)?.hasMarkedText() == true
        if attachedSheet == nil,
           BrowserShortcut.input(event, isComposing: composing) == BrowserShortcut(key: "w", modifiers: .command) {
            performClose(nil)
            return true
        }
        if attachedSheet == nil, let shortcut = BrowserShortcut.input(event, isComposing: composing),
           shortcut.modifiers == .command, let index = Int(shortcut.key),
           (1...BrowserSettingsSection.allCases.count).contains(index),
           selectCategory?(BrowserSettingsSection.allCases[index - 1]) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class BrowserSettingsWindowController<Engine: BrowserEngine>: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let model: BrowserSettingsModel<Engine>
    private var sectionObservation: AnyCancellable?
    private var displayedSection: BrowserSettingsSection?
    private let selectionPill = BrowserSettingsSelectionPill()
    private var outgoingPane: CALayer?
    private var paneTransitionGeneration = 0
    static var minimumContentSize: NSSize { NSSize(width: 900, height: 400) }

    /// The theme editor opened from the Spaces section.
    var themeEditor: OrbitThemeEditorController?
    let themeUndoManager = OrbitThemeUndoManager()

    private func chooseDownloadFolder() {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.appearance = NSAppearance(named: .aqua)
        panel.title = uiText("Save downloads to")
        panel.prompt = uiText("Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.runtime.document.downloads.folderURL
        panel.beginSheetModal(for: window) { [weak model] response in
            guard response == .OK, let path = panel.url?.path, let model else { return }
            model.perform { try await model.runtime.updateDownloads { $0.folderPath = path } }
        }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { themeUndoManager }

    init(model: BrowserSettingsModel<Engine>, appearanceOverride: NSAppearance.Name? = OrbitAppearance.launchOverride) {
        self.model = model
        let window = BrowserSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = (model.settingsSection ?? .general).title
        window.titleVisibility = .hidden
        window.appearance = OrbitAppearance.windowAppearance(for: .automatic, override: appearanceOverride)
        window.identifier = NSUserInterfaceItemIdentifier("orbit-settings")
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minimumContentSize
        window.toolbarStyle = .preference
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.backgroundColor = OrbitSettingsStyle.toolbarColor
        window.isOpaque = true
        window.isMovableByWindowBackground = false
        window.contentViewController = NSHostingController(rootView: BrowserSettingsView(model: model, runtime: model.runtime))
        super.init(window: window)
        themeUndoManager.registry = model.environment.themeEditors
        model.chooseDownloadFolder = { [weak self] in self?.chooseDownloadFolder() }
        window.delegate = self
        let toolbar = NSToolbar(identifier: "orbit-settings-categories")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        // Categories live in the persistent sidebar. Keep the toolbar delegate for menu routing.
        window.toolbar = nil
        window.selectCategory = { [weak self] section in self?.selectSection(section) ?? false }
        model.selectSettingsSection = { [weak self] section in self?.selectSection(section) ?? false }
        // Keep the hosting view alive: catalog publications must not recreate drafts or IME editors.
        sectionObservation = model.$settingsSection.sink { [weak self] section in
            // @Published delivers before storing the value. Resizing can run AppKit's nested
            // display loop; defer that work so SwiftUI never consumes the old pane's value.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.model.settingsSection == section,
                      self.displayedSection != (section ?? .general) else { return }
                self.applySection(section ?? .general)
            }
        }
        applySection(model.settingsSection ?? .general)
        if let frame = window.contentView?.superview {
            frame.wantsLayer = true
            frame.layer?.borderWidth = 2; frame.layer?.borderColor = BrandPalette.ink.cgColor
            frame.layer?.cornerRadius = 13
        }
        window.center()
        model.presentThemeEditor = { [weak self] spaceID in self?.openThemeEditor(for: spaceID) }
    }

    private func applySection(_ section: BrowserSettingsSection) {
        for item in window?.toolbar?.items ?? [] {
            guard let tab = BrowserSettingsSection.allCases.first(where: { $0.toolbarIdentifier == item.itemIdentifier }) else { continue }
            item.image = OrbitIcon.image(sfName: tab.symbol, pointSize: 24, variant: .color,
                                         accessibilityDescription: tab.title)
        }
        guard let window else { return }
        let identifier = section.toolbarIdentifier
        window.toolbar?.selectedItemIdentifier = nil
        window.title = section.title
        let changed = displayedSection != nil && displayedSection != section
        resize(for: section)
        updateSelectionPill(animated: changed)
        if changed { animatePane() }
        displayedSection = section
        for item in window.toolbar?.items ?? [] {
            item.menuFormRepresentation?.state = item.itemIdentifier == identifier ? .on : .off
        }
    }

    private func resize(for section: BrowserSettingsSection) {
        guard let window else { return }
        let contentSize = NSSize(width: max(900, window.contentLayoutRect.width), height: max(400, section.contentHeight))
        let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        let top = window.frame.maxY
        let frame = NSRect(x: window.frame.minX, y: top - size.height, width: size.width, height: size.height)
        guard frame != window.frame else { return }
        // Keep the top edge and navigation fixed while only the lower window edge changes.
        window.setFrame(frame, display: true)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        BrowserSettingsSection.allCases.map(\.toolbarIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }

    var selectedToolbarIdentifier: NSToolbarItem.Identifier? {
        let section = model.settingsSection ?? .general
        return BrowserSettingsSection.allCases.contains(section) ? section.toolbarIdentifier : nil
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let section = BrowserSettingsSection.allCases.first(where: { $0.toolbarIdentifier == identifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = section.toolbarTitle
        item.paletteLabel = section.toolbarTitle
        item.toolTip = section.title
        item.image = OrbitIcon.image(sfName: section.symbol, pointSize: 24, variant: .color, accessibilityDescription: section.title)
        let button = BrowserSettingsToolbarButton(section: section)
        button.target = self
        button.action = #selector(selectToolbarItem(_:))
        item.view = button
        item.isBordered = false
        item.target = self
        item.action = #selector(selectToolbarItem(_:))
        // Standard toolbar items derive their accessible name from the label and image;
        // NSToolbarItem itself is not an NSAccessibility view.
        // AppKit can overflow long/localized labels at the minimum width. Keep every pane
        // reachable there, with the same target and keyboard equivalent as the toolbar.
        let menu = NSMenuItem(title: section.title, action: #selector(selectToolbarItem(_:)),
                              keyEquivalent: String(BrowserSettingsSection.allCases.firstIndex(of: section)! + 1))
        menu.keyEquivalentModifierMask = .command
        menu.target = self
        menu.representedObject = section.rawValue
        item.menuFormRepresentation = menu
        return item
    }

    @objc private func selectToolbarItem(_ sender: Any) {
        let identifier = (sender as? NSToolbarItem)?.itemIdentifier ?? (sender as? BrowserSettingsToolbarButton)?.section.toolbarIdentifier
        let rawValue = (sender as? NSMenuItem)?.representedObject as? String
        guard let section = BrowserSettingsSection.allCases.first(where: {
            $0.toolbarIdentifier == identifier || $0.rawValue == rawValue
        }) else { return }
        if !selectSection(section) {
            window?.toolbar?.selectedItemIdentifier = nil
        }
    }

    @discardableResult
    func selectSection(_ section: BrowserSettingsSection) -> Bool {
        guard let window, window.attachedSheet == nil, model.acceptsActions,
              (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
        if model.settingsSection != section {
            guard window.makeFirstResponder(nil) else { return false }
            prepareOutgoingPane()
            model.settingsSection = section
        }
        if displayedSection != section { applySection(section) }
        return true
    }

    private func updateSelectionPill(animated: Bool) {
        guard let window, let items = window.toolbar?.items else { return }
        let views = items.compactMap(\.view)
        guard let first = views.first else { return }
        var ancestor = first.superview
        while let candidate = ancestor, !views.allSatisfy({ $0.isDescendant(of: candidate) }) { ancestor = candidate.superview }
        guard let host = ancestor else { return }
        host.layoutSubtreeIfNeeded()
        if selectionPill.superview !== host {
            selectionPill.removeFromSuperview()
            selectionPill.wantsLayer = true
            selectionPill.layer?.cornerRadius = 8
            host.addSubview(selectionPill, positioned: .below, relativeTo: nil)
        }
        selectionPill.layer?.backgroundColor = OrbitSettingsStyle.selectionColor.resolved(for: window.effectiveAppearance).cgColor
        let selected = items.first { $0.itemIdentifier == selectedToolbarIdentifier }?.view
        selectionPill.isHidden = selected == nil
        guard let selected else { return }
        let frame = selected.convert(selected.bounds, to: host)
        if animated && !OrbitMotionPreferences.prefersReducedMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = BrowserSettingsMotion.pillDuration
                context.timingFunction = BrowserSettingsMotion.timingFunction
                selectionPill.animator().setFrameOrigin(frame.origin)
                selectionPill.animator().setFrameSize(frame.size)
            }
        } else { selectionPill.frame = frame }
    }

    private func prepareOutgoingPane() {
        guard let window, window.isVisible, !OrbitMotionPreferences.prefersReducedMotion,
              let view = detailView, let root = view.superview,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        outgoingPane?.removeFromSuperlayer()
        let outgoing = CALayer()
        outgoing.contents = bitmap.cgImage
        outgoing.frame = view.convert(view.bounds, to: root)
        root.wantsLayer = true
        outgoing.autoresizingMask = root.layer?.isGeometryFlipped == true
            ? [.layerWidthSizable, .layerMaxYMargin] : [.layerWidthSizable, .layerMinYMargin]
        root.layer?.addSublayer(outgoing)
        outgoingPane = outgoing
        // Hide the live outgoing content so it cannot show through the fading snapshot.
        view.alphaValue = 0
    }

    var detailView: NSView? {
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == "settings-detail-pane" { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        return window?.contentView.flatMap(find)
    }

    private func animatePane() {
        paneTransitionGeneration += 1
        let generation = paneTransitionGeneration
        guard let view = detailView else { outgoingPane?.removeFromSuperlayer(); outgoingPane = nil; return }
        view.layer?.removeAnimation(forKey: "pane-entry")
        view.alphaValue = 1
        guard window?.isVisible == true, !OrbitMotionPreferences.prefersReducedMotion else {
            outgoingPane?.removeFromSuperlayer(); outgoingPane = nil
            return
        }
        if let outgoing = outgoingPane {
            outgoingPane = nil
            CATransaction.begin()
            CATransaction.setCompletionBlock { outgoing.removeFromSuperlayer() }
            let exit = CABasicAnimation(keyPath: "opacity")
            exit.fromValue = 1; exit.toValue = 0
            exit.duration = BrowserSettingsMotion.crossfadeDuration
            exit.timingFunction = BrowserSettingsMotion.timingFunction
            outgoing.opacity = 0
            outgoing.add(exit, forKey: "exit")
            CATransaction.commit()
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        fade.duration = BrowserSettingsMotion.crossfadeDuration
        fade.timingFunction = BrowserSettingsMotion.timingFunction
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak view] in
            guard self?.paneTransitionGeneration == generation else { return }
            view?.layer?.removeAnimation(forKey: "pane-entry")
        }
        view.layer?.add(fade, forKey: "pane-entry")
        CATransaction.commit()
    }

    func windowDidBecomeKey(_ notification: Notification) { updateSelectionPill(animated: false); model.perform { [model] in await model.reload() } }

    required init?(coder: NSCoder) { nil }
}

enum BrowserSettingsSection: String, CaseIterable, Identifiable {
    case general, profiles, spaces, shortcuts, links, ai, privacy, advanced, appearance, about
    // Auxiliary panes retain their deep links outside the seven toolbar categories.
    // The order is also the ⌘1…⌘7 order: AI is ⌘5, Advanced ⌘6, About ⌘7.
    static let allCases: [Self] = [.general, .profiles, .shortcuts, .links, .ai, .advanced, .about]
    static let navigationSections: [Self] = [.general, .profiles, .spaces, .shortcuts, .links, .ai, .privacy, .advanced, .appearance, .about]
    var id: String { rawValue }
    var toolbarIdentifier: NSToolbarItem.Identifier { .init("settings-category-" + rawValue) }
    var title: String {
        switch self {
        case .appearance: uiText("Appearance")
        case .about: uiText("About Circa")
        case .general: settingsText("general", "General")
        case .profiles: settingsText("profiles", "Profiles")
        case .spaces: settingsText("spaces", "Spaces")
        case .shortcuts: settingsText("shortcuts", "Shortcuts")
        case .links: uiText("Links")
        case .ai: uiText("AI")
        case .privacy: settingsText("privacy", "Privacy & Site Settings")
        case .advanced: settingsText("advanced", "Advanced")
        }
    }
    var toolbarTitle: String { self == .about ? uiText("About") : title }
    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .about: "info.circle"
        case .general: "gearshape"
        case .profiles: "person"
        case .spaces: "square.grid.2x2"
        case .shortcuts: "keyboard"
        case .links: "macwindow.on.rectangle"
        case .ai: "sparkles"
        case .privacy: "hand.raised"
        case .advanced: "slider.horizontal.3"
        }
    }
    var contentHeight: CGFloat {
        switch self {
        case .general: 560
        case .profiles: 500
        case .shortcuts: 590
        case .links: 410
        case .ai: 640
        case .about: 400
        case .advanced: 460
        default: 540
        }
    }
}

private enum BrowserSettingsConfirmation: Identifiable {
    case deleteSpace(BrowserSpace)
    case clearData(BrowserSettingsSiteDataRequest)
    var id: String {
        switch self {
        case .deleteSpace(let space): "space/" + space.id.rawValue.uuidString
        case .clearData(let request): "data/" + request.id.uuidString
        }
    }
}

@MainActor
struct BrowserSettingsView<Engine: BrowserEngine>: View {
    @ObservedObject var model: BrowserSettingsModel<Engine>
    @ObservedObject var runtime: BrowserSettingsRuntime
    @State private var selectedSpaceID: SpaceID?
    @State private var deletingSpace: BrowserSpace?
    @State private var deletionSpaceName = ""
    @State private var deletionProfileName = ""
    @State private var deletingProfile: BrowserProfile?

    init(model: BrowserSettingsModel<Engine>, runtime: BrowserSettingsRuntime, initialSection: BrowserSettingsSection? = nil) {
        self.model = model
        self.runtime = runtime
        if let initialSection { model.settingsSection = initialSection }
    }

    private func text(_ key: String, _ value: String) -> String { settingsText(key, value) }

    var body: some View {
        HStack(spacing: 0) {
            navigation
            BrowserSettingsDetailHost {
              VStack(alignment: .leading, spacing: 0) {
                if runtime.isUnavailable {
                    Text(text("unavailable", "Saved settings could not be opened. Defaults are in use and changes cannot be saved. The existing file is kept."))
                        .foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 12)
                        .accessibilityIdentifier("settings-unavailable")
                }
                if model.pendingProfileRemovalCount > 0 {
                    HStack {
                        Text(text("cleanupPending", "A removed profile still needs local cleanup."))
                        Button(text("retryCleanup", "Retry Cleanup")) { model.perform { try await model.retryProfileRemovals() } }
                            .disabled(model.isBusy || runtime.isUnavailable)
                    }.padding(.horizontal, 24).padding(.bottom, 12)
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red).font(Font(BrandFonts.ui(12)))
                        .padding(.horizontal, 24).padding(.bottom, 12)
                        .accessibilityIdentifier("settings-error")
                }
                if BrowserSettingsSection.allCases.contains(model.settingsSection ?? .general) {
                    BrowserOrbitSettingsPanes(model: model, runtime: runtime) { profile in
                        deletionProfileName = ""
                        deletingProfile = profile
                    }.disabled(!model.acceptsActions)
                } else if model.settingsSection == .appearance {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) { SettingsPaneIcon(section: .appearance).frame(width: 22, height: 22); Text(uiText("Appearance")).font(Font(BrandTextStyle.title.font(size: 21))).kerning(-0.945) }
                            appearance
                            BrowserSettingsIconGrid()
                        }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
                    }.disabled(!model.acceptsActions)
                } else if model.settingsSection == .about {
                    ScrollView { OrbitSecondaryAbout().padding(24) }
                } else if let profile = model.selectedProfileID {
                    ScrollView {
                      VStack(alignment: .leading, spacing: 16) {
                        if model.settingsSection != .spaces {
                          HStack {
                            Text((model.settingsSection ?? .general).title).font(Font(BrandTextStyle.title.font(size: 25))).kerning(BrandTextStyle.title.tracking(size: 25))
                            Spacer()
                            SettingsPopupPicker(text("selectedProfile", "Profile"), selectedTitle: model.catalog.profiles.first(where: { $0.id == profile })?.name ?? "", selection: Binding(get: { profile }, set: { model.selectProfile($0) })) {
                                ForEach(model.catalog.profiles, id: \.id) { Text($0.name).tag($0.id) }
                            }.labelsHidden().frame(width: 160).accessibilityIdentifier("settings-profile")
                          }
                        }
                        switch model.settingsSection ?? .general {
                        case .spaces: spaces(profile)
                        case .privacy: privacy(profile)
                        default: EmptyView()
                        }
                      }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
                    }
                    .disabled(!model.acceptsActions)
                } else {
                    Text(text("loading", "Choose an available profile.")).padding(24)
                    Spacer()
                }
              }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(Font(BrandFonts.ui(12)))
        .controlSize(.small)
        .frame(minWidth: 900, minHeight: 400)
        .foregroundStyle(OrbitSettingsStyle.foreground)
        .toggleStyle(SettingsSwitchStyle())
        .settingsPopupChrome()
        .tint(Color(nsColor: BrandPalette.cobalt))
        .background(OrbitSettingsStyle.background)
        .overlay(OrbitPaperGrainSurface().allowsHitTesting(false))
        .task { await model.reload() }
        .sheet(isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } })) {
            if let profile = deletingProfile {
                VStack(alignment: .leading, spacing: 16) {
                    Text(uiText("Delete this Profile")).font(.headline)
                    Text(profile.name)
                    Text(uiText("Deleting this Profile will permanently remove any cookies, history, preferences, and logins that belong to this Profile."))
                    Text(uiText("To continue, please type the name of this Profile:"))
                    TextField(uiText("Profile Name"), text: $deletionProfileName)
                        .accessibilityIdentifier("settings-confirm-profile-name")
                    HStack {
                        Spacer()
                        Button(uiText("Cancel")) { deletingProfile = nil }.keyboardShortcut(.cancelAction)
                        Button(uiText("Delete"), role: .destructive) {
                            guard deletionProfileName == profile.name else { return }
                            deletingProfile = nil
                            model.perform { try await model.deleteProfile(profile.id) }
                        }.settingsDestructive().disabled(deletionProfileName != profile.name || model.isBusy)
                            .accessibilityIdentifier("settings-confirm-delete-profile")
                    }
                }.padding(24).frame(width: 420).settingsFrost()
            }
        }
        .sheet(item: Binding<BrowserSettingsConfirmation?>(get: {
            if let deletingSpace { return .deleteSpace(deletingSpace) }
            if let request = model.siteDataRequest { return .clearData(request) }
            return nil
        }, set: { value in
            if case nil = value { deletingSpace = nil; model.siteDataRequest = nil }
        })) { confirmation in
            VStack(alignment: .leading, spacing: 16) {
                switch confirmation {
                case .deleteSpace(let space):
                    Text(uiFormat("Delete your “%@” Space?", space.name)).font(Font(BrandTextStyle.ui.font(size: 22, weight: .semibold)))
                    Text(uiText("This will archive all the tabs and folders inside it."))
                    Text(uiText("To continue, please type the name of this Space:"))
                    TextField(uiText("Space Name"), text: $deletionSpaceName)
                        .accessibilityIdentifier("settings-confirm-space-name")
                    HStack {
                        Spacer()
                        Button(uiText("Cancel")) { deletingSpace = nil }.keyboardShortcut(.cancelAction)
                        Button(uiText("Delete"), role: .destructive) {
                            guard deletionSpaceName == space.name else { return }
                            deletingSpace = nil
                            model.perform { try await model.deleteSpace(space.id, expectedProfileID: space.profileID) }
                        }.settingsDestructive().disabled(deletionSpaceName != space.name || model.isBusy)
                    }
                case .clearData(let request):
                    Text(text("clearDataTitle", "Clear Site Data?")).font(Font(BrandTextStyle.ui.font(size: 22, weight: .semibold)))
                    Text(request.profileName)
                    Text(request.origin == nil ? text("allSiteData", "All websites") : request.domains.joined(separator: ", "))
                    Text(text("clearDataMessage", "This signs you out of the affected websites and removes their stored data. Other profiles are kept."))
                    HStack {
                        Spacer()
                        Button(uiText("Cancel")) { model.siteDataRequest = nil }.keyboardShortcut(.cancelAction)
                        Button(text("clear", "Clear"), role: .destructive) {
                            model.siteDataRequest = nil
                            model.perform { try await model.clearSiteData(request) }
                        }.settingsDestructive()
                    }
                }
            }.padding(22).frame(width: 420).font(Font(BrandFonts.ui(12))).settingsFrost()
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(BrowserSettingsSection.navigationSections) { section in
                Button { model.navigate(to: section) } label: {
                    HStack(spacing: 8) {
                        navigationIcon(section).frame(width: 18, height: 18)
                        Text(section.title).font(Font(BrandFonts.ui(11.5, weight: model.settingsSection == section ? .semibold : .regular)))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 6)
                    .background(model.settingsSection == section ? Color(nsColor: BrandPalette.paper) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityIdentifier(section.toolbarIdentifier.rawValue)
                    .accessibilityAddTraits(model.settingsSection == section ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.top, 11).padding(.bottom, 11)
        .frame(width: 186).frame(maxHeight: .infinity)
        .background(Color(nsColor: BrandPalette.rgb(0xDCE3FB)))
    }

    private func navigationIcon(_ section: BrowserSettingsSection) -> some View {
        SettingsPaneIcon(section: section)
    }

    private func displayedSpaceIcon(_ space: BrowserSpace) -> BrowserSpaceIcon {
        let choice = runtime.document.space(space.id).iconSelection
        guard choice == .planet(.automatic) else { return choice }
        let index = model.catalog.spaces.firstIndex(where: { $0.id == space.id }) ?? 0
        return .planet(BrowserSpacePlanet.selectable[index % 4])
    }

    @ViewBuilder private func spaces(_ profile: ProfileID) -> some View {
        let available = model.catalog.spaces.filter { $0.profileID == profile }
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(available, id: \.id) { space in
                    BrowserSettingsSpaceRow(space: space,
                        theme: space.theme ?? BrandPalette.spaceGradients[(model.catalog.spaces.firstIndex(where: { $0.id == space.id }) ?? 0) % 4].theme(),
                        icon: runtime.document.space(space.id).iconSelection,
                        isSelected: (selectedSpaceID ?? available.first?.id) == space.id,
                        planetIndex: model.catalog.spaces.firstIndex(where: { $0.id == space.id }) ?? 0) {
                            selectedSpaceID = space.id
                        }
                }
                Button {
                    model.perform { selectedSpaceID = try await model.createSpace(name: uiText("New Space"), profile: profile) }
                } label: {
                    HStack(spacing: 8) {
                        OrbitIcon.view(sfName: "plus", pointSize: 14).font(.system(size: 14))
                        Text(uiText("New Space"))
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("settings-create-space")
                DisclosureGroup {
                    ForEach(model.archivedSpaces.filter { $0.space.profileID == profile }) { saved in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(saved.space.name)
                            Button(uiText("Restore Space")) {
                                model.perform { try await model.restoreSpace(saved.id, expectedProfileID: saved.space.profileID) }
                            }.accessibilityIdentifier("settings-restore-space")
                        }.padding(.vertical, 4)
                    }
                } label: { SettingsGroupLabel(title: uiText("Archived Spaces")) }
                .foregroundStyle(.secondary).padding(.top, 12)
            }.frame(width: 150)
            if let space = available.first(where: { $0.id == selectedSpaceID }) ?? available.first {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsCard {
                        SettingsDetailRow(title: text("name", "Name")) {
                            BrowserSettingsNameEditor(name: space.name, compact: true) { name in
                                model.perform { try await model.renameSpace(space.id, name: name) }
                            }.frame(width: 180).accessibilityIdentifier("settings-space-name")
                        }
                        SettingsRule()
                        SettingsDetailRow(title: uiText("Icon")) {
                            BrowserSettingsSpaceIconChoices(choice: displayedSpaceIcon(space)) { value in
                                model.queueSpaceIconEdit(spaceID: space.id, profileID: space.profileID, icon: value)
                            }.disabled(runtime.isUnavailable)
                        }
                        SettingsRule()
                        SettingsDetailRow(title: text("spaceColor", "Theme Color")) {
                            BrowserSettingsGradientPicker(model: model, space: space)
                                .accessibilityIdentifier("settings-space-theme")
                        }
                        SettingsRule()
                        SettingsDetailRow(title: text("spaceProfile", "Profile")) {
                            SettingsPopupPicker(text("spaceProfile", "Profile"), selectedTitle: model.catalog.profiles.first(where: { $0.id == space.profileID })?.name ?? "", selection: Binding(get: { space.profileID }, set: { target in
                                model.perform { try await model.assignSpace(space.id, profile: target) }
                            })) {
                                ForEach(model.catalog.profiles, id: \.id) { Text($0.name).tag($0.id) }
                            }.labelsHidden().frame(width: 160)
                                .accessibilityIdentifier("settings-space-profile")
                        }
                    }.id(space.id)
                    SettingsCard {
                        SettingsDetailRow(title: uiText("Delete this Space")) {
                            Button(uiText("Delete…")) { deletionSpaceName = ""; deletingSpace = space }
                                .buttonStyle(OrbitPrintButtonStyle())
                                .disabled(model.catalog.spaces.count < 2 || runtime.isUnavailable)
                                .accessibilityIdentifier("settings-delete-space")
                        }
                    }
                    Text(text("spaceProfileNote", "Changing a profile requires an empty Space that is not open in a window."))
                        .font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func privacy(_ profile: ProfileID) -> some View {
        SettingsCard {
            BrowserSafeBrowsingSettingsRow(model: model).padding(14)
        }
        SettingsCard {
            HStack(spacing: 12) {
                OrbitIcon.view(sfName: "trash", pointSize: 20).font(.system(size: 20)).frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text("siteData", "Website Data")).fontWeight(.medium)
                    Text(text("siteDataNote", "Website data belongs to this profile. Clearing it does not remove your browsing history or saved permission choices."))
                        .font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(text("clearSiteData", "Clear Site Data for This Profile…")) {
                    model.perform { try await model.reviewSiteData(origin: nil, profile: profile) }
                }.disabled(!model.supportsSiteData)
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }
        SettingsGroupLabel(title: text("sitePermissions", "Site Permissions"))
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                if model.permissionsUnavailable {
                    Text(text("permissionsUnavailable", "Saved permissions could not be opened. The existing file is kept and access remains restricted."))
                        .foregroundStyle(.red).padding(14)
                } else if model.permissionRows.isEmpty {
                    Text(text("noSites", "No saved site permissions for this profile.")).foregroundStyle(.secondary).padding(14)
                }
                ForEach(permissionOrigins, id: \.self) { origin in
                    HStack(spacing: 12) {
                        OrbitIcon.view(sfName: "globe", pointSize: 20).font(.system(size: 20)).frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(origin.value).fontWeight(.medium).textSelection(.enabled)
                            Button(text("clearSite", "Clear Site Data…")) {
                                model.perform { try await model.reviewSiteData(origin: origin, profile: profile) }
                            }.disabled(!model.supportsSiteData)
                        }.frame(width: 160, alignment: .leading)
                        ScrollView(.horizontal) {
                          HStack(spacing: 12) {
                           ForEach(model.permissionRows.filter { $0.origin == origin }) { row in
                            VStack(spacing: 4) {
                                Text(row.permission.displayTitle).font(Font(BrandFonts.ui(11))).foregroundStyle(.secondary)
                                SettingsPopupPicker(row.permission.displayTitle, selectedTitle: permissionName(row.setting), selection: Binding(get: { row.setting }, set: { value in
                                    model.perform { try await model.changePermission(row, setting: value, profile: profile) }
                                })) {
                                    ForEach(BrowserSitePermissionSetting.allCases.filter { $0 != .allow || row.permission.supportsPersistentAllow }, id: \.self) { value in
                                        Text(permissionName(value)).tag(value)
                                    }
                                }.labelsHidden().frame(width: 85)
                            }
                           }
                          }
                        }.frame(height: 64)
                    }.padding(14)
                    SettingsRule()
                }
            }
        }
        Text(text("permissionLimits", "Only permissions supported by the current engine are editable. Some changes require reloading the website."))
            .font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
    }

    private var permissionOrigins: [BrowserSiteOrigin] {
        model.permissionRows.reduce(into: []) { origins, row in
            if !origins.contains(row.origin) { origins.append(row.origin) }
        }
    }

    @ViewBuilder private var appearance: some View {
        if let profile = model.selectedProfileID {
            SettingsGroupLabel(title: uiText("Space appearance"))
            SettingsCard {
                Group {
                    SettingsDetailRow(title: uiText("Profile")) {
                        SettingsPopupPicker(uiText("Profile"), selectedTitle: model.catalog.profiles.first(where: { $0.id == profile })?.name ?? "", selection: Binding(get: { profile }, set: { model.selectProfile($0) })) {
                            ForEach(model.catalog.profiles, id: \.id) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(width: 160).accessibilityIdentifier("settings-appearance-profile")
                    }
                    SettingsRule()
                }
                if let id = model.appearanceSpaceID, let space = model.catalog.spaces.first(where: { $0.id == id && $0.profileID == profile }) {
                    SettingsDetailRow(title: uiText("Space")) {
                        SettingsPopupPicker(uiText("Space"), selectedTitle: space.name, selection: Binding(get: { id }, set: { model.selectAppearanceSpace($0) })) {
                            ForEach(model.catalog.spaces.filter { $0.profileID == profile }, id: \.id) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(width: 160).accessibilityIdentifier("settings-appearance-space")
                    }
                    SettingsRule()
                    SettingsDetailRow(title: uiText("Theme Color")) { BrowserSettingsGradientPicker(model: model, space: space) }
                    Text(uiText("Applies to this Space in every window. Other Spaces keep their own themes."))
                        .font(Font(BrandFonts.ui(10.5))).foregroundStyle(.secondary).padding(13)
                        .accessibilityIdentifier("settings-appearance-scope")
                } else {
                    Text(uiText("Choose a profile with an available Space.")).padding(13)
                }
                SettingsRule()
                SettingsDetailRow(title: uiText("Animations")) {
                    SettingsPopupPicker(uiText("Animations"), selectedTitle: SettingsPopupLabels.motion(runtime.document.reducedMotion), selection: Binding(get: { runtime.document.reducedMotion }, set: { value in
                        model.perform { try await model.setReducedMotion(value) }
                    })) {
                        Text(uiText("Follow System")).tag(BrowserReducedMotionSetting.system)
                        Text(uiText("Reduce Motion")).tag(BrowserReducedMotionSetting.reduce)
                        Text(uiText("Full Motion")).tag(BrowserReducedMotionSetting.full)
                    }.labelsHidden().frame(width: 160)
                }
            }.disabled(runtime.isUnavailable)
        }
    }

    private func permissionName(_ value: BrowserSitePermissionSetting) -> String {
        switch value { case .ask: text("ask", "Ask"); case .allow: text("allow", "Allow"); case .block: text("block", "Block") }
    }
}

@MainActor
struct BrowserSettingsNameEditor: View {
    let name: String
    let compact: Bool
    let save: (String) -> Void
    @StateObject private var draft: BrowserSettingsNameDraft
    init(name: String, compact: Bool = false, save: @escaping (String) -> Void) {
        self.name = name; self.compact = compact; self.save = save
        _draft = StateObject(wrappedValue: BrowserSettingsNameDraft(name: name))
    }
    var body: some View {
        Group {
          if compact {
            BrowserSettingsNameField(draft: draft, onSubmit: { draft.submit(save) }, savesOnEndEditing: true)
                .padding(.horizontal, 9).frame(height: 26)
                .background(OrbitSettingsStyle.panel, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(OrbitSettingsStyle.border))
          } else {
           HStack {
            LabeledContent(settingsText("name", "Name")) {
                BrowserSettingsNameField(draft: draft) { draft.submit(save) }
            }
            Button(settingsText("rename", "Rename")) { draft.submit(save) }.disabled(!draft.canSubmit)
           }
          }
        }.onChange(of: name) { _, value in draft.receivePersisted(value) }
    }
}

func shortcutLabel(_ shortcut: BrowserShortcut) -> String {
    var label = ""
    if shortcut.modifiers.contains(.control) { label += "⌃" }
    if shortcut.modifiers.contains(.option) { label += "⌥" }
    if shortcut.modifiers.contains(.shift) { label += "⇧" }
    if shortcut.modifiers.contains(.command) { label += "⌘" }
    let keys = ["\t": "⇥", "\r": "↩", "\u{1b}": "⎋", "\u{7f}": "⌫", "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→", " ": settingsText("spaceKey", "Space")]
    if let scalar = shortcut.key.unicodeScalars.first, (0xf704...0xf726).contains(scalar.value) {
        return label + "F\(scalar.value - 0xf704 + 1)"
    }
    return label + (keys[shortcut.key] ?? shortcut.key.uppercased())
}

func shortcutAccessibilityLabel(_ shortcut: BrowserShortcut) -> String {
    var parts: [String] = []
    if shortcut.modifiers.contains(.control) { parts.append(settingsText("key.control", "Control")) }
    if shortcut.modifiers.contains(.option) { parts.append(settingsText("key.option", "Option")) }
    if shortcut.modifiers.contains(.shift) { parts.append(settingsText("key.shift", "Shift")) }
    if shortcut.modifiers.contains(.command) { parts.append(settingsText("key.command", "Command")) }
    let names = ["\t": settingsText("key.tab", "Tab"), "\r": settingsText("key.return", "Return"),
                 "\u{1b}": settingsText("key.escape", "Escape"), "\u{7f}": settingsText("key.delete", "Delete"),
                 "\u{f700}": settingsText("key.up", "Up Arrow"), "\u{f701}": settingsText("key.down", "Down Arrow"),
                 "\u{f702}": settingsText("key.left", "Left Arrow"), "\u{f703}": settingsText("key.right", "Right Arrow"),
                 " ": settingsText("key.space", "Space")]
    if let name = names[shortcut.key] { parts.append(name) }
    else if let scalar = shortcut.key.unicodeScalars.first, (0xf704...0xf726).contains(scalar.value) { parts.append("F\(scalar.value - 0xf704 + 1)") }
    else { parts.append(shortcut.key.uppercased()) }
    return parts.joined(separator: " ")
}
