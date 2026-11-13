import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import SwiftUI

enum OrbitSettingsStyle {
    static let destructiveColor = NSColor.systemRed
    static let foreground = Color(nsColor: BrandPalette.ink)
    static let background = Color(nsColor: BrandPalette.paper)
    static let panel = Color(nsColor: BrandPalette.pageWhite)
    static let border = Color(nsColor: BrandPalette.ink.withAlphaComponent(0.13))
    static let windowColor = BrandPalette.paper
    static let toolbarColor = BrandPalette.paper
    static let selectionColor = BrandPalette.ink.withAlphaComponent(0.07)

}

@MainActor
struct BrowserOrbitSettingsPanes<Engine: BrowserEngine>: View {
    @ObservedObject var model: BrowserSettingsModel<Engine>
    @ObservedObject var runtime: BrowserSettingsRuntime
    let deleteProfile: (BrowserProfile) -> Void
    @State private var newProfileName = ""
    @State private var showsNewProfile = false
    @FocusState private var newProfileFocused: Bool
    @State private var newSpaceName = ""
    @State private var shortcutQuery = ""
    @State private var showsAirTrafficControl = false
    @State private var archiveChange: BrowserArchiveSettingsChange?
    @State private var renamingProfile: BrowserProfile?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.settingsSection != .profiles && model.settingsSection != .links && model.settingsSection != .about {
                    HStack(spacing: 8) {
                        if let section = model.settingsSection, section != .general {
                            SettingsPaneIcon(section: section).frame(width: 22, height: 22)
                        }
                        Text((model.settingsSection ?? .general).title).font(Font(BrandTextStyle.title.font(size: model.settingsSection == .general ? 25 : 21))).kerning(BrandTextStyle.title.tracking(size: model.settingsSection == .general ? 25 : 21))
                    }.padding(.bottom, 6)
                }
                switch model.settingsSection ?? .general {
                case .general: general
                case .profiles: profiles
                case .shortcuts: shortcuts
                case .links: links
                case .about: about
                case .advanced: advanced
                case .ai: BrowserSettingsAIPane(model: model, runtime: runtime, ai: model.environment.ai)
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 20)
            .padding(.top, 18).padding(.bottom, 16)
        }
        .scrollIndicators(.automatic)
        .font(Font(BrandFonts.ui(12)))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(runtime.isUnavailable)
        .accessibilityIdentifier("settings-pane-" + (model.settingsSection ?? .general).rawValue)
        .sheet(isPresented: Binding(get: { renamingProfile != nil }, set: { if !$0 { renamingProfile = nil } })) {
          if let profile = renamingProfile {
            BrowserSettingsRenameForm(name: profile.name, error: model.errorMessage, save: { name in
                model.perform { try await model.renameProfile(profile.id, name: name); renamingProfile = nil }
            }, cancel: { renamingProfile = nil })
          }
        }
        .sheet(item: $archiveChange) { change in
            VStack(alignment: .leading, spacing: 16) {
                Text(change.title).font(Font(BrandTextStyle.ui.font(size: 22, weight: .semibold)))
                Text(uiFormat("Would you like to apply this change to all of your Profiles, or only your %@ Profile?", change.profileName))
                    .foregroundStyle(.secondary)
                HStack {
                    Button(uiText("Cancel")) { archiveChange = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(uiText("Only this Profile")) {
                        archiveChange = nil
                        model.perform { try await model.setArchiveThreshold(change.threshold, profile: change.profile) }
                    }
                    Button(uiText("All Profiles")) {
                        archiveChange = nil
                        model.perform { try await model.setArchiveThreshold(change.threshold, profile: change.profile, allProfiles: true) }
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(22).frame(width: 440).settingsFrost()
        }
    }

    private var general: some View {
        Group {
            if model.environment.sync.showsSettings {
                BrowserSyncSettingsRow(runtime: model.environment.sync) { value in
                    model.perform { try await model.environment.sync.setEnabled(value) }
                }
            }
            panel {
                settingRow("Default browser", subtitle: "Links from other apps open in Circa") {
                    BrowserDefaultBrowserAction(isDefault: model.defaultStatus?.isOrbit == true,
                        canRequest: model.canRequestDefaultBrowser && !model.isRequestingDefaultBrowser) {
                            model.perform { try await model.requestDefaultBrowser() }
                        }
                }
                if let profile = model.selectedProfileID {
                    rule
                    settingRow("Search engine") {
                        SettingsPopupPicker(uiText("Search engine"), selectedTitle: SettingsPopupLabels.search(runtime.document.profile(profile).searchEngine), selection: Binding(get: { runtime.document.profile(profile).searchEngine }, set: { value in
                            model.perform { try await model.updateProfile(profile) { $0.searchEngine = value } }
                        })) {
                            Text("Google").tag(SearchEngine.google)
                            Text("DuckDuckGo").tag(SearchEngine.duckDuckGo)
                            Text("Bing").tag(SearchEngine.bing)
                        }.labelsHidden().frame(width: 135).accessibilityIdentifier("settings-search-engine")
                    }
                    rule
                    liveToggle("Show search suggestions", value: runtime.document.profile(profile).showSearchSuggestions,
                               identifier: "settings-search-suggestions") { value in
                        try await model.updateProfile(profile) { $0.showSearchSuggestions = value }
                    }
                }
            }
            panel {
                Button { model.navigate(to: .profiles) } label: {
                    HStack(spacing: 12) {
                        SettingsRowLabel(title: uiText("Profile Settings"),
                            subtitle: uiText("Manage your default search engine and Auto-Archive in Profile Settings."))
                        Spacer()
                        OrbitIcon.view(sfName: "chevron.right", pointSize: 14).frame(width: 14, height: 14)
                    }.padding(.horizontal, 13).padding(.vertical, 9).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("settings-open-profiles")
            }
            panel {
                settingRow("Save downloads to") {
                    Button { model.chooseDownloadFolder?() } label: {
                        Text(runtime.document.downloads.folderURL.lastPathComponent).lineLimit(1)
                    }.help(runtime.document.downloads.folderURL.path).accessibilityIdentifier("settings-download-folder")
                }
                rule
                liveToggle("Ask where to save each file", value: runtime.document.downloads.asksWhereToSave,
                           identifier: "settings-ask-download-location") { value in
                    try await runtime.updateDownloads { $0.asksWhereToSave = value }
                }
            }
            SettingsGroupLabel(title: uiText("Archive"))
            panel {
                if let profile = model.selectedProfileID {
                    settingRow("Archive tabs after", subtitle: "Pinned tabs and Favorites are never auto-archived.") {
                        SettingsPopupPicker(uiText("Archive tabs after"), selectedTitle: model.archiveThreshold.map(BrowserArchiveSettingsChange.label) ?? "", selection: Binding(get: { model.archiveThreshold }, set: { value in
                            guard let value else { return }
                            if model.catalog.profiles.count > 1 {
                                archiveChange = .init(profile: profile, profileName: model.catalog.profiles.first(where: { $0.id == profile })?.name ?? "", threshold: value)
                            } else { model.perform { try await model.setArchiveThreshold(value, profile: profile) } }
                        })) {
                            ForEach(BrowserArchiveSettingsChange.options(current: model.archiveThreshold), id: \.self) { threshold in
                                Text(BrowserArchiveSettingsChange.label(threshold)).tag(Optional(threshold))
                            }
                        }.labelsHidden().frame(width: 135).accessibilityIdentifier("settings-auto-archive")
                    }
                    rule
                }
                settingRow("Archive Little Circas after") {
                    SettingsPopupPicker(uiText("Archive Little Circas after"), selectedTitle: BrowserQuickWindowArchiveSettings.title(runtime.document.quickWindowArchiveThreshold), selection: Binding(get: { runtime.document.quickWindowArchiveThreshold }, set: { value in
                        model.perform { try await runtime.setQuickWindowArchiveThreshold(value) }
                    })) {
                        ForEach(BrowserQuickWindowArchiveSettings.choices, id: \.self) { choice in
                            Text(BrowserQuickWindowArchiveSettings.title(choice)).tag(choice)
                        }
                    }.labelsHidden().frame(width: 135).accessibilityIdentifier("settings-little-archive")
                }
            }
            SettingsGroupLabel(title: uiText("Little Circa & Peek"))
            panel {
                Toggle(uiText("Links from other apps open in Little Circa"), isOn: Binding(get: { runtime.document.opensExternalLinksInQuickWindow }, set: { value in
                    model.perform { try await runtime.setOpensExternalLinksInQuickWindow(value) }
                })).toggleStyle(SettingsSwitchStyle()).padding(.horizontal, 13).padding(.vertical, 9).accessibilityIdentifier("settings-external-little-orbit")
                if let profile = model.selectedProfileID {
                    rule
                    Toggle(isOn: Binding(get: { runtime.document.profile(profile).opensPinnedLinksInPeek }, set: { value in
                        model.perform { try await model.updateProfile(profile) { $0.opensPinnedLinksInPeek = value } }
                    })) {
                        SettingsRowLabel(title: uiText("Open a Peek window when clicking on links to other sites"),
                            subtitle: uiText("Note: This only affects Favorites and Pinned tabs"))
                    }.toggleStyle(SettingsSwitchStyle()).padding(.horizontal, 13).padding(.vertical, 9).accessibilityIdentifier("settings-pinned-peek")
                    rule
                    Toggle(uiText("Open a Peek window when clicking on links with Shift held"), isOn: Binding(get: { runtime.document.profile(profile).shiftClickOpensPeek }, set: { value in
                        model.perform { try await model.updateProfile(profile) { $0.shiftClickOpensPeek = value } }
                    })).toggleStyle(SettingsSwitchStyle()).padding(.horizontal, 13).padding(.vertical, 9).accessibilityIdentifier("settings-shift-peek")
                }
            }
            panel {
                settingRow(uiFormat("Automatically update my %@", applicationName)) {
                    BrowserAutomaticUpdateToggle(updater: runtime.updater)
                }
                rule
                liveToggle("Warn before quitting", value: runtime.document.interaction.warnBeforeQuitting,
                           identifier: "settings-warn-before-quitting", save: model.setWarnBeforeQuitting)
            }
        }
    }

    private var profiles: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.catalog.profiles, id: \.id) { profile in
                    Button { model.selectProfile(profile.id) } label: {
                        HStack(spacing: 8) {
                            BrowserSettingsThemeSwatch(theme: profileTheme(profile.id))
                            Text(profile.name).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 9)
                        .background(model.selectedProfileID == profile.id ? Color.accentColor : .clear,
                                    in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.selectedProfileID == profile.id ? .white : OrbitSettingsStyle.foreground)
                    .accessibilityAddTraits(model.selectedProfileID == profile.id ? .isSelected : [])
                    .accessibilityIdentifier("settings-profile-" + profile.id.rawValue.uuidString)
                }
                if showsNewProfile {
                    TextField(uiText("Profile Name"), text: $newProfileName)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("settings-new-profile-name")
                        .focused($newProfileFocused)
                    HStack {
                        Button(uiText("Cancel")) { showsNewProfile = false }
                        Button(uiText("New Profile")) {
                            let name = newProfileName
                            model.perform {
                                try await model.createProfile(name: name)
                                if newProfileName == name { newProfileName = ""; showsNewProfile = false }
                            }
                        }.disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("settings-create-profile")
                    }
                } else {
                    Button {
                        showsNewProfile = true; newProfileFocused = true
                    } label: {
                        HStack(spacing: 8) {
                            OrbitIcon.view(sfName: "plus", pointSize: 14).font(.system(size: 14))
                            Text(uiText("New Profile"))
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 8).padding(.vertical, 9).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-new-profile")
                }
            }.frame(width: 150)
                .onAppear { if model.focusNewProfile { showsNewProfile = true; newProfileFocused = true; model.focusNewProfile = false } }
                .onChange(of: model.focusNewProfile) { _, value in
                    if value { showsNewProfile = true; newProfileFocused = true; model.focusNewProfile = false }
                }
            VStack(alignment: .leading, spacing: 16) {
                if let profile = model.selectedProfileID,
                   let entry = model.catalog.profiles.first(where: { $0.id == profile }) {
                    HStack(spacing: 10) {
                        BrowserSettingsThemeSwatch(theme: profileTheme(profile)).scaleEffect(1.65).frame(width: 30, height: 30)
                        Text(entry.name).font(Font(BrandTextStyle.title.font(size: 25))).kerning(BrandTextStyle.title.tracking(size: 25))
                        Spacer()
                        Button(uiText("Rename")) { renamingProfile = entry }.accessibilityIdentifier("settings-rename-profile")
                    }
                    panel {
                        settingRow("Search engine") {
                            SettingsPopupPicker(uiText("Search engine"), selectedTitle: SettingsPopupLabels.search(runtime.document.profile(profile).searchEngine), selection: Binding(get: { runtime.document.profile(profile).searchEngine }, set: { value in
                                model.perform { try await model.updateProfile(profile) { $0.searchEngine = value } }
                            })) {
                                Text("Google").tag(SearchEngine.google)
                                Text("DuckDuckGo").tag(SearchEngine.duckDuckGo)
                                Text("Bing").tag(SearchEngine.bing)
                            }.labelsHidden().frame(width: 135).accessibilityIdentifier("settings-search-engine")
                        }
                        rule
                        liveToggle("Show search suggestions", value: runtime.document.profile(profile).showSearchSuggestions,
                                   identifier: "settings-search-suggestions") { value in
                            try await model.updateProfile(profile) { $0.showSearchSuggestions = value }
                        }
                        rule
                        settingRow("Archive tabs after", subtitle: "Pinned tabs and Favorites are never auto-archived.") {
                            SettingsPopupPicker(uiText("Archive tabs after"), selectedTitle: model.archiveThreshold.map(BrowserArchiveSettingsChange.label) ?? "", selection: Binding(get: { model.archiveThreshold }, set: { value in
                                guard let value else { return }
                                if model.catalog.profiles.count > 1 {
                                    archiveChange = .init(profile: profile, profileName: entry.name, threshold: value)
                                } else {
                                    model.perform { try await model.setArchiveThreshold(value, profile: profile) }
                                }
                            })) {
                                ForEach(BrowserArchiveSettingsChange.options(current: model.archiveThreshold), id: \.self) { threshold in
                                    Text(BrowserArchiveSettingsChange.label(threshold)).tag(Optional(threshold))
                                }
                            }.labelsHidden().frame(width: 110).accessibilityIdentifier("settings-auto-archive")
                        }
                    }
                    panel {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(uiText("Spaces")).fontWeight(.medium)
                                ViewThatFits(in: .horizontal) {
                                    spaceChips(profile)
                                    Text(model.catalog.spaces.filter { $0.profileID == profile }.map(\.name).joined(separator: ", "))
                                        .font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Button(uiText("Edit…")) { model.navigate(to: .spaces) }.accessibilityIdentifier("settings-edit-spaces")
                        }.padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 62)
                    }
                    panel {
                        settingRow("Extensions", icon: "puzzlepiece.extension") {
                            Button(uiText("Manage…")) { open(.extensions, profile: profile) }
                                .disabled(!model.canOpenExtensionSettings(profile: profile))
                                .accessibilityIdentifier("settings-manage-extensions")
                        }
                        rule
                        settingRow("Languages and site settings", icon: "arrow.down.circle") {
                            Button(uiText("More Settings…")) { open(.chromium, profile: profile) }
                                .disabled(!model.canOpenChromiumSettings(profile: profile))
                                .accessibilityIdentifier("settings-chromium-profile")
                        }
                    }
                    if !model.catalog.spaces.contains(where: { $0.profileID == profile }) {
                        Text(uiText("Create a Space to start browsing with this Profile.")).foregroundStyle(.secondary)
                        HStack {
                            TextField(uiText("Space Name"), text: $newSpaceName).textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("settings-new-space-name")
                            Button(uiText("Create Space")) {
                                let name = newSpaceName
                                model.perform { try await model.createSpace(name: name, profile: profile); newSpaceName = "" }
                            }.disabled(newSpaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("settings-create-space")
                        }
                    }
                    HStack {
                        Button(uiText("Delete Profile…"), role: .destructive) { deleteProfile(entry) }.settingsDestructive()
                            .disabled(model.profileRemovalUnavailableReason != nil)
                            .help(model.profileRemovalUnavailableReason ?? uiText("Delete this Profile"))
                            .accessibilityIdentifier("settings-delete-profile")
                    }
                    if let reason = model.profileRemovalUnavailableReason {
                        Text(reason).font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var links: some View {
        Group {
            HStack(spacing: 15) {
                OrbitIcon.view(sfName: "macwindow.on.rectangle", pointSize: 38, weight: .ultraLight).font(.system(size: 38, weight: .ultraLight)).foregroundStyle(OrbitSettingsStyle.foreground)
                VStack(alignment: .leading, spacing: 5) {
                    Text(uiText("Little Circa")).font(Font(BrandTextStyle.title.font(size: 25))).kerning(BrandTextStyle.title.tracking(size: 25))
                    Text(uiText("A smaller, simpler window for quick lookups and links from other apps."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.vertical, 8)
            panel {
                Toggle(uiText("Links from other apps open in Little Circa"), isOn: Binding(get: { runtime.document.opensExternalLinksInQuickWindow }, set: { value in
                    model.perform { try await runtime.setOpensExternalLinksInQuickWindow(value) }
                })).toggleStyle(SettingsSwitchStyle()).padding(12).accessibilityIdentifier("settings-external-little-orbit")
            }
            HStack {
                SettingsGroupLabel(title: uiText("Peek"))
                Spacer()
                profilePicker
            }
            if let profile = model.selectedProfileID {
                panel {
                    Toggle(isOn: Binding(get: { runtime.document.profile(profile).opensPinnedLinksInPeek }, set: { value in
                        model.perform { try await model.updateProfile(profile) { $0.opensPinnedLinksInPeek = value } }
                    })) {
                        SettingsRowLabel(title: uiText("Open a Peek window when clicking on links to other sites"),
                            subtitle: uiText("Note: This only affects Favorites and Pinned tabs"))
                    }.padding(12).accessibilityIdentifier("settings-pinned-peek")
                    rule
                    Toggle(uiText("Open a Peek window when clicking on links with Shift held"), isOn: Binding(get: { runtime.document.profile(profile).shiftClickOpensPeek }, set: { value in
                        model.perform { try await model.updateProfile(profile) { $0.shiftClickOpensPeek = value } }
                    })).padding(12).accessibilityIdentifier("settings-shift-peek")
                }.toggleStyle(SettingsSwitchStyle())
            }
            panel {
                settingRow(uiFormat("Choose where links open inside %@.", applicationName), icon: "arrow.turn.down.right") {
                    Button(uiText("Air Traffic Control…")) { showsAirTrafficControl = true }
                        .accessibilityIdentifier("settings-air-traffic-control")
                        .sheet(isPresented: $showsAirTrafficControl) {
                            BrowserAirTrafficControlView(model: model, runtime: runtime)
                        }
                }
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 18) {
            panel {
                settingRow("Site Search") {
                    Button(uiText("Manage")) { model.showsSiteSearchSettings = true }
                        .accessibilityIdentifier("settings-site-search-manage")
                        .sheet(isPresented: $model.showsSiteSearchSettings) {
                            BrowserSiteSearchSettings(model: model, runtime: runtime)
                        }
                }
            }
            BrowserShortcutSettingsPane(preferences: model.environment.shortcutPreferences,
                definitions: model.settingsShortcuts,
                openExtensionSettings: model.selectedProfileID.map { profile in { open(.extensionShortcuts, profile: profile) } },
                extensionSettingsAvailable: model.selectedProfileID.map { model.canOpenExtensionSettings(profile: $0) } ?? false)
        }
    }

    private var about: some View {
        BrowserSettingsAbout(updater: runtime.updater)
    }

    private var advanced: some View {
        Group {
            panel {
                liveToggle("Allow JavaScript from Apple Events",
                           value: runtime.document.allowJavaScriptFromAppleEvents,
                           identifier: "settings-apple-events-javascript", save: runtime.setAllowJavaScriptFromAppleEvents)
                rule
                liveToggle("Enable Picture in Picture when you leave a video tab",
                           value: runtime.document.automaticPictureInPicture,
                           identifier: "settings-automatic-pip", icon: "rectangle.on.rectangle", save: model.setAutomaticPictureInPicture)
                rule
                HStack(spacing: 12) {
                  OrbitIcon.view(sfName: "paintbrush.pointed", pointSize: 20).font(.system(size: 20)).frame(width: 20, height: 20)
                  Toggle(BrowserSettingsRuntime.enablesBoostsTitle, isOn: Binding(
                    get: { runtime.document.enablesBoostsOnWebsites },
                    set: { value in model.perform { try await runtime.setEnablesBoostsOnWebsites(value) } }
                )).toggleStyle(SettingsSwitchStyle()).accessibilityIdentifier("settings-enables-boosts")
                }.padding(.horizontal, 13).padding(.vertical, 9).frame(minHeight: 38)
            }
            panel {
                settingRow("Put inactive tabs to sleep after", icon: "moon.stars") {
                    SettingsPopupPicker(uiText("Memory Saver"), selectedTitle: SettingsPopupLabels.memory(runtime.document.memorySaver), selection: Binding(get: { runtime.document.memorySaver }, set: { value in
                        model.perform { try await model.setMemorySaver(value) }
                    })) {
                        Text(uiText("5 minutes")).tag(BrowserMemorySaverSetting.fiveMinutes)
                        Text(uiText("15 minutes")).tag(BrowserMemorySaverSetting.fifteenMinutes)
                        Text(uiText("30 minutes")).tag(BrowserMemorySaverSetting.thirtyMinutes)
                        Text(uiText("1 hour")).tag(BrowserMemorySaverSetting.oneHour)
                        Text(uiText("2 hours")).tag(BrowserMemorySaverSetting.twoHours)
                        Text(uiText("4 hours")).tag(BrowserMemorySaverSetting.fourHours)
                        Text(uiText("6 hours")).tag(BrowserMemorySaverSetting.sixHours)
                        Text(uiText("Never")).tag(BrowserMemorySaverSetting.never)
                    }.labelsHidden().frame(width: 140).accessibilityIdentifier("settings-memory-saver")
                        .help(uiText("Keeps pinned tabs, edited forms and active media awake. Sleeping tabs reload when selected."))
                }
                rule
                settingRow("Animations", icon: "sparkles") {
                    Picker(uiText("Animations"), selection: Binding(get: { runtime.document.reducedMotion }, set: { value in
                        model.perform { try await model.setReducedMotion(value) }
                    })) {
                        Text(uiText("Follow System")).tag(BrowserReducedMotionSetting.system)
                        Text(uiText("Reduce Motion")).tag(BrowserReducedMotionSetting.reduce)
                        Text(uiText("Full Motion")).tag(BrowserReducedMotionSetting.full)
                    }.labelsHidden().pickerStyle(.segmented)
                        .tint(Color(nsColor: .controlColor)).foregroundStyle(OrbitSettingsStyle.foreground)
                        .frame(width: 300).accessibilityIdentifier("settings-reduced-motion")
                }
                rule
                liveToggle("Show tab hover previews", value: runtime.document.showsTabHoverPreviews,
                           identifier: "settings-tab-hover-previews", icon: "rectangle.on.rectangle",
                           save: runtime.setShowsTabHoverPreviews)
                rule
                liveToggle("Space around pages", value: runtime.document.showsSpaceAroundPages,
                           identifier: "settings-space-around-pages", icon: "rectangle.inset.filled",
                           save: model.setShowsSpaceAroundPages)
                rule
                liveToggle(uiFormat("Play %@ sound effects", applicationName), value: runtime.document.interaction.playSoundEffects,
                           identifier: "settings-sound-effects", icon: "speaker.wave.2", save: model.setPlaySoundEffects)
                rule
                liveToggle("Haptic feedback for tab organization and resizing", value: runtime.document.interaction.hapticFeedback,
                           identifier: "settings-reorder-haptics", icon: "hand.raised", save: model.setHapticFeedback)
            }
            panel { BrowserOverlayScrollbarsSettingsRow(model: model) }
            panel {
                liveToggle("Use dots for Space icons", value: runtime.document.usesDotsForSpaceIcons,
                           identifier: "settings-space-icon-dots", save: runtime.setUsesDotsForSpaceIcons)
            }
            panel {
                settingRow("Website data and permissions", icon: "lock") {
                    Button(uiText("Manage…")) { model.navigate(to: .privacy) }
                        .accessibilityIdentifier("settings-site-data")
                }
            }
            panel {
                BrowserSafeBrowsingSettingsRow(model: model)
                    .padding(14)
            }
        }
    }

    private func profileTheme(_ profile: ProfileID) -> BrowserSpaceTheme? {
        guard let space = model.catalog.spaces.first(where: { $0.profileID == profile }) else { return nil }
        return space.theme ?? runtime.document.space(space.id).palette.themeModel
    }

    private func spaceChips(_ profile: ProfileID) -> some View {
        HStack(spacing: 6) {
            ForEach(model.catalog.spaces.filter { $0.profileID == profile }, id: \.id) { space in
                HStack(spacing: 5) {
                    BrowserSettingsThemeSwatch(theme: space.theme ?? runtime.document.space(space.id).palette.themeModel)
                        .scaleEffect(0.85).frame(width: 16, height: 16)
                    Text(space.name).lineLimit(1)
                }.padding(.horizontal, 5).padding(.vertical, 4)
                    .background(OrbitSettingsStyle.background, in: Capsule())
            }
        }
    }

    private var profilePicker: some View {
        Group {
            if let profile = model.selectedProfileID {
                SettingsPopupPicker(uiText("Profile"), selectedTitle: model.catalog.profiles.first(where: { $0.id == profile })?.name ?? "", selection: Binding(get: { profile }, set: { model.selectProfile($0) })) {
                    ForEach(model.catalog.profiles, id: \.id) { Text($0.name).tag($0.id) }
                }.labelsHidden().frame(maxWidth: 190).accessibilityIdentifier("settings-profile")
            }
        }
    }

    private var applicationName: String { BrowserCommandMenus<BrowserWindowController<Engine>>.applicationDisplayName }
    private var filteredShortcuts: [BrowserCommandDefinition] {
        let query = shortcutQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.settingsShortcuts.filter { query.isEmpty || $0.localizedTitle.localizedStandardContains(query) || $0.menu.localizedStandardContains(query) }
    }
    private var appIcon: some View {
        SettingsAppIcon()
    }
    private var rule: some View { SettingsRule() }
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OrbitSettingsStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OrbitSettingsStyle.border, lineWidth: 1))
    }
    private func settingRow<Control: View>(_ title: String, icon: String? = nil, subtitle: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            if let icon { OrbitIcon.view(sfName: icon, pointSize: 20).font(.system(size: 20)).frame(width: 20, height: 20) }
            SettingsRowLabel(title: uiText(title), subtitle: subtitle.map { uiText($0) })
            Spacer(minLength: 8); control()
        }
            .padding(.horizontal, 13).padding(.vertical, 9).frame(minHeight: 38)
    }
    private func liveToggle(_ title: String, value: Bool, identifier: String, icon: String? = nil,
                            save: @escaping (Bool) async throws -> Void) -> some View {
        settingRow(title, icon: icon) {
            Toggle(uiText(title), isOn: Binding(get: { value }, set: { next in
                model.perform { try await save(next) }
            })).labelsHidden().toggleStyle(SettingsSwitchControlStyle()).controlSize(.small).accessibilityIdentifier(identifier)
        }
    }
    private func open(_ page: BrowserSettingsPage, profile: ProfileID) {
        model.perform { try await model.openBrowserSettings(page, profile: profile) }
    }
}

@MainActor
private struct BrowserAutomaticUpdateToggle: View {
    @ObservedObject var updater: OrbitUpdater
    var body: some View {
        Toggle(uiText("Automatically update"), isOn: Binding(get: { updater.automaticallyUpdates },
            set: { updater.setAutomaticallyUpdates($0) }))
            .labelsHidden().toggleStyle(SettingsSwitchControlStyle()).controlSize(.small)
            .accessibilityIdentifier("settings-automatic-updates")
    }
}

@MainActor
private struct BrowserSyncSettingsRow: View {
    @ObservedObject var runtime: BrowserSyncRuntime
    let save: (Bool) -> Void
    var body: some View {
        HStack(spacing: 12) {
            OrbitIcon.view(sfName: "arrow.clockwise", pointSize: 20).font(.system(size: 20)).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(uiText("Sync with iCloud")).fontWeight(.medium)
                Text(runtime.statusText).font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-icloud-sync-status")
            }
                Spacer()
                Toggle(uiText("Sync with iCloud"), isOn: Binding(get: { runtime.enabled }, set: save))
                    .labelsHidden().toggleStyle(SettingsSwitchControlStyle()).controlSize(.small)
                    .disabled(!runtime.available).accessibilityIdentifier("settings-icloud-sync")
        }
        .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 50).frame(maxWidth: .infinity, alignment: .leading)
        .background(OrbitSettingsStyle.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OrbitSettingsStyle.border, lineWidth: 1))
        .alert(uiText("Use a different iCloud account?"), isPresented: $runtime.needsAccountDecision) {
            Button(uiText("Keep Sync Off"), role: .cancel) {}
            Button(uiText("Try Again")) { save(true) }
        } message: {
            Text(uiText("Your local data belongs to the previous iCloud account. To keep accounts separate, sign back into that account before trying again. Your local data will stay on this Mac."))
        }
    }
}
