import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import SwiftUI

/// Settings › AI: the master switch (off by default), the programs found on this Mac, the
/// default model per use, and privacy. Helper rows appear only once their feature ships.
@MainActor
struct BrowserSettingsAIPane<Engine: BrowserEngine>: View {
    @ObservedObject var model: BrowserSettingsModel<Engine>
    @ObservedObject var runtime: BrowserSettingsRuntime
    @ObservedObject var ai: OrbitAIService
    @State private var showsMissing = false
    @State private var editsSites = false

    /// Helpers whose visible flow has shipped.
    static var shippedHelpers: [KeyPath<BrowserAIHelperPreferences, Bool>] { [\.askInFind, \.writingHelp, \.tidyTitlesAndDownloads] }

    private var preferences: BrowserAIPreferences { runtime.document.ai }
    private var enabled: Bool { preferences.isEnabled }
    private var appName: String { BrowserSettingsAIText.applicationName }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            card { masterRow }
            if enabled {
                VStack(alignment: .leading, spacing: 0) {
                    header(uiText("Programs")) {
                        Button(ai.isChecking ? uiText("Checking…") : uiText("Check Again")) { check(explicit: true) }
                            .disabled(ai.isChecking).accessibilityIdentifier("settings-ai-check-again")
                    }
                    card { programs }.accessibilityIdentifier("settings-ai-programs")
                    header(uiText("Default models")) { EmptyView() }
                    card { defaultModels }
                    if !Self.shippedHelpers.isEmpty {
                        header(uiText("Helpers")) { EmptyView() }
                        card {
                            Toggle(uiText("Ask in Find"), isOn: Binding(get: { preferences.helpers.askInFind }, set: { value in
                                model.perform { try await runtime.updateAI { $0.helpers.askInFind = value } }
                            })).padding(14)
                            SettingsRule()
                            Toggle(uiText("Writing help"), isOn: Binding(get: { preferences.helpers.writingHelp }, set: { value in
                                model.perform { try await runtime.updateAI { $0.helpers.writingHelp = value } }
                            })).padding(14)
                            SettingsRule()
                            Toggle(uiText("Tidy titles and downloads"), isOn: Binding(get: { preferences.helpers.tidyTitlesAndDownloads }, set: { value in
                                model.perform { try await runtime.updateAI { $0.helpers.tidyTitlesAndDownloads = value } }
                            })).padding(14)
                        }
                    }
                    header(uiText("Privacy")) { EmptyView() }
                    card { privacy }
                }
            }
        }
        .background(BrowserSettingsAIScrollOverlay().accessibilityHidden(true))
        .onAppear { check(explicit: false) }
        .sheet(isPresented: $editsSites) {
            BrowserSettingsAISitesSheet(sites: preferences.disabledSites, save: { sites in
                model.perform { try await runtime.updateAI { $0.disabledSites = sites } }
            }, done: { editsSites = false })
        }
    }

    private func check(explicit: Bool) { ai.refresh(explicit: explicit, keepRunning: enabled) }

    // MARK: Master switch

    private var masterRow: some View {
        HStack(spacing: 12) {
            OrbitIcon.view(sfName: "sparkles", pointSize: 20).font(.system(size: 20)).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(uiFormat("Use AI in %@", appName)).fontWeight(.medium)
            }
            Spacer(minLength: 8)
            Toggle(uiFormat("Use AI in %@", appName), isOn: Binding(get: { enabled }, set: { value in
                model.perform {
                    try await runtime.updateAI { $0.isEnabled = value }
                    if value { ai.refresh(keepRunning: true) } else { ai.stopPrograms() }
                }
            })).labelsHidden().toggleStyle(BrowserSettingsAISwitchStyle()).accessibilityIdentifier("settings-ai-enabled")
        }
        .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 50)
    }

    // MARK: Programs

    private func status(_ id: BrowserAIProviderID) -> BrowserAIProviderStatus? { ai.statuses[id] }

    @ViewBuilder private var programs: some View {
        let found = OrbitAIService.order.filter { $0 == .onDevice || status($0)?.state != .notInstalled }
        let missing = OrbitAIService.order.filter { $0 != .onDevice && status($0)?.state == .notInstalled }
        ForEach(Array(found.enumerated()), id: \.element) { index, id in
            if index > 0 { SettingsRule() }
            programRow(id)
        }
        if !missing.isEmpty {
            SettingsRule()
            Button {
                if let animation = BrowserSettingsAIStyle.disclosure { withAnimation(animation) { showsMissing.toggle() } }
                else { showsMissing.toggle() }
            } label: {
                HStack(spacing: 12) {
                    OrbitIcon.view(sfName: "chevron.right", pointSize: 16).font(.system(size: 16)).frame(width: 20, height: 20)
                        .rotationEffect(.degrees(showsMissing ? 90 : 0)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(uiText("Not on this Mac")).fontWeight(.medium)
                        Text(missing.map(BrowserSettingsAIText.name).joined(separator: ", "))
                            .font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("settings-ai-not-on-this-mac")
            .accessibilityAddTraits(showsMissing ? .isSelected : [])
            if showsMissing {
                ForEach(missing, id: \.self) { id in
                    SettingsRule()
                    programRow(id)
                }
            }
        }
    }

    private func programRow(_ id: BrowserAIProviderID) -> some View {
        let state = status(id)?.state
        let centered = id == .onDevice && state?.isReady == true
        return HStack(alignment: centered ? .center : .top, spacing: 12) {
            BrowserSettingsAIProgramTile(provider: id)
            VStack(alignment: .leading, spacing: 2) {
                Text(BrowserSettingsAIText.name(id)).fontWeight(.medium)
                programDetails(id, state: state)
            }
            Spacer(minLength: 8)
            programAccessory(id, state: state).padding(.top, centered ? 0 : 3)
        }
        .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-ai-program-" + id.rawValue)
    }

    @ViewBuilder private func programDetails(_ id: BrowserAIProviderID, state: BrowserAIProviderState?) -> some View {
        let name = BrowserSettingsAIText.name(id)
        switch state {
        case nil:
            BrowserSettingsAIStateLine(tone: .neutral, text: uiText("Checking…"))
        case .ready(let account)?:
            if id == .onDevice {
                BrowserSettingsAIStateLine(tone: .ready, text: uiText("Ready"))
            } else {
                BrowserSettingsAIStateLine(tone: .ready, text: BrowserSettingsAIText.plan(id, account.plan)
                    .map { uiFormat("Signed in · %@", $0) } ?? uiText("Signed in"))
                if let usage = account.usage, !usage.windows.isEmpty { BrowserSettingsAIMeters(usage: usage) }
            }
        case .signedOut?:
            BrowserSettingsAIStateLine(tone: .warning, text: uiText("Signed out"))
            detail(uiFormat("Sign in to %@, then check again.", name))
        case .notInstalled?:
            BrowserSettingsAIStateLine(tone: .neutral, text: uiText("Not on this Mac"))
        case .unavailable(let reason)?:
            BrowserSettingsAIStateLine(tone: .neutral, text: uiText("Unavailable"))
            detail(unavailableText(reason, name: name))
        }
    }

    private func unavailableText(_ reason: BrowserAIUnavailableReason, name: String) -> String {
        switch reason {
        case .appleIntelligenceOff: uiText("Apple Intelligence is off.")
        case .deviceNotEligible: uiText("This Mac can’t run Apple Intelligence.")
        case .modelNotReady: uiText("Model not ready. Try again later.")
        case .systemTooOld: uiText("Needs macOS 26 or later.")
        case .programNotResponding: uiFormat("Open %@ in Terminal, then check again.", name)
        case .toolsNotDisabled: uiText("Unsupported configuration.")
        }
    }

    @ViewBuilder private func programAccessory(_ id: BrowserAIProviderID, state: BrowserAIProviderState?) -> some View {
        let name = BrowserSettingsAIText.name(id)
        switch state {
        case .ready?:
            if id != .onDevice, let status = status(id) {
                Menu {
                    Button(uiFormat("Open %@ Usage Page", name)) { NSWorkspace.shared.open(Self.usagePage(id)) }
                    if let program = status.programURL {
                        Button(uiText("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([program]) }
                    }
                } label: {
                    OrbitIcon.view(sfName: "ellipsis", pointSize: 14).font(.system(size: 14))
                }
                .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(uiText("More")).accessibilityIdentifier("settings-ai-more-" + id.rawValue)
            }
        case .signedOut?, .unavailable(.programNotResponding)?, .unavailable(.toolsNotDisabled)?, .unavailable(.modelNotReady)?:
            Button(uiText("Check Again")) { check(explicit: true) }.disabled(ai.isChecking)
        case .unavailable(.appleIntelligenceOff)?:
            Button(uiText("Open System Settings")) { NSWorkspace.shared.open(Self.appleIntelligenceSettings) }
        case .notInstalled?:
            if let program = Self.program(id) {
                Link(destination: program.installPage) {
                    HStack(spacing: 3) {
                        Text(uiFormat("Get %@", name))
                        OrbitIcon.view(sfName: "arrow.up.right.square", pointSize: 12).font(.system(size: 12)).frame(width: 12, height: 12)
                    }
                    .fontWeight(.medium)
                }
                .foregroundStyle(Color.accentColor).accessibilityIdentifier("settings-ai-get-" + id.rawValue)
            }
        default: EmptyView()
        }
    }

    static func program(_ id: BrowserAIProviderID) -> BrowserAIProgram? {
        switch id { case .codex: .codex; case .claudeCode: .claude; case .onDevice: nil }
    }

    static func usagePage(_ id: BrowserAIProviderID) -> URL {
        id == .codex ? URL(string: "https://chatgpt.com/codex/settings/usage")! : URL(string: "https://claude.ai/settings/usage")!
    }

    static var appleIntelligenceSettings: URL { URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")! }

    // MARK: Default models

    private var defaultModels: some View {
        VStack(spacing: 0) {
            modelRow(.quick, title: uiText("Quick tasks"))
            SettingsRule()
            modelRow(.chat, title: uiText("Chat and questions"))
            SettingsRule()
            modelRow(.errands, title: uiText("Errands"))
        }
    }

    private func modelRow(_ use: BrowserAIUse, title: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
            }
            Spacer(minLength: 8)
            BrowserSettingsAIModelPopUp(entries: entries(for: use), selected: selection(for: use), title: title) { choice in
                model.perform { try await runtime.updateAI { $0.defaultModels[use] = choice } }
            }
            .fixedSize().accessibilityIdentifier("settings-ai-model-" + use.rawValue)
        }
        .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
    }

    private func selection(for use: BrowserAIUse) -> BrowserAIModelChoice? {
        preferences.defaultModels[use] ?? BrowserAIPolicy.automaticChoice(for: use, statuses: ai.statuses)
            ?? BrowserAIPolicy.choices(for: use, statuses: ai.statuses).first
    }

    private func entries(for use: BrowserAIUse) -> [BrowserSettingsAIMenuEntry] {
        var choices = BrowserAIPolicy.choices(for: use, statuses: ai.statuses)
        if let saved = preferences.defaultModels[use], !choices.contains(saved) { choices.insert(saved, at: 0) }
        var previous: BrowserAIProviderID?
        return choices.map { choice in
            defer { previous = choice.provider }
            return BrowserSettingsAIMenuEntry(choice: choice, title: BrowserSettingsAIText.choice(choice, statuses: ai.statuses),
                reason: BrowserSettingsAIText.reason(ai.statuses[choice.provider]?.state),
                startsGroup: previous != nil && previous != choice.provider)
        }
    }

    // MARK: Privacy

    private var privacy: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                OrbitIcon.view(sfName: "doc.on.clipboard", pointSize: 20).font(.system(size: 20)).frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(uiText("Read the current tab when I ask")).fontWeight(.medium)
                }
                Spacer(minLength: 8)
                Toggle(uiText("Read the current tab when I ask"), isOn: Binding(get: { preferences.readsCurrentTabOnRequest }, set: { value in
                    model.perform { try await runtime.updateAI { $0.readsCurrentTabOnRequest = value } }
                })).labelsHidden().toggleStyle(BrowserSettingsAISwitchStyle()).accessibilityIdentifier("settings-ai-read-tab")
            }
            .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
            SettingsRule()
            HStack(spacing: 12) {
                OrbitIcon.view(sfName: "eyeglasses", pointSize: 20).font(.system(size: 20)).frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(uiText("Private windows")).fontWeight(.medium)
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    OrbitIcon.view(sfName: "lock.fill", pointSize: 14).font(.system(size: 14)).frame(width: 14, height: 14)
                    Text(uiText("Always off"))
                }
                .font(Font(BrandFonts.ui(12))).foregroundStyle(BrowserSettingsAIStyle.tertiary)
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
            SettingsRule()
            HStack(spacing: 12) {
                OrbitIcon.view(sfName: "nosign", pointSize: 20).font(.system(size: 20)).frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(uiText("Sites where AI is off")).fontWeight(.medium)
                    detail(preferences.disabledSites.isEmpty ? uiText("None") : preferences.disabledSites.joined(separator: ", "))
                }
                Spacer(minLength: 8)
                Button(uiText("Edit…")) { editsSites = true }.accessibilityIdentifier("settings-ai-sites")
            }
            .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
        }
    }

    // MARK: Layout

    private func detail(_ text: String) -> some View {
        Text(text).font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func header<Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Font(BrandFonts.ui(14, weight: .semibold)))
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.top, 20).padding(.bottom, 8).frame(minHeight: 26)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View { SettingsCard { content() } }
}

/// "Sites where AI is off": add and remove registrable hosts.
@MainActor
struct BrowserSettingsAISitesSheet: View {
    @State var sites: [String]
    let save: ([String]) -> Void
    let done: () -> Void
    @State private var entry = ""

    init(sites: [String], save: @escaping ([String]) -> Void, done: @escaping () -> Void) {
        _sites = State(initialValue: sites)
        self.save = save
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(uiText("Sites where AI is off")).font(Font(BrandTextStyle.ui.font(size: 22, weight: .semibold))).padding(.bottom, 8)
            SettingsCard {
                if sites.isEmpty {
                    Text(uiText("No sites yet.")).font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).frame(minHeight: 36)
                }
                ForEach(Array(sites.enumerated()), id: \.element) { index, site in
                    if index > 0 { SettingsRule() }
                    HStack(spacing: 12) {
                        OrbitIcon.view(sfName: "globe", pointSize: 16).font(.system(size: 16)).frame(width: 16, height: 16)
                        Text(site).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button(uiText("Remove")) {
                            sites.removeAll { $0 == site }
                            save(sites)
                        }
                        .buttonStyle(.plain).foregroundStyle(Color(nsColor: OrbitSettingsStyle.destructiveColor))
                        .accessibilityLabel(uiFormat("Remove %@", site))
                    }
                    .padding(.horizontal, 14).frame(minHeight: 36)
                }
            }
            HStack(spacing: 8) {
                TextField(uiText("example.com"), text: $entry).textFieldStyle(.roundedBorder).onSubmit(add)
                    .accessibilityIdentifier("settings-ai-site-field")
                Button(uiText("Add"), action: add).disabled(BrowserAIPolicy.site(from: entry) == nil)
            }
            .padding(.top, 10)
            HStack {
                Spacer()
                Button(uiText("Done"), action: done).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
        .frame(width: 440).font(Font(BrandFonts.ui(13))).settingsFrost()
    }

    private func add() {
        guard let next = BrowserAIPolicy.adding(entry, to: sites) else { return }
        sites = next
        entry = ""
        save(sites)
    }
}
