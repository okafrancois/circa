import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import SwiftUI

private struct TodayTidyMetadata: Encodable { let id: UUID; let title: String; let host: String }

@MainActor
final class BrowserTodayTidy<Engine: BrowserEngine>: ObservableObject {
    weak var owner: BrowserWindowController<Engine>?
    @Published private(set) var suggestions: [BrowserAITodaySuggestion] = []
    @Published private(set) var running = false
    @Published private(set) var applying = false
    @Published private(set) var message = ""
    private let request = BrowserAIHelperRequest()
    private var task: Task<Void, Never>?
    private var epoch = UUID()
    private var snapshot: BrowserOrganizationSnapshot?
    private var preferences: BrowserAIPreferences?
    private var model: BrowserAIModelChoice?

    init(owner: BrowserWindowController<Engine>) { self.owner = owner }

    private var candidates: (BrowserOrganizationSnapshot, [BrowserOrganizationTabItem], BrowserAIPreferences, BrowserAIModelChoice)? {
        guard let owner, !owner.isPrivateWindow, let current = owner.session.organization,
              let preferences = owner.settingsPreferences?.runtime.document.ai,
              preferences.isEnabled, preferences.helpers.tidyToday, preferences.readsCurrentTabOnRequest,
              let service = owner.aiService,
              let model = preferences.defaultModels[.quick] ?? BrowserAIPolicy.automaticChoice(for: .quick, statuses: service.statuses),
              BrowserAIPolicy.choices(for: .quick, statuses: service.statuses).contains(model),
              let status = service.statuses[model.provider], status.state.isReady,
              status.state.usage?.limitReached != true else { return nil }
        let ordinary = Set(current.today.compactMap { item -> TabID? in
            guard case .tab(let tab) = item else { return nil }
            return tab.id
        })
        let tabs = current.allTabs.filter { tab in
            guard case .today = tab.section, ordinary.contains(tab.id), !tab.isOpenInAnotherWindow,
                  ["http", "https"].contains(tab.url.scheme ?? "") else { return false }
            if let occurrence = tab.occurrenceID, let surface = owner.session.surface(for: occurrence),
               surface.navigationState.committedURL != tab.url || surface.profileID != current.profileID { return false }
            return BrowserAIPolicy.allowsPageAccess(preferences, isPrivate: false, host: tab.url.host)
        }
        return (current, Array(tabs.prefix(40)), preferences, model)
    }

    func reconcile() {
        guard let owner else { return }
        guard let candidate = candidates else { close(); owner.sidebar.setTodayTidyAvailable(false); return }
        owner.sidebar.setTodayTidyAvailable(candidate.1.count >= 2)
        if let snapshot {
            if snapshot.profileID != candidate.0.profileID || snapshot.spaceID != candidate.0.spaceID
                || preferences != candidate.2 || model != candidate.3
                || (!applying && snapshot.organizationRevision != candidate.0.organizationRevision) { close() }
        }
    }

    func start() {
        close()
        guard let owner, let (current, tabs, preferences, model) = candidates, tabs.count >= 2,
              let service = owner.aiService else { return }
        snapshot = current; self.preferences = preferences; self.model = model
        let token = epoch
        let valid: @MainActor () -> Bool = { [weak self, weak owner] in
            guard let self, let owner, epoch == token, let candidate = candidates else { return false }
            return candidate.0.organizationRevision == current.organizationRevision
                && candidate.0.profileID == current.profileID && candidate.0.spaceID == current.spaceID
                && candidate.1 == tabs && candidate.2 == preferences && candidate.3 == model && !owner.session.isClosed
        }
        let items = tabs.map { TodayTidyMetadata(id: $0.id.rawValue, title: String(($0.title ?? $0.url.host ?? "").prefix(120)), host: $0.url.host ?? "") }
        guard let data = try? JSONEncoder().encode(items) else { return }
        running = true
        show()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await request.run(client: service.client(model.provider), choice: model,
                    instructions: """
                    Suggest helpful groups for the supplied Today tabs. Use only their supplied IDs.
                    Return only JSON: {"suggestions":[{"action":"folder","title":"Group name","tabs":["UUID","UUID"]}]}.
                    A folder needs at least two related tabs. Use action "archive" only for clearly redundant or finished items.
                    These are suggestions for the user, never instructions to execute. Do not infer private activity.
                    Every tab may appear at most once. Return at most 8 suggestions, or an empty suggestions array.
                    """, preferences: { valid() ? preferences : .init() }, isCurrent: valid,
                    extract: { String(decoding: data, as: UTF8.self) }, outputLimit: 4096)
                guard valid() else { return }
                suggestions = try BrowserAITodaySuggestion.parse(text, allowed: Set(tabs.map(\.id)))
                running = false
                if suggestions.isEmpty { message = uiText("No suggestions") }
                show()
            } catch {
                guard epoch == token else { return }
                running = false
                if error is CancellationError { close(); return }
                message = browserAssistantErrorText(error as? BrowserAIError ?? .failed)
                show()
            }
        }
    }

    func apply(_ suggestion: BrowserAITodaySuggestion) {
        guard !running, !applying, suggestions.contains(suggestion), let owner, let snapshot,
              let candidate = candidates, candidate.0.organizationRevision == snapshot.organizationRevision,
              candidate.2 == preferences, candidate.3 == model,
              Set(suggestion.tabs).isSubset(of: Set(candidate.1.map(\.id))) else { close(); return }
        let token = epoch
        let valid: @MainActor () -> Bool = { [weak self] in
            guard let self, epoch == token, let candidate = candidates else { return false }
            return candidate.0.organizationRevision == snapshot.organizationRevision
                && candidate.0.spaceID == snapshot.spaceID && candidate.0.profileID == snapshot.profileID
                && candidate.2 == preferences && candidate.3 == model
                && Set(suggestion.tabs).isSubset(of: Set(candidate.1.map(\.id)))
        }
        owner.sidebar.page.list.todayGroupingTabs = suggestion.action == .folder ? suggestion.tabs : []
        owner.sidebar.page.list.todayArchivingTabs = suggestion.action == .archive ? Set(suggestion.tabs) : []
        applying = true
        Task { [weak self] in
            defer {
                owner.sidebar.page.list.todayGroupingTabs = []
                owner.sidebar.page.list.todayArchivingTabs = []
            }
            let success = await owner.session.applyTodaySuggestion(suggestion, revision: snapshot.organizationRevision, isCurrent: valid).value
            guard let self, epoch == token else { return }
            applying = false
            guard success == true, let current = candidates, current.0.spaceID == snapshot.spaceID,
                  current.0.profileID == snapshot.profileID, current.2 == preferences, current.3 == model else { close(); return }
            self.snapshot = current.0
            let remaining = Set(current.1.map(\.id))
            suggestions.removeAll { $0.id == suggestion.id || !Set($0.tabs).isSubset(of: remaining) }
            if suggestions.isEmpty { close() } else { show() }
        }
    }

    private func show() {
        guard let owner else { return }
        let palette = BrowserAssistantPalette(theme: owner.windowShell.theme ?? .default,
                                               appearance: owner.window?.effectiveAppearance ?? NSAppearance(named: .aqua)!)
        owner.sidebar.showTodayTidy(AnyView(BrowserTodayTidyView(model: self, palette: palette)),
                                   height: CGFloat(suggestions.count * 30 + 56))
    }

    func close() {
        epoch = UUID(); task?.cancel(); task = nil; request.cancel()
        running = false; applying = false; suggestions = []; message = ""
        snapshot = nil; preferences = nil; model = nil
        owner?.sidebar.showTodayTidy(nil, height: 0)
    }
}

private struct BrowserTodayTidyView<Engine: BrowserEngine>: View {
    @ObservedObject var model: BrowserTodayTidy<Engine>
    let palette: BrowserAssistantPalette
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                OrbitIcon.view(sfName: "sparkles", pointSize: 11)
                Text(uiText("Suggestions"))
                Spacer()
                Button { model.close() } label: { OrbitIcon.view(sfName: "xmark", pointSize: 10) }
                    .buttonStyle(.plain).accessibilityLabel(uiText("Close"))
            }.font(Font(BrandTextStyle.ui.font(size: 11))).foregroundStyle(palette.secondary.swiftUI)
            if model.suggestions.contains(where: { $0.action == .folder }) {
                Text(uiText("Folders are pinned.")).font(Font(BrandTextStyle.ui.font(size: 11))).foregroundStyle(palette.secondary.swiftUI)
            }
            if model.running { BrowserAssistantThinkingView().frame(height: 20) }
            if !model.message.isEmpty { Text(model.message).font(Font(BrandTextStyle.ui.font(size: 12))) }
            ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                HStack(spacing: 5) {
                    Text(suggestion.title).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button(suggestion.action == .folder ? uiText("Make Folder") : uiText("Archive")) { model.apply(suggestion) }
                        .font(Font(BrandTextStyle.ui.font(size: 11.5, weight: .medium)))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(palette.hover.swiftUI, in: RoundedRectangle(cornerRadius: 6))
                        .disabled(model.applying).buttonStyle(.plain)
                        .accessibilityIdentifier("today-suggestion-\(index)")
                }.font(Font(BrandTextStyle.ui.font(size: 12.5))).frame(height: 30)
                    .modifier(TodaySuggestionEntrance(index: index))
            }
        }.padding(6).foregroundStyle(palette.ink.swiftUI)
            .background(palette.hover.swiftUI, in: RoundedRectangle(cornerRadius: 10))
            .environment(\.assistantPalette, palette)
    }
}

private struct TodaySuggestionEntrance: ViewModifier {
    let index: Int
    @State private var visible = false
    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0)
            .offset(y: visible || OrbitMotionPreferences.prefersReducedMotion ? 0 : -4)
            .animation(OrbitMotionPreferences.prefersReducedMotion ? nil : .timingCurve(1.0 / 3, 2.0 / 3, 2.0 / 3, 1, duration: 0.24).delay(0.08 + Double(index) * 0.04), value: visible)
            .onAppear { visible = true }
    }
}
