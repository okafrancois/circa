import AppKit
import BrowserCore
import BrowserEngine
import Combine
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
        window.appearance = OrbitAppearance.windowAppearance(for: .automatic, override: appearanceOverride)
        window.identifier = NSUserInterfaceItemIdentifier("orbit-settings")
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minimumContentSize
        window.toolbarStyle = .preference
        window.titlebarSeparatorStyle = .line
        window.isMovableByWindowBackground = false
        window.contentViewController = NSHostingController(rootView: BrowserSettingsView(model: model, runtime: model.runtime))
        super.init(window: window)
        themeUndoManager.registry = model.environment.themeEditors
        window.delegate = self
        let toolbar = NSToolbar(identifier: "orbit-settings-categories")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.selectCategory = { [weak self] section in self?.selectSection(section) ?? false }
        // Keep the hosting view alive: catalog publications must not recreate drafts or IME editors.
        sectionObservation = model.$settingsSection.sink { [weak self] section in
            // @Published delivers before storing the value. Resizing can run AppKit's nested
            // display loop; defer that work so SwiftUI never consumes the old pane's value.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.model.settingsSection == section else { return }
                self.applySection(section ?? .general)
            }
        }
        applySection(model.settingsSection ?? .general)
        window.center()
        model.presentThemeEditor = { [weak self] spaceID in self?.openThemeEditor(for: spaceID) }
    }

    private func applySection(_ section: BrowserSettingsSection) {
        guard let window else { return }
        let identifier = section.toolbarIdentifier
        window.toolbar?.selectedItemIdentifier = BrowserSettingsSection.allCases.contains(section) ? identifier : nil
        window.title = section.title
        resize(for: section)
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
        window.setFrame(frame, display: true, animate: window.isVisible && !OrbitMotionPreferences.prefersReducedMotion)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        BrowserSettingsSection.allCases.map(\.toolbarIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let section = BrowserSettingsSection.allCases.first(where: { $0.toolbarIdentifier == identifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = section.title
        item.paletteLabel = section.title
        item.toolTip = section.title
        item.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
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
        let identifier = (sender as? NSToolbarItem)?.itemIdentifier
        let rawValue = (sender as? NSMenuItem)?.representedObject as? String
        guard let section = BrowserSettingsSection.allCases.first(where: {
            $0.toolbarIdentifier == identifier || $0.rawValue == rawValue
        }) else { return }
        if !selectSection(section) {
            window?.toolbar?.selectedItemIdentifier = (model.settingsSection ?? .general).toolbarIdentifier
        }
    }

    @discardableResult
    func selectSection(_ section: BrowserSettingsSection) -> Bool {
        guard let window, window.attachedSheet == nil, model.acceptsActions,
              (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
        if model.settingsSection != section {
            guard window.makeFirstResponder(nil) else { return false }
            model.settingsSection = section
        }
        applySection(section)
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) { model.perform { [model] in await model.reload() } }

    required init?(coder: NSCoder) { nil }
}

enum BrowserSettingsSection: String, CaseIterable, Identifiable {
    case general, profiles, spaces, shortcuts, links, icon, privacy, advanced, appearance, about
    // Space/theme tools and About retain their deep links without adding non-Orbit toolbar tabs.
    static let allCases: [Self] = [.general, .profiles, .shortcuts, .links, .icon, .advanced]
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
        case .icon: uiText("Icon")
        case .privacy: settingsText("privacy", "Privacy & Site Settings")
        case .advanced: settingsText("advanced", "Advanced")
        }
    }
    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .about: "info.circle"
        case .general: "gearshape"
        case .profiles: "person"
        case .spaces: "square.grid.2x2"
        case .shortcuts: "keyboard"
        case .links: "macwindow.on.rectangle"
        case .icon: "app.dashed"
        case .privacy: "hand.raised"
        case .advanced: "slider.horizontal.3"
        }
    }
    var contentHeight: CGFloat {
        switch self {
        case .general: 400
        case .profiles: 500
        case .shortcuts: 510
        case .links: 520
        case .icon: 400
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
    @State private var deletingSpace: BrowserSpace?
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
                    Text(error).foregroundStyle(.red).font(.system(size: 12))
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
                    Form {
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
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .disabled(!model.acceptsActions)
                } else {
                    Text(text("loading", "Choose an available profile.")).padding(24)
                    Spacer()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(.system(size: 13))
        .controlSize(.small)
        .frame(minWidth: 640, minHeight: 400)
        .foregroundStyle(OrbitSettingsStyle.foreground)
        .tint(.blue)
        .background(OrbitSettingsStyle.background)
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
                        }.disabled(deletionProfileName != profile.name || model.isBusy)
                            .accessibilityIdentifier("settings-confirm-delete-profile")
                    }
                }.padding(24).frame(width: 420)
            }
        }
        .alert(item: Binding<BrowserSettingsConfirmation?>(get: {
            if let deletingSpace { return .deleteSpace(deletingSpace) }
            if let request = model.siteDataRequest { return .clearData(request) }
            return nil
        }, set: { value in
            if case nil = value { deletingProfile = nil; deletingSpace = nil; model.siteDataRequest = nil }
        })) { confirmation in
            switch confirmation {
            case .deleteSpace(let space):
                return Alert(title: Text(uiFormat("Delete your “%@” Space?", space.name)),
                             message: Text(uiText("This will archive all the tabs and folders inside it.")),
                             primaryButton: .destructive(Text(uiText("Delete"))) { model.perform { try await model.deleteSpace(space.id, expectedProfileID: space.profileID) } },
                             secondaryButton: .cancel())
            case .clearData(let request):
                let scope = request.origin == nil ? text("allSiteData", "All websites") : request.domains.joined(separator: ", ")
                return Alert(title: Text(text("clearDataTitle", "Clear Site Data?")),
                             message: Text(request.profileName + "\n" + scope + "\n" + text("clearDataMessage", "This signs you out of the affected websites and removes their stored data. Other profiles are kept.")),
                             primaryButton: .destructive(Text(text("clear", "Clear"))) { model.perform { try await model.clearSiteData(request) } },
                             secondaryButton: .cancel())
            }
        }
    }

    @ViewBuilder private func spaces(_ profile: ProfileID) -> some View {
        Section(uiText("Create a Space")) { createSpaceForm(profile) }
        if model.archivedSpaces.contains(where: { $0.space.profileID == profile }) {
            Section(uiText("Archived Spaces")) {
                ForEach(model.archivedSpaces.filter { $0.space.profileID == profile }) { saved in
                    HStack {
                        Text(saved.space.name)
                        Spacer()
                        Button(uiText("Restore Space")) { model.perform { try await model.restoreSpace(saved.id, expectedProfileID: saved.space.profileID) } }
                            .accessibilityIdentifier("settings-restore-space")
                    }
                }
            }
        }
        ForEach(model.catalog.spaces.filter { $0.profileID == profile }, id: \.id) { space in
            Section(space.name) {
                // The enclosing ForEach owns Space identity. Sibling editors must never share an explicit ID.
                BrowserSettingsNameEditor(name: space.name) { name in model.perform { try await model.renameSpace(space.id, name: name) } }
                    .accessibilityIdentifier("settings-space-name")
                BrowserSettingsIconEditor(choice: runtime.document.space(space.id).iconSelection) { value in
                    model.queueSpaceIconEdit(spaceID: space.id, profileID: space.profileID, icon: BrowserSpaceIcon(legacyIcon: value))
                }.disabled(runtime.isUnavailable)
                // Space themes: the Space's stored theme, else its legacy palette (no longer editable here).
                HStack {
                    Text(text("spaceColor", "Theme Color"))
                    Spacer()
                    BrowserSettingsThemeSwatch(theme: space.theme ?? runtime.document.space(space.id).palette.themeModel)
                    Button(text("editThemeColor", "Edit Theme Color…")) { model.presentThemeEditor?(space.id) }
                        .accessibilityIdentifier("settings-space-theme")
                }
                Picker(text("spaceProfile", "Profile"), selection: Binding(get: { space.profileID }, set: { target in
                    model.perform { try await model.assignSpace(space.id, profile: target) }
                })) {
                    ForEach(model.catalog.profiles, id: \.id) { Text($0.name).tag($0.id) }
                }
                Text(text("spaceProfileNote", "Changing a profile requires an empty Space that is not open in a window.")).font(.system(size: 12)).foregroundStyle(.secondary)
                Button(uiText("Delete Space…"), role: .destructive) { deletingSpace = space }
                    .disabled(model.catalog.spaces.count < 2 || runtime.isUnavailable)
                    .accessibilityIdentifier("settings-delete-space")
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
        Section(text("siteData", "Website Data")) {
            Text(text("siteDataNote", "Website data belongs to this profile. Clearing it does not remove your browsing history or saved permission choices.")).foregroundStyle(.secondary)
            Button(text("clearSiteData", "Clear Site Data for This Profile…")) { model.perform { try await model.reviewSiteData(origin: nil, profile: profile) } }
                .disabled(!model.supportsSiteData)
        }
        Section(text("sitePermissions", "Site Permissions")) {
            if model.permissionsUnavailable {
                Text(text("permissionsUnavailable", "Saved permissions could not be opened. The existing file is kept and access remains restricted.")).foregroundStyle(.red)
            } else if model.permissionRows.isEmpty {
                Text(text("noSites", "No saved site permissions for this profile.")).foregroundStyle(.secondary)
            }
            ForEach(model.permissionRows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.origin.value).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
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
            Text(text("permissionLimits", "Only permissions supported by the current engine are editable. Some changes require reloading the website.")).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Section(text("safeBrowsing", "Safe Browsing")) {
            if model.safeBrowsingAvailable {
                Text(text("safeBrowsingOn", "Warnings for dangerous sites and downloads are on.")).foregroundStyle(.secondary)
            } else {
                Text(text("safeBrowsingUnavailable", "Unavailable in this build. Orbit does not warn about dangerous sites or downloads.")).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var appearance: some View {
        if let profile = model.selectedProfileID {
            Section(uiText("Space appearance")) {
                Picker(uiText("Profile"), selection: Binding(get: { profile }, set: { model.selectProfile($0) })) {
                    ForEach(model.catalog.profiles, id: \.id) { Text($0.name).tag($0.id) }
                }.accessibilityIdentifier("settings-appearance-profile")
                if let id = model.appearanceSpaceID,
                   let space = model.catalog.spaces.first(where: { $0.id == id && $0.profileID == profile }) {
                    Picker(uiText("Space"), selection: Binding(get: { id }, set: { model.selectAppearanceSpace($0) })) {
                        ForEach(model.catalog.spaces.filter { $0.profileID == profile }, id: \.id) { Text($0.name).tag($0.id) }
                    }.accessibilityIdentifier("settings-appearance-space")
                    let surface = space.theme?.surface ?? BrowserThemeSurface()
                    Text(uiText("Applies to this Space in every window. Other Spaces keep their own themes."))
                        .foregroundStyle(.secondary).accessibilityIdentifier("settings-appearance-scope")
                    if space.theme?.surface == nil {
                        Text(uiText("This Space keeps its existing material until you change a control."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker(uiText("Material"), selection: Binding(get: { surface.material }, set: { value in
                        model.queueAppearanceSurfaceEdit(spaceID: id, profileID: profile, material: value)
                    })) {
                        ForEach(BrowserThemeSurface.Material.allCases, id: \.self) { value in
                            Text(OrbitThemeSurfaceText.material(value)).tag(value)
                        }
                    }.accessibilityIdentifier("settings-appearance-material")
                    Slider(value: Binding(get: { surface.transparency }, set: { value in
                        model.queueAppearanceSurfaceEdit(spaceID: id, profileID: profile, transparency: value)
                    }), in: 0...1) { Text(uiText("Transparency")) }
                        .disabled(surface.material == .solid)
                        .accessibilityIdentifier("settings-appearance-transparency")
                    LabeledContent(uiText("Transparency"), value: surface.transparency.formatted(.percent.precision(.fractionLength(0))))
                    Text(OrbitThemeSurfaceText.capability).font(.caption).foregroundStyle(.secondary)
                    Text(uiText("Transparency reveals the blurred desktop through the theme. Reduce Transparency and Increase Contrast use an opaque theme. Choose Solid for full opacity."))
                        .font(.caption).foregroundStyle(.secondary)
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
