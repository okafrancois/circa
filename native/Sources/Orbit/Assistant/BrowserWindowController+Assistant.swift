import AppKit
import BrowserCore
import BrowserEngine
import SwiftUI

extension BrowserWindowController {
    var assistantEnabled: Bool { settingsPreferences?.runtime.document.ai.isEnabled == true && !isPrivateWindow }
    func ensureAssistant() -> BrowserAIConversation? {
        guard assistantEnabled, let aiService else { return nil }
        reconcileAssistant()
        if let aiConversation { return aiConversation }
        aiProfileID = session.activeProfileID
        let choice = settingsPreferences?.runtime.document.ai.defaultModels[.chat]
            ?? BrowserAIPolicy.automaticChoice(for: .chat, statuses: aiService.statuses)
            ?? BrowserAIModelChoice(provider: .codex)

        let conversation = BrowserAIConversation(choice: choice,
            clients: OrbitAIService.order.map { aiService.client($0) },
            preferences: { [weak self] in self?.settingsPreferences?.runtime.document.ai ?? .init() },
            isPrivate: { [weak self] in self?.isPrivateWindow ?? true },
            currentSource: { [weak self] id in self?.assistantSources.first { $0.id == id } },
            reader: { [weak self] source in
                guard let self, let tab = session.organization?.allTabs.first(where: { $0.id.rawValue == source.id }),
                      let occurrence = tab.occurrenceID, let surface = session.surface(for: occurrence),
                      surface.documentGeneration == source.revision, let reader = surface as? any BrowserAIPageReading else {
                    throw BrowserEngineError.unsupportedOperation
                }
                return try await reader.readAIPage(revision: source.revision, isCurrent: { [weak self, weak surface] in
                    guard let self, let surface else { return false }
                    return self.assistantSources.contains(source) && self.aiConversation?.selectedSources.contains(source) == true
                        && self.session.surface(for: occurrence) === surface
                })
            })
        if let selected = session.organization?.selectedTab,
           let source = assistantSources.first(where: { $0.id == selected.id.rawValue }) { conversation.select(source) }
        aiConversation = conversation
        return conversation
    }
    var assistantSources: [BrowserAIContextSource] {
        guard assistantEnabled else { return [] }
        return (session.organization?.allTabs ?? []).compactMap { tab in
            guard let occurrence = tab.occurrenceID, let surface = session.surface(for: occurrence),
                  surface.profileID == session.activeProfileID, let url = surface.navigationState.committedURL,
                  ["http", "https"].contains(url.scheme ?? ""),
                  BrowserAIPolicy.allowsPageAccess(settingsPreferences?.runtime.document.ai ?? .init(), isPrivate: isPrivateWindow, host: url.host) else { return nil }
            return .init(id: tab.id.rawValue, revision: surface.documentGeneration, url: url, title: tab.title ?? url.host ?? "")
        }
    }
    func reconcileAssistant() {
        reconcileFindAnswer()
        if aiConversation != nil, aiProfileID != session.activeProfileID {
            aiConversation?.close(); aiConversation = nil; closeAssistant()
        }
        guard let conversation = aiConversation else { return }
        if conversation.isRunning, let status = aiService?.statuses[conversation.choice.provider], !status.state.isReady { conversation.stop() }
        let allowed = assistantSources
        let stale = conversation.selectedSources.filter { !allowed.contains($0) }
        if !assistantEnabled || !stale.isEmpty { conversation.stop() }
        for source in stale { conversation.removeSource(source.id) }
        if let host = assistantHost as? NSHostingView<BrowserAssistantView> { host.rootView = assistantView(conversation) }
    }
    var assistantScopes: [String: [BrowserAIContextSource]] {
        guard let organization = session.organization else { return [:] }
        let sources = assistantSources
        var scopes: [String: [BrowserAIContextSource]] = [uiText("Whole Space"): Array(sources.prefix(8))]
        func visit(_ items: [BrowserOrganizationItem]) {
            for item in items {
                if case .folder(let folder) = item {
                    func ids(_ children: [BrowserOrganizationItem]) -> [UUID] {
                        children.flatMap { child -> [UUID] in
                            switch child {
                            case .tab(let tab): return [tab.id.rawValue]
                            case .folder(let nested): return ids(nested.children)
                            case .split(let group): return group.tabs.map { $0.id.rawValue }
                            }
                        }
                    }
                    let members = Set(ids(folder.children))
                    scopes[folder.title] = Array(sources.filter { members.contains($0.id) }.prefix(8))
                    visit(folder.children)
                }
            }
        }
        visit(organization.pinned + organization.today)
        return scopes.filter { !$0.value.isEmpty }
    }
    func toggleAssistant() {
        if assistantHost != nil { closeAssistant(); return }
        guard let conversation = ensureAssistant() else { return }
        dismissPeek()
        let view = assistantView(conversation)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        assistantHost = host
        paintAssistant(windowShell.theme)
        contentCard.onEffectiveAppearanceChange = { [weak self] in
            guard let self else { return }
            paintAssistant(windowShell.theme)
        }
        contentCard.setAssistant(host, width: 372)
    }
    /// Keeps the dock cut from the fill actually painted, including during a Space swipe. Its reading
    /// colours settle with the published theme.
    func paintAssistant(_ painted: OrbitTokens.SpaceTheme) {
        guard let host = assistantHost as? NSHostingView<BrowserAssistantView>, let window else { return }
        let palette = BrowserAssistantPalette(theme: painted, appearance: window.effectiveAppearance)
        contentCard.setAssistantSurface(theme: painted, tint: palette.tint)
        guard painted == windowShell.theme, let conversation = aiConversation else { return }
        host.appearance = palette.appearance
        host.rootView = assistantView(conversation)
    }
    private func assistantView(_ conversation: BrowserAIConversation) -> BrowserAssistantView {
        return BrowserAssistantView(conversation: conversation,
            choices: BrowserAIPolicy.choices(for: .chat, statuses: aiService?.statuses ?? [:]),
            statuses: aiService?.statuses ?? [:], sources: assistantSources, usages: aiService?.statuses.compactMapValues { $0.state.usage } ?? [:], scopes: assistantScopes, currentTabID: session.organization?.selectedTab?.id.rawValue, enabled: assistantEnabled,
            palette: BrowserAssistantPalette(theme: windowShell.theme, appearance: window?.effectiveAppearance ?? NSApp.effectiveAppearance),
            favicons: assistantFavicons, citation: { [weak self] in await self?.showAssistantCitation($0) ?? false }, close: { [weak self] in self?.closeAssistant() })
    }
    /// Icons the sidebar already shows for the offered tabs; nothing is fetched for the assistant.
    private var assistantFavicons: [UUID: NSImage] {
        let offered = Set(assistantSources.map(\.id))
        var icons: [UUID: NSImage] = [:]
        for tab in session.organization?.allTabs ?? [] where offered.contains(tab.id.rawValue) {
            if let icon = sidebar.liveActivity(tab).favicon { icons[tab.id.rawValue] = icon }
        }
        return icons
    }
    func openAssistantSource(_ source: BrowserAIContextSource) {
        guard assistantSources.contains(source), let tab = session.organization?.allTabs.first(where: { $0.id.rawValue == source.id }) else { return }
        session.selectTab(tab.id)
    }
    func showAssistantCitation(_ citation: BrowserAICitation) async -> Bool {
        guard assistantSources.contains(citation.snapshot.source),
              let tab = session.organization?.allTabs.first(where: { $0.id.rawValue == citation.snapshot.source.id }),
              let occurrence = tab.occurrenceID, let surface = session.surface(for: occurrence),
              let reader = surface as? any BrowserAIPageReading else { return false }
        session.selectTab(tab.id)
        return (try? await reader.highlightAIPassage(citation.passage, revision: citation.snapshot.source.revision,
            isCurrent: { [weak self, weak surface] in
                guard let self, let surface else { return false }
                return self.assistantSources.contains(citation.snapshot.source) && self.session.surface(for: occurrence) === surface
            })) ?? false
    }
    func closeAssistant() {
        guard assistantHost != nil else { return }
        contentCard.setAssistant(nil, width: 0)
        assistantHost = nil
        focusSelectedDocument()
    }
}
