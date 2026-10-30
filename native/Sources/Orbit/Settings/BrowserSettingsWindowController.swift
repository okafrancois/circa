import AppKit
import BrowserCore
import BrowserEngine
import Combine
import BrowserShell
import SwiftUI

/// CMD deliberately leaves standard shortcuts to auxiliary key windows. Handle native Close
/// here, before the browser menu's Archive Tab equivalent, without a second event monitor.
@MainActor
final class BrowserSettingsWindow: NSWindow {
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
    static var minimumContentSize: NSSize { NSSize(width: 684, height: 400) }

    /// The theme editor opened from the Spaces section.
    var themeEditor: OrbitThemeEditorController?
    let themeUndoManager = OrbitThemeUndoManager()

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { themeUndoManager }

    init(model: BrowserSettingsModel<Engine>, appearanceOverride: NSAppearance.Name? = OrbitAppearance.launchOverride) {
        self.model = model
        let window = BrowserSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 684, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = (model.settingsSection ?? .general).title
        window.titleVisibility = .hidden
        window.appearance = OrbitAppearance.windowAppearance(for: .automatic, override: appearanceOverride)
        window.identifier = NSUserInterfaceItemIdentifier("orbit-settings")
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minimumContentSize
        window.toolbarStyle = .preference
        window.titlebarSeparatorStyle = .line
        window.titlebarAppearsTransparent = true
        window.backgroundColor = OrbitSettingsStyle.toolbarColor
        window.isOpaque = true
        window.isMovableByWindowBackground = false
        window.contentViewController = NSHostingController(rootView: BrowserSettingsView(model: model, runtime: model.runtime))
        super.init(window: window)
        themeUndoManager.registry = model.environment.themeEditors
        window.delegate = self
        let toolbar = NSToolbar(identifier: "orbit-settings-categories")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
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
        let contentSize = NSSize(width: max(684, window.contentLayoutRect.width), height: section.contentHeight)
        let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        let top = window.frame.maxY
        let frame = NSRect(x: window.frame.minX, y: top - size.height, width: size.width, height: size.height)
        guard frame != window.frame else { return }
        guard window.isVisible && !OrbitMotionPreferences.prefersReducedMotion else {
            window.setFrame(frame, display: true); return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = BrowserSettingsMotion.resizeDuration
            context.timingFunction = BrowserSettingsMotion.timingFunction
            window.animator().setFrame(frame, display: true)
        }
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
              let view = window.contentView, let root = view.superview,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        outgoingPane?.removeFromSuperlayer()
        let outgoing = CALayer()
        outgoing.contents = bitmap.cgImage
        outgoing.frame = view.convert(view.bounds, to: root)
        root.wantsLayer = true
        root.layer?.addSublayer(outgoing)
        outgoingPane = outgoing
    }

    private func animatePane() {
        if let outgoing = outgoingPane {
            outgoingPane = nil
            CATransaction.begin()
            CATransaction.setCompletionBlock { outgoing.removeFromSuperlayer() }
            let exit = CABasicAnimation(keyPath: "opacity")
            exit.fromValue = 1; exit.toValue = 0; exit.duration = BrowserSettingsMotion.exitDuration
            exit.timingFunction = CAMediaTimingFunction(name: .easeIn)
            outgoing.opacity = 0
            outgoing.add(exit, forKey: "exit")
            CATransaction.commit()
        }
        guard let view = window?.contentView, window?.isVisible == true,
              !OrbitMotionPreferences.prefersReducedMotion else { return }
        view.wantsLayer = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        fade.beginTime = CACurrentMediaTime() + BrowserSettingsMotion.enterDelay
        fade.duration = BrowserSettingsMotion.enterDuration
        fade.fillMode = .backwards
        fade.timingFunction = BrowserSettingsMotion.timingFunction
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = view.layer?.superlayer?.isGeometryFlipped == true ? BrowserSettingsMotion.rise : -BrowserSettingsMotion.rise
        rise.toValue = 0
        rise.beginTime = fade.beginTime; rise.duration = fade.duration
        rise.fillMode = .backwards; rise.timingFunction = BrowserSettingsMotion.timingFunction
        view.layer?.add(fade, forKey: "pane-fade")
        view.layer?.add(rise, forKey: "pane-rise")
    }

    func windowDidBecomeKey(_ notification: Notification) { updateSelectionPill(animated: false); model.perform { [model] in await model.reload() } }

    required init?(coder: NSCoder) { nil }
}

enum BrowserSettingsSection: String, CaseIterable, Identifiable {
    case general, profiles, spaces, shortcuts, links, privacy, advanced, appearance, about
    // Auxiliary panes retain their deep links outside the six toolbar categories.
    static let allCases: [Self] = [.general, .profiles, .shortcuts, .links, .advanced, .about]
    var id: String { rawValue }
    var toolbarIdentifier: NSToolbarItem.Identifier { .init("settings-category-" + rawValue) }
    var title: String {
        switch self {
        case .appearance: uiText("Appearance")
        case .about: uiText("About Orbit")
        case .general: settingsText("general", "General")
        case .profiles: settingsText("profiles", "Profiles")
        case .spaces: settingsText("spaces", "Spaces")
        case .shortcuts: settingsText("shortcuts", "Shortcuts")
        case .links: uiText("Links")
        case .privacy: settingsText("privacy", "Privacy & Site Settings")
        case .advanced: settingsText("advanced", "Advanced")
        }
    }
    var toolbarTitle: String { self == .about ? uiText("About") : title }
    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .about: "app.dashed"
        case .general: "gearshape"
        case .profiles: "person"
        case .spaces: "square.grid.2x2"
        case .shortcuts: "keyboard"
        case .links: "macwindow.on.rectangle"
        case .privacy: "hand.raised"
        case .advanced: "slider.horizontal.3"
        }
    }
    var contentHeight: CGFloat {
        switch self {
        case .general: 400
        case .profiles: 500
        case .shortcuts: 590
        case .links: 410
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
    @State private var newSpaceName = ""
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
        VStack(spacing: 0) {
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
                    Form { appearance }.formStyle(.grouped).scrollContentBackground(.hidden)
                        .disabled(!model.acceptsActions)
                } else if model.settingsSection == .about {
                    ScrollView { OrbitSecondaryAbout().padding(24) }
                } else if let profile = model.selectedProfileID {
                    ScrollView {
                      VStack(alignment: .leading, spacing: 16) {
                        Text((model.settingsSection ?? .general).title).font(Font(BrandTextStyle.title.font(size: 28)))
                        if model.settingsSection != .shortcuts && model.settingsSection != .advanced {
                            Picker(text("selectedProfile", "Profile"), selection: Binding(get: { profile }, set: { model.selectProfile($0) })) {
                                ForEach(model.catalog.profiles, id: \.id) { Text($0.name).tag($0.id) }
                            }.accessibilityIdentifier("settings-profile")
                        }
                        switch model.settingsSection ?? .general {
                        case .spaces: spaces(profile)
                        case .privacy: privacy(profile)
                        default: EmptyView()
                        }
                      }.padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 26)
                    }
                    .disabled(!model.acceptsActions)
                } else {
                    Text(text("loading", "Choose an available profile.")).padding(24)
                    Spacer()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(Font(BrandFonts.ui(13)))
        .controlSize(.small)
        .frame(minWidth: 640, minHeight: 400)
        .foregroundStyle(OrbitSettingsStyle.foreground)
        .tint(Color(nsColor: .controlAccentColor))
        .toggleStyle(.switch)
        .background(OrbitSettingsStyle.background)
        .task { await model.reload() }
        .sheet(isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } })) {
            if let profile = deletingProfile {
                VStack(alignment: .leading, spacing: 16) {
                    Text(uiText("Delete this Profile")).font(Font(BrandTextStyle.title.font(size: 22)))
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
                        }.disabled(deletionProfileName != profile.name || model.isBusy)
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
                    Text(uiFormat("Delete your “%@” Space?", space.name)).font(Font(BrandTextStyle.title.font(size: 22)))
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
                        }.disabled(deletionSpaceName != space.name || model.isBusy)
                    }
                case .clearData(let request):
                    Text(text("clearDataTitle", "Clear Site Data?")).font(Font(BrandTextStyle.title.font(size: 22)))
                    Text(request.profileName)
                    Text(request.origin == nil ? text("allSiteData", "All websites") : request.domains.joined(separator: ", "))
                    Text(text("clearDataMessage", "This signs you out of the affected websites and removes their stored data. Other profiles are kept."))
                    HStack {
                        Spacer()
                        Button(uiText("Cancel")) { model.siteDataRequest = nil }.keyboardShortcut(.cancelAction)
                        Button(text("clear", "Clear"), role: .destructive) {
                            model.siteDataRequest = nil
                            model.perform { try await model.clearSiteData(request) }
                        }
                    }
                }
            }.padding(22).frame(width: 420).font(Font(BrandFonts.ui(13))).settingsFrost()
        }
    }

    @ViewBuilder private func spaces(_ profile: ProfileID) -> some View {
        let available = model.catalog.spaces.filter { $0.profileID == profile }
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(available, id: \.id) { space in
                    Button { selectedSpaceID = space.id } label: {
                        HStack(spacing: 8) {
                            BrowserSettingsThemeSwatch(theme: space.theme ?? runtime.document.space(space.id).palette.themeModel)
                            Text(space.name)
                            Spacer(minLength: 0)
                        }.padding(8).background((selectedSpaceID ?? available.first?.id) == space.id ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                        .foregroundStyle((selectedSpaceID ?? available.first?.id) == space.id ? .white : OrbitSettingsStyle.foreground)
                }
                Divider().padding(.vertical, 6)
                createSpaceForm(profile)
                if model.archivedSpaces.contains(where: { $0.space.profileID == profile }) {
                    DisclosureGroup(uiText("Archived Spaces")) {
                        ForEach(model.archivedSpaces.filter { $0.space.profileID == profile }) { saved in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(saved.space.name)
                                Button(uiText("Restore Space")) { model.perform { try await model.restoreSpace(saved.id, expectedProfileID: saved.space.profileID) } }
                                    .accessibilityIdentifier("settings-restore-space")
                            }
                        }
                    }
                }
            }.frame(width: 150)
            if let space = available.first(where: { $0.id == selectedSpaceID }) ?? available.first {
                VStack(alignment: .leading, spacing: 12) {
                    Text(space.name).font(Font(BrandTextStyle.title.font(size: 22)))
                        .frame(maxWidth: .infinity, minHeight: 74, alignment: .bottomLeading).padding(12)
                        .background(LinearGradient(colors: (space.theme ?? runtime.document.space(space.id).palette.themeModel ?? BrowserSpaceThemePresets.default).light.stops.map {
                            Color(nsColor: OrbitSpaceThemes.color($0))
                        }, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 14) {
                            BrowserSettingsNameEditor(name: space.name) { name in model.perform { try await model.renameSpace(space.id, name: name) } }
                                .accessibilityIdentifier("settings-space-name")
                            Divider()
                            BrowserSettingsIconEditor(choice: runtime.document.space(space.id).iconSelection) { value in
                                model.queueSpaceIconEdit(spaceID: space.id, profileID: space.profileID, icon: BrowserSpaceIcon(legacyIcon: value))
                            }.disabled(runtime.isUnavailable)
                            Divider()
                            HStack {
                                Text(text("spaceColor", "Theme Color"))
                                Spacer()
                                BrowserSettingsGradientPicker(model: model, space: space)
                                    .accessibilityIdentifier("settings-space-theme")
                            }
                            Divider()
                            Picker(text("spaceProfile", "Profile"), selection: Binding(get: { space.profileID }, set: { target in
                                model.perform { try await model.assignSpace(space.id, profile: target) }
                            })) {
                                ForEach(model.catalog.profiles, id: \.id) { Text($0.name).tag($0.id) }
                            }
                        }.padding(14)
                    }.id(space.id)
                    Text(text("spaceProfileNote", "Changing a profile requires an empty Space that is not open in a window.")).font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                    Button(uiText("Delete Space…"), role: .destructive) { deletionSpaceName = ""; deletingSpace = space }
                        .disabled(model.catalog.spaces.count < 2 || runtime.isUnavailable)
                        .accessibilityIdentifier("settings-delete-space")
                }.frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private func createSpaceForm(_ profile: ProfileID) -> some View {
        TextField(uiText("Space Name"), text: $newSpaceName)
            .accessibilityIdentifier("settings-new-space-name")
        Button(uiText("Create Space")) {
            let name = newSpaceName
            model.perform { try await model.createSpace(name: name, profile: profile); if newSpaceName == name { newSpaceName = "" } }
        }.disabled(newSpaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("settings-create-space")
    }

    @ViewBuilder private func privacy(_ profile: ProfileID) -> some View {
        SettingsCard { VStack(alignment: .leading, spacing: 12) {
            Text(text("siteData", "Website Data")).fontWeight(.semibold)
            Text(text("siteDataNote", "Website data belongs to this profile. Clearing it does not remove your browsing history or saved permission choices.")).foregroundStyle(.secondary)
            Button(text("clearSiteData", "Clear Site Data for This Profile…")) { model.perform { try await model.reviewSiteData(origin: nil, profile: profile) } }
                .disabled(!model.supportsSiteData)
        }.padding(14) }
        SettingsCard { VStack(alignment: .leading, spacing: 12) {
            Text(text("sitePermissions", "Site Permissions")).fontWeight(.semibold)
            if model.permissionsUnavailable {
                Text(text("permissionsUnavailable", "Saved permissions could not be opened. The existing file is kept and access remains restricted.")).foregroundStyle(.red)
            } else if model.permissionRows.isEmpty {
                Text(text("noSites", "No saved site permissions for this profile.")).foregroundStyle(.secondary)
            }
            ForEach(model.permissionRows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.origin.value).font(Font(BrandFonts.ui(11))).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                        if row.permission == model.permissionRows.first(where: { $0.origin == row.origin })?.permission {
                            Button(text("clearSite", "Clear Site Data…")) { model.perform { try await model.reviewSiteData(origin: row.origin, profile: profile) } }
                                .disabled(!model.supportsSiteData)
                        }
                    }
                    Picker(row.permission.displayTitle, selection: Binding(get: { row.setting }, set: { value in
                        model.perform { try await model.changePermission(row, setting: value, profile: profile) }
                    })) {
                        ForEach(BrowserSitePermissionSetting.allCases.filter { $0 != .allow || row.permission.supportsPersistentAllow }, id: \.self) { value in
                            Text(permissionName(value)).tag(value)
                        }
                    }
                }
            }
            Text(text("permissionLimits", "Only permissions supported by the current engine are editable. Some changes require reloading the website.")).font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
        }.padding(14) }
        SettingsCard { VStack(alignment: .leading, spacing: 12) {
            Text(text("safeBrowsing", "Safe Browsing")).fontWeight(.semibold)
            if model.safeBrowsingAvailable {
                Text(text("safeBrowsingOn", "Warnings for dangerous sites and downloads are on.")).foregroundStyle(.secondary)
            } else {
                Text(text("safeBrowsingUnavailable", "Unavailable in this build. Orbit does not warn about dangerous sites or downloads.")).foregroundStyle(.secondary)
            }
        }.padding(14) }
    }

    @ViewBuilder private var appearance: some View {
        if let profile = model.selectedProfileID {
            Section(uiText("Space appearance")) {
                Picker(uiText("Profile"), selection: Binding(get: { profile }, set: { model.selectProfile($0) })) {
                    ForEach(model.catalog.profiles, id: \.id) { Text($0.name).tag($0.id) }
                }.accessibilityIdentifier("settings-appearance-profile")
                if let id = model.appearanceSpaceID,
                   model.catalog.spaces.contains(where: { $0.id == id && $0.profileID == profile }) {
                    Picker(uiText("Space"), selection: Binding(get: { id }, set: { model.selectAppearanceSpace($0) })) {
                        ForEach(model.catalog.spaces.filter { $0.profileID == profile }, id: \.id) { Text($0.name).tag($0.id) }
                    }.accessibilityIdentifier("settings-appearance-space")
                    Text(uiText("Applies to this Space in every window. Other Spaces keep their own themes."))
                        .foregroundStyle(.secondary).accessibilityIdentifier("settings-appearance-scope")
                    Button(uiText("Edit Theme Color…")) { model.presentThemeEditor?(id) }
                } else {
                    Text(uiText("Choose a profile with an available Space."))
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
    let save: (String) -> Void
    @StateObject private var draft: BrowserSettingsNameDraft
    init(name: String, save: @escaping (String) -> Void) {
        self.name = name; self.save = save
        _draft = StateObject(wrappedValue: BrowserSettingsNameDraft(name: name))
    }
    var body: some View {
        HStack {
            LabeledContent(settingsText("name", "Name")) {
                BrowserSettingsNameField(draft: draft) { draft.submit(save) }
            }
            Button(settingsText("rename", "Rename")) { draft.submit(save) }.disabled(!draft.canSubmit)
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
