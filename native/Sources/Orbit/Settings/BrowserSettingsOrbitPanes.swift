import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import SwiftUI

enum OrbitSettingsStyle {
    static let foreground = color(light: 0x141317, dark: 0xF4F1EC)
    static let background = Color(nsColor: windowColor)
    static let panel = color(light: 0xFFFFFF, dark: 0x222128)
    static let border = Color.primary.opacity(0.09)
    static let windowColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? BrandPalette.stage2 : BrandPalette.paper
    }
    static let toolbarColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? BrandPalette.rgb(0x1E1E24) : .white
    }
    static let selectionColor = NSColor(name: nil) { appearance in
        (appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor.white : NSColor.black).withAlphaComponent(0.07)
    }

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

@MainActor
struct BrowserOrbitSettingsPanes<Engine: BrowserEngine>: View {
    @ObservedObject var model: BrowserSettingsModel<Engine>
    @ObservedObject var runtime: BrowserSettingsRuntime
    let deleteProfile: (BrowserProfile) -> Void
    @State private var newProfileName = ""
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
                    Text((model.settingsSection ?? .general).title).font(Font(BrandTextStyle.title.font(size: 28))).padding(.bottom, 6)
                }
                switch model.settingsSection ?? .general {
                case .general: general
                case .profiles: profiles
                case .shortcuts: shortcuts
                case .links: links
                case .about: about
                case .advanced: advanced
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28)
            .padding(.top, 22).padding(.bottom, 26)
        }
        .scrollIndicators(.automatic)
        .font(Font(BrandFonts.ui(13)))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(runtime.isUnavailable)
        .accessibilityIdentifier("settings-pane-" + (model.settingsSection ?? .general).rawValue)
        .sheet(isPresented: Binding(get: { renamingProfile != nil }, set: { if !$0 { renamingProfile = nil } })) {
          if let profile = renamingProfile {
            VStack(alignment: .leading, spacing: 16) {
                Text(uiText("Rename")).font(Font(BrandTextStyle.title.font(size: 22)))
                BrowserSettingsNameEditor(name: profile.name) { name in
                    model.perform { try await model.renameProfile(profile.id, name: name); renamingProfile = nil }
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red).font(Font(BrandFonts.ui(12))) }
                HStack { Spacer(); Button(uiText("Cancel")) { renamingProfile = nil }.keyboardShortcut(.cancelAction) }
            }.padding(22).frame(width: 396).settingsFrost()
          }
        }
        .sheet(item: $archiveChange) { change in
            VStack(alignment: .leading, spacing: 16) {
                Text(change.title).font(Font(BrandTextStyle.title.font(size: 22)))
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
                settingRow(uiFormat("Automatically update my %@", applicationName)) {
                    BrowserAutomaticUpdateToggle(updater: runtime.updater)
                }
                rule
                liveToggle("Warn before quitting", value: runtime.document.interaction.warnBeforeQuitting,
                           identifier: "settings-warn-before-quitting", save: model.setWarnBeforeQuitting)
            }
            panel {
                Button { model.navigate(to: .profiles) } label: {
                    HStack(spacing: 12) {
                        OrbitIcon.view(sfName: "person.crop.circle", pointSize: 20).frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(uiText("Profile Settings")).fontWeight(.medium)
                            Text(uiText("Manage your default search engine, Auto-Archive, and downloads in Profile Settings."))
                                .font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                        }
                        Spacer()
                        OrbitIcon.view(sfName: "chevron.right", pointSize: 14).frame(width: 14, height: 14).foregroundStyle(.secondary)
                    }.padding(14).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("settings-open-profiles")
            }

            panel {
                HStack(spacing: 14) {
                    Image(nsImage: BrandFonts.mark ?? NSImage()).resizable().scaledToFit().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.defaultStatus?.isOrbit == true
                             ? uiFormat("%@ is your default web browser.", applicationName) : uiFormat("%@ is not your default web browser.", applicationName))
                    }
                    Spacer(minLength: 0)
                    Button(uiText("Make Default")) { model.perform { try await model.requestDefaultBrowser() } }
                        .disabled(!model.canRequestDefaultBrowser || model.isRequestingDefaultBrowser)
                        .accessibilityIdentifier("settings-default-browser")
                }.padding(8)
            }
        }
    }

    private var profiles: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(uiText("Profiles")).font(Font(BrandFonts.ui(12, weight: .semibold))).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.bottom, 8)
                ForEach(model.catalog.profiles, id: \.id) { profile in
                    Button { model.selectProfile(profile.id) } label: {
                        HStack(spacing: 8) {
                            OrbitIcon.view(sfName: "person.crop.circle", pointSize: 13)
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
                Divider().padding(.vertical, 8)
                TextField(uiText("Profile Name"), text: $newProfileName)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("settings-new-profile-name")
                    .focused($newProfileFocused)
                    .onAppear { newProfileFocused = model.focusNewProfile; model.focusNewProfile = false }
                    .onChange(of: model.focusNewProfile) { _, value in
                        if value { newProfileFocused = true; model.focusNewProfile = false }
                    }
                Button(uiText("New Profile"), systemImage: "plus") {
                    let name = newProfileName
                    model.perform {
                        try await model.createProfile(name: name)
                        if newProfileName == name { newProfileName = "" }
                    }
                }
                .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("settings-create-profile")
            }.frame(width: 136)
            VStack(alignment: .leading, spacing: 16) {
                if let profile = model.selectedProfileID,
                   let entry = model.catalog.profiles.first(where: { $0.id == profile }) {
                    HStack {
                        Text(entry.name).font(Font(BrandTextStyle.title.font(size: 28)))
                        Spacer()
                        Button(uiText("Rename")) { renamingProfile = entry }.accessibilityIdentifier("settings-rename-profile")
                    }
                    panel {
                        settingRow("Search engine") {
                            Picker(uiText("Search engine"), selection: Binding(get: { runtime.document.profile(profile).searchEngine }, set: { value in
                                model.perform { try await model.updateProfile(profile) { $0.searchEngine = value } }
                            })) {
                                Text("Google").tag(SearchEngine.google)
                                Text("DuckDuckGo").tag(SearchEngine.duckDuckGo)
                                Text("Bing").tag(SearchEngine.bing)
                            }.labelsHidden().pickerStyle(.menu).frame(width: 135).accessibilityIdentifier("settings-search-engine")
                        }
                        rule
                        settingRow("Archive tabs after") {
                            Picker(uiText("Archive tabs after"), selection: Binding(get: { model.archiveThreshold }, set: { value in
                                guard let value else { return }
                                if model.catalog.profiles.count > 1 {
                                    archiveChange = .init(profile: profile, profileName: entry.name, threshold: value)
                                } else {
                                    model.perform { try await model.setArchiveThreshold(value, profile: profile) }
                                }
                            })) {
                                Text(uiText("12 hours")).tag(Optional(BrowserAutoArchiveThreshold.twelveHours))
                                Text(uiText("24 hours")).tag(Optional(BrowserAutoArchiveThreshold.oneDay))
                                Text(uiText("7 days")).tag(Optional(BrowserAutoArchiveThreshold.sevenDays))
                                Text(uiText("30 days")).tag(Optional(BrowserAutoArchiveThreshold.thirtyDays))
                                if let current = model.archiveThreshold, !standardArchiveThresholds.contains(current) {
                                    Text(current == .never ? uiText("Never") : uiText("Custom Delay")).tag(Optional(current))
                                }
                            }.labelsHidden().pickerStyle(.menu).frame(width: 110).accessibilityIdentifier("settings-auto-archive")
                        }
                    }
                    Text(uiText("Pinned tabs and Favorites are never auto-archived.")).font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                    panel {
                        settingRow("Spaces") {
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(model.catalog.spaces.filter { $0.profileID == profile }.map(\.name).joined(separator: ", "))
                                    .font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                                Button(uiText("Edit…")) { model.navigate(to: .spaces) }
                                    .accessibilityIdentifier("settings-edit-spaces")
                            }
                        }
                    }
                    panel {
                        settingRow("Extensions") {
                            Button(uiText("Manage…")) { open(.extensions, profile: profile) }
                                .disabled(!model.canOpenExtensionSettings(profile: profile))
                                .accessibilityIdentifier("settings-manage-extensions")
                        }
                        rule
                        settingRow("Downloads, languages, and site settings") {
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
                        Spacer()
                        Button(uiText("Delete Profile…"), role: .destructive) { deleteProfile(entry) }
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
                OrbitIcon.view(sfName: "macwindow.on.rectangle", pointSize: 38).font(.system(size: 38, weight: .ultraLight)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 5) {
                    Text(uiText("Little Orbit")).font(Font(BrandTextStyle.title.font(size: 28)))
                    Text(uiText("A smaller, simpler window for quick lookups and links from other apps."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.vertical, 8)
            panel {
                Toggle(uiText("Links from other apps open in Little Orbit"), isOn: Binding(get: { runtime.document.opensExternalLinksInQuickWindow }, set: { value in
                    model.perform { try await runtime.setOpensExternalLinksInQuickWindow(value) }
                })).toggleStyle(SettingsSwitchStyle()).padding(12).accessibilityIdentifier("settings-external-little-orbit")
            }
            HStack {
                Text(uiText("Peek")).font(Font(BrandFonts.ui(14, weight: .semibold)))
                Spacer()
                profilePicker
            }
            if let profile = model.selectedProfileID {
                panel {
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle(uiText("Open a Peek window when clicking on links to other sites"), isOn: Binding(get: { runtime.document.profile(profile).opensPinnedLinksInPeek }, set: { value in
                            model.perform { try await model.updateProfile(profile) { $0.opensPinnedLinksInPeek = value } }
                        })).accessibilityIdentifier("settings-pinned-peek")
                        Text(uiText("Note: This only affects Favorites and Pinned tabs")).font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                    }.padding(12)
                    rule
                    Toggle(uiText("Open a Peek window when clicking on links with Shift held"), isOn: Binding(get: { runtime.document.profile(profile).shiftClickOpensPeek }, set: { value in
                        model.perform { try await model.updateProfile(profile) { $0.shiftClickOpensPeek = value } }
                    })).padding(12).accessibilityIdentifier("settings-shift-peek")
                }.toggleStyle(SettingsSwitchStyle())
            }
            panel {
                settingRow(uiFormat("Choose where links open inside %@.", applicationName)) {
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
        BrowserShortcutSettingsPane(preferences: model.environment.shortcutPreferences,
            definitions: model.settingsShortcuts, conflictDefinitions: model.shortcuts,
            openExtensionSettings: model.selectedProfileID.map { profile in { open(.extensionShortcuts, profile: profile) } },
            extensionSettingsAvailable: model.selectedProfileID.map { model.canOpenExtensionSettings(profile: $0) } ?? false)
    }

    private var about: some View {
        BrowserSettingsAbout(updater: runtime.updater)
    }

    private var advanced: some View {
        Group {
            panel {
                liveToggle("Enable Picture in Picture when you leave a video tab",
                           value: runtime.document.automaticPictureInPicture,
                           identifier: "settings-automatic-pip", save: model.setAutomaticPictureInPicture)
                Toggle(BrowserSettingsRuntime.enablesBoostsTitle, isOn: Binding(
                    get: { runtime.document.enablesBoostsOnWebsites },
                    set: { value in model.perform { try await runtime.setEnablesBoostsOnWebsites(value) } }
                )).toggleStyle(SettingsSwitchStyle()).padding(12).accessibilityIdentifier("settings-enables-boosts")
            }
            panel {
                settingRow("Put inactive tabs to sleep after") {
                    Picker(uiText("Memory Saver"), selection: Binding(get: { runtime.document.memorySaver }, set: { value in
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
                    }.labelsHidden().pickerStyle(.menu).frame(width: 140).accessibilityIdentifier("settings-memory-saver")
                        .help(uiText("Keeps pinned tabs, edited forms and active media awake. Sleeping tabs reload when selected."))
                }
                rule
                settingRow("Animations") {
                    Picker(uiText("Animations"), selection: Binding(get: { runtime.document.reducedMotion }, set: { value in
                        model.perform { try await model.setReducedMotion(value) }
                    })) {
                        Text(uiText("Follow System")).tag(BrowserReducedMotionSetting.system)
                        Text(uiText("Reduce Motion")).tag(BrowserReducedMotionSetting.reduce)
                        Text(uiText("Full Motion")).tag(BrowserReducedMotionSetting.full)
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 300).accessibilityIdentifier("settings-reduced-motion")
                }
                rule
                liveToggle(uiFormat("Play %@ sound effects", applicationName), value: runtime.document.interaction.playSoundEffects,
                           identifier: "settings-sound-effects", save: model.setPlaySoundEffects)
                rule
                liveToggle("Haptic feedback when reordering tabs", value: runtime.document.interaction.hapticFeedback,
                           identifier: "settings-reorder-haptics", save: model.setHapticFeedback)
            }
            panel {
                settingRow("Website data and permissions") {
                    Button(uiText("Manage…")) { model.navigate(to: .privacy) }
                        .accessibilityIdentifier("settings-site-data")
                }
            }
            Text(model.safeBrowsingAvailable ? uiText("Warnings for dangerous sites and downloads are on.")
                 : uiText("Safe Browsing is unavailable in this build."))
                .font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
        }
    }

    private var profilePicker: some View {
        Group {
            if let profile = model.selectedProfileID {
                Picker(uiText("Profile"), selection: Binding(get: { profile }, set: { model.selectProfile($0) })) {
                    ForEach(model.catalog.profiles, id: \.id) { Text($0.name).tag($0.id) }
                }.labelsHidden().pickerStyle(.menu).frame(maxWidth: 190).accessibilityIdentifier("settings-profile")
            }
        }
    }

    private var applicationName: String { BrowserCommandMenus<BrowserWindowController<Engine>>.applicationDisplayName }
    private var filteredShortcuts: [BrowserCommandDefinition] {
        let query = shortcutQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.settingsShortcuts.filter { query.isEmpty || $0.localizedTitle.localizedStandardContains(query) || $0.menu.localizedStandardContains(query) }
    }
    private var standardArchiveThresholds: [BrowserAutoArchiveThreshold] { [.twelveHours, .oneDay, .sevenDays, .thirtyDays] }
    private var appIcon: some View {
        SettingsAppIcon()
    }
    private var rule: some View { Rectangle().fill(OrbitSettingsStyle.border).frame(height: 1).padding(.horizontal, 8) }
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OrbitSettingsStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OrbitSettingsStyle.border, lineWidth: 1))
    }
    private func settingRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) { Text(uiText(title)).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 8); control() }
            .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
    }
    private func liveToggle(_ title: String, value: Bool, identifier: String,
                            save: @escaping (Bool) async throws -> Void) -> some View {
        settingRow(title) {
            Toggle(uiText(title), isOn: Binding(get: { value }, set: { next in
                model.perform { try await save(next) }
            })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityIdentifier(identifier)
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
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .accessibilityIdentifier("settings-automatic-updates")
    }
}

@MainActor
private struct BrowserSyncSettingsRow: View {
    @ObservedObject var runtime: BrowserSyncRuntime
    let save: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(uiText("Sync with iCloud"))
                Spacer()
                Toggle(uiText("Sync with iCloud"), isOn: Binding(get: { runtime.enabled }, set: save))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!runtime.available).accessibilityIdentifier("settings-icloud-sync")
            }
            Text(runtime.statusText).font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-icloud-sync-status")
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
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
