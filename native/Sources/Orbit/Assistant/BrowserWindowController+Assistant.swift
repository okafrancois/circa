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
                return try await reader.readAIPage(revision: source.revision)
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
        if aiConversation != nil, aiProfileID != session.activeProfileID {
            aiConversation?.close(); aiConversation = nil; closeAssistant()
        }
        guard let conversation = aiConversation else { return }
        let allowed = assistantSources
        let stale = conversation.selectedSources.filter { !allowed.contains($0) }
        if !assistantEnabled || !stale.isEmpty { conversation.stop() }
        for source in stale { conversation.removeSource(source.id) }
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
                            case .split: return []
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
        let view = BrowserAssistantView(conversation: conversation,
            choices: BrowserAIPolicy.choices(for: .chat, statuses: aiService?.statuses ?? [:]),
            sources: assistantSources, scopes: assistantScopes, enabled: assistantEnabled, citation: { [weak self] in await self?.showAssistantCitation($0) ?? false }, close: { [weak self] in self?.closeAssistant() })
        let host = NSHostingView(rootView: view)
        assistantHost = host
        contentCard.setAssistant(host, width: 372)
    }
    func showAssistantCitation(_ citation: BrowserAICitation) async -> Bool {
        guard assistantSources.contains(citation.snapshot.source),
              let tab = session.organization?.allTabs.first(where: { $0.id.rawValue == citation.snapshot.source.id }),
              let occurrence = tab.occurrenceID, let surface = session.surface(for: occurrence),
              let reader = surface as? any BrowserAIPageReading else { return false }
        session.selectTab(tab.id)
        return (try? await reader.highlightAIPassage(citation.passage, revision: citation.snapshot.source.revision)) ?? false
    }
    func closeAssistant() {
        guard assistantHost != nil else { return }
        contentCard.setAssistant(nil, width: 0)
        assistantHost = nil
        focusSelectedDocument()
    }
}
