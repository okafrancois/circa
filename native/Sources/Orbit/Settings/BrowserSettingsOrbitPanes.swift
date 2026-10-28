import AppKit
import BrowserCore
import BrowserEngine
import SwiftUI

enum OrbitSettingsStyle {
    static let foreground = color(light: 0x3d3d3d, dark: 0xf3f3f3)
    static let background = color(light: 0xf2f1f3, dark: 0x272629)
    static let panel = color(light: 0xefedf0, dark: 0x2d2c2f)
    static let border = color(light: 0xdedce0, dark: 0x424145)

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch model.settingsSection ?? .general {
                case .general: general
                case .profiles: profiles
                case .shortcuts: shortcuts
                case .links: links
                case .icon: icon
                case .advanced: advanced
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, model.settingsSection == .profiles ? 24 : 64)
            .padding(.vertical, 20)
        }
        .scrollIndicators(.automatic)
        .font(.system(size: 13))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(runtime.isUnavailable)
        .accessibilityIdentifier("settings-pane-" + (model.settingsSection ?? .general).rawValue)
        .alert(item: $archiveChange) { change in
            Alert(title: Text(change.title),
                  message: Text(uiFormat("Would you like to apply this change to all of your Profiles, or only your %@ Profile?", change.profileName)),
                  primaryButton: .default(Text(uiText("All Profiles"))) {
                      model.perform { try await model.setArchiveThreshold(change.threshold, profile: change.profile, allProfiles: true) }
                  }, secondaryButton: .default(Text(uiText("Only this Profile"))) {
                      model.perform { try await model.setArchiveThreshold(change.threshold, profile: change.profile) }
                  })
        }
    }

    private var general: some View {
        Group {
            panel {
                settingRow(uiFormat("Automatically update my %@", applicationName)) {
                    BrowserAutomaticUpdateToggle(updater: runtime.updater)
                }
                rule
                liveToggle("Warn before quitting", value: runtime.document.interaction.warnBeforeQuitting,
                           identifier: "settings-warn-before-quitting", save: model.setWarnBeforeQuitting)
            }
            panel {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(uiText("Manage your default search engine, Auto-Archive, and downloads in Profile Settings."))
                            .fixedSize(horizontal: false, vertical: true)
                        Button(uiText("Profile Settings")) { model.settingsSection = .profiles }
                            .accessibilityIdentifier("settings-open-profiles")
                    }
                    Spacer(minLength: 0)
                }.padding(8)
            }
            panel {
                HStack(spacing: 14) {
                    appIcon.frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.defaultStatus?.isOrbit == true
                             ? uiFormat("%@ is your default web browser.", applicationName) : uiFormat("%@ is not your default web browser.", applicationName))
                        Button(uiText("Make Default")) { model.perform { try await model.requestDefaultBrowser() } }
                            .disabled(!model.canRequestDefaultBrowser || model.isRequestingDefaultBrowser)
                            .accessibilityIdentifier("settings-default-browser")
                    }
                    Spacer(minLength: 0)
                }.padding(8)
            }
        }
    }

    private var profiles: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(uiText("Profiles")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.bottom, 8)
                ForEach(model.catalog.profiles, id: \.id) { profile in
                    Button { model.selectProfile(profile.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle")
                            Text(profile.name).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 9)
                        .background(model.selectedProfileID == profile.id ? Color.blue.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.selectedProfileID == profile.id ? .blue : OrbitSettingsStyle.foreground)
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
                    Text(entry.name).font(.system(size: 21, weight: .semibold)).padding(.bottom, 2)
                    panel {
                        BrowserSettingsNameEditor(name: entry.name) { name in
                            model.perform { try await model.renameProfile(profile, name: name) }
                        }.id(profile).padding(9)
                        rule
                        settingRow("Search engine") {
                            Picker(uiText("Search engine"), selection: Binding(get: { runtime.document.profile(profile).searchEngine }, set: { value in
                                model.perform { try await model.updateProfile(profile) { $0.searchEngine = value } }
                            })) {
                                Text("Google").tag(SearchEngine.google)
                                Text("DuckDuckGo").tag(SearchEngine.duckDuckGo)
                                Text("Bing").tag(SearchEngine.bing)
                            }.labelsHidden().frame(width: 135).accessibilityIdentifier("settings-search-engine")
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
                            }.labelsHidden().frame(width: 110).accessibilityIdentifier("settings-auto-archive")
                        }
                    }
                    Text(uiText("Pinned tabs and Favorites are never auto-archived.")).font(.system(size: 11)).foregroundStyle(.secondary)
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
                        Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var links: some View {
        Group {
            HStack(spacing: 15) {
                Image(systemName: "macwindow.on.rectangle").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Little Orbit").font(.system(size: 20, weight: .semibold))
                    Text(uiText("A smaller, simpler window for quick lookups and links from other apps."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.vertical, 8)
            panel {
                Toggle(uiText("Links from other apps open in Little Orbit"), isOn: Binding(get: { runtime.document.opensExternalLinksInQuickWindow }, set: { value in
                    model.perform { try await runtime.setOpensExternalLinksInQuickWindow(value) }
                })).toggleStyle(.checkbox).padding(12).accessibilityIdentifier("settings-external-little-orbit")
            }
            HStack {
                Text("Peek").font(.system(size: 20, weight: .semibold))
                Spacer()
                profilePicker
            }
            if let profile = model.selectedProfileID {
                panel {
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle(uiText("Open a Peek window when clicking on links to other sites"), isOn: Binding(get: { runtime.document.profile(profile).opensPinnedLinksInPeek }, set: { value in
                            model.perform { try await model.updateProfile(profile) { $0.opensPinnedLinksInPeek = value } }
                        })).accessibilityIdentifier("settings-pinned-peek")
                        Text(uiText("Note: This only affects Favorites and Pinned tabs")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 19)
                    }.padding(12)
                    rule
                    Toggle(uiText("Open a Peek window when clicking on links with Shift held"), isOn: Binding(get: { runtime.document.profile(profile).shiftClickOpensPeek }, set: { value in
                        model.perform { try await model.updateProfile(profile) { $0.shiftClickOpensPeek = value } }
                    })).padding(12).accessibilityIdentifier("settings-shift-peek")
                }.toggleStyle(.checkbox)
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
        Group {
            HStack {
                if let profile = model.selectedProfileID {
                    Button(uiText("Extension Shortcuts…")) { open(.extensionShortcuts, profile: profile) }
                        .disabled(!model.canOpenExtensionSettings(profile: profile))
                        .accessibilityIdentifier("settings-extension-shortcuts")
                }
            }
            BrowserShortcutSettingsPane(preferences: model.environment.shortcutPreferences,
                definitions: model.settingsShortcuts, conflictDefinitions: model.shortcuts)

        }
    }

    private var icon: some View {
        VStack(spacing: 20) {
            appIcon.frame(width: 112, height: 112).padding(.top, 24)
            Text(uiText("App Icon")).font(.system(size: 21, weight: .semibold))
            Text(uiFormat("%@ uses its current app icon.", applicationName)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private var advanced: some View {
        Group {
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
                    }.labelsHidden().frame(width: 140).accessibilityIdentifier("settings-memory-saver")
                }
                Text(uiText("Keeps pinned tabs, edited forms and active media awake. Sleeping tabs reload when selected."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
            }
            panel {
                settingRow("Animations") {
                    Picker(uiText("Animations"), selection: Binding(get: { runtime.document.reducedMotion }, set: { value in
                        model.perform { try await model.setReducedMotion(value) }
                    })) {
                        Text(uiText("Follow System")).tag(BrowserReducedMotionSetting.system)
                        Text(uiText("Reduce Motion")).tag(BrowserReducedMotionSetting.reduce)
                        Text(uiText("Full Motion")).tag(BrowserReducedMotionSetting.full)
                    }.labelsHidden().frame(width: 140).accessibilityIdentifier("settings-reduced-motion")
                }
            }
            panel {
                liveToggle(uiFormat("Play %@ sound effects", applicationName), value: runtime.document.interaction.playSoundEffects,
                           identifier: "settings-sound-effects", save: model.setPlaySoundEffects)
                rule
                liveToggle("Haptic feedback when reordering tabs", value: runtime.document.interaction.hapticFeedback,
                           identifier: "settings-reorder-haptics", save: model.setHapticFeedback)
            }
            panel {
                settingRow("Website data and permissions") {
                    Button(uiText("Manage…")) { model.settingsSection = .privacy }
                        .accessibilityIdentifier("settings-site-data")
                }
            }
            Text(model.safeBrowsingAvailable ? uiText("Warnings for dangerous sites and downloads are on.")
                 : uiText("Safe Browsing is unavailable in this build."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var profilePicker: some View {
        Group {
            if let profile = model.selectedProfileID {
                Picker(uiText("Profile"), selection: Binding(get: { profile }, set: { model.selectProfile($0) })) {
                    ForEach(model.catalog.profiles, id: \.id) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 190).accessibilityIdentifier("settings-profile")
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
        Image(nsImage: NSApp.applicationIconImage ?? NSImage()).resizable().interpolation(.high).scaledToFit().accessibilityLabel(uiText("App Icon"))
    }
    private var rule: some View { Rectangle().fill(OrbitSettingsStyle.border).frame(height: 1).padding(.horizontal, 8) }
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OrbitSettingsStyle.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OrbitSettingsStyle.border, lineWidth: 1))
    }
    private func settingRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) { Text(uiText(title)).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 8); control() }
            .padding(.horizontal, 12).padding(.vertical, 10)
    }
    private func liveToggle(_ title: String, value: Bool, identifier: String,
                            save: @escaping (Bool) async throws -> Void) -> some View {
        settingRow(title) {
            Toggle(uiText(title), isOn: Binding(get: { value }, set: { next in
                model.perform { try await save(next) }
            })).labelsHidden().toggleStyle(.switch).controlSize(.mini).accessibilityIdentifier(identifier)
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
            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            .accessibilityIdentifier("settings-automatic-updates")
    }
}
