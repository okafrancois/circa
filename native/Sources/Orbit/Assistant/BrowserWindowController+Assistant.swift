import AppKit
import BrowserCore
import BrowserEngine
import SwiftUI

extension BrowserWindowController {
    func refreshAssistantErrandPresentation() {
        if let host = assistantHost as? NSHostingView<BrowserAssistantView>, let conversation = aiConversation {
            host.rootView = assistantView(conversation)
        }
    }
    var assistantEnabled: Bool { settingsPreferences?.runtime.document.ai.isEnabled == true && !isPrivateWindow }
    func ensureAssistant() -> BrowserAIConversation? {
        guard assistantEnabled, let aiService else { return nil }
        reconcileAssistant()
        if let aiConversation { return aiConversation }
        aiProfileID = session.activeProfileID
        Task { [weak self] in guard let self, let profile = session.activeProfileID else { return }; await skillsRuntime?.refresh(profile) }
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
                if let selection = self.skillSelection, selection.source == source { return selection.text }
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
        reconcileErrand()
        if skillDraft.reconcilePermissions(settingsPreferences?.runtime.document.ai ?? .init()) {
            aiConversation?.stop()
            if let selection = skillSelection { aiConversation?.removeSource(selection.source.id) }
            skillSelection = nil; skillDraft.selectionID = nil; skillDraft.text = ""
        }
        palette.reconcileSkills()
        linkPreviewHelp?.reconcile()
        todayTidy.reconcile()
        tidyHelpers.revokeStaleRequests()
        writingHelp?.reconcile()
        reconcileFindAnswer()
        if aiConversation != nil, aiProfileID != session.activeProfileID {
            skillSelection = nil; skillDraft.selectionID = nil; skillDraft.text = ""; skillDraft.revokeRevision += 1
            aiConversation?.close(); aiConversation = nil; closeAssistant()
        }
        guard let conversation = aiConversation else { return }
        if conversation.isRunning, let status = aiService?.statuses[conversation.choice.provider], !status.state.isReady { conversation.stop() }
        let allowed = assistantSources
        let stale = conversation.selectedSources.filter { !allowed.contains($0) }
        if !assistantEnabled || skillSelection.map({ !allowed.contains($0.source) }) == true {
            skillSelection = nil; skillDraft.selectionID = nil; skillDraft.text = ""; skillDraft.revision += 1
        }
        if !assistantEnabled || !stale.isEmpty {
            conversation.stop(); skillDraft.cancelInvocation(); skillSelection = nil; skillDraft.selectionID = nil; skillDraft.text = ""; skillDraft.revokeRevision += 1
        }
        for source in stale { conversation.removeSource(source.id) }
        if let host = assistantHost as? NSHostingView<BrowserAssistantView> { host.rootView = assistantView(conversation) }
    }
    var assistantScopes: [BrowserAssistantMentionOption] {
        guard let organization = session.organization else { return [] }
        let sources = assistantSources
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        func ids(_ children: [BrowserOrganizationItem]) -> [UUID] {
            children.flatMap { child -> [UUID] in
                switch child {
                case .tab(let tab): return [tab.id.rawValue]
                case .folder(let nested): return ids(nested.children)
                case .split(let group): return group.tabs.map { $0.id.rawValue }
                }
            }
        }
        var result: [BrowserAssistantMentionOption] = []
        func visit(_ items: [BrowserOrganizationItem], path: [String]) {
            for item in items {
                switch item {
                case .tab(let tab):
                    guard let source = byID[tab.id.rawValue] else { continue }
                    result.append(.init(id: .tab(source.id), kind: .tab, title: source.title,
                        path: path.isEmpty ? uiText("Tabs") : path.joined(separator: " / "),
                        detail: mentionOrigin(source.url), members: [source]))
                case .split(let split):
                    for tab in split.tabs {
                        guard let source = byID[tab.id.rawValue] else { continue }
                        result.append(.init(id: .tab(source.id), kind: .tab, title: source.title,
                            path: path.isEmpty ? uiText("Tabs") : path.joined(separator: " / "),
                            detail: mentionOrigin(source.url), members: [source]))
                    }
                case .folder(let folder):
                    let folderPath = path + [folder.title]
                    let members = ids(folder.children).compactMap { byID[$0] }
                    if !members.isEmpty {
                        result.append(.init(id: .folder(folder.id.rawValue), kind: .folder,
                            title: folder.title, path: folderPath.joined(separator: " / "),
                            detail: uiText("Folder"), members: members))
                    }
                    visit(folder.children, path: folderPath)
                }
            }
        }
        result.append(.init(id: .space(organization.spaceID.rawValue), kind: .space,
            title: uiText("Whole Space"), path: uiText("Space"), detail: uiText("Current window"), members: sources))
        visit(organization.pinned + organization.today, path: [])
        // Keep flat live tabs unique while preserving their first organization position.
        var emitted = Set<UUID>()
        let liveTabs = result.filter { $0.kind == .tab && emitted.insert($0.members[0].id).inserted }
        return liveTabs + result.filter { $0.kind != .tab }
    }
    private func mentionOrigin(_ url: URL) -> String {
        let host = url.host ?? ""
        let path = url.path == "/" ? "" : url.path
        return host + path
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
        let profile = session.activeProfileID
        let sources = assistantSources
        let invocation = skillInvocation
        return BrowserAssistantView(conversation: conversation,
            choices: BrowserAIPolicy.choices(for: errandDraft ? .errands : .chat, statuses: aiService?.statuses ?? [:]),
            statuses: aiService?.statuses ?? [:], sources: sources, usages: aiService?.statuses.compactMapValues { $0.state.usage } ?? [:], scopes: assistantScopes, currentTabID: session.organization?.selectedTab?.id.rawValue, enabled: assistantEnabled,
            skillSync: skillsSyncRuntime, skillRuntime: skillsRuntime, skillProfile: profile, skillDraft: skillDraft,
            skillsOwnerValid: { [weak self] in
                guard let self else { return false }
                return window?.isVisible == true && assistantEnabled && skillInvocation == invocation && aiConversation === conversation
            },
            removeSkillContext: { [weak self] id in
                guard let self, skillSelection?.source.id == id else { return }
                skillSelection = nil; skillDraft.selectionID = nil
            },
            useSkill: { [weak self] option, intent in await self?.prefillSkill(option, invocation: invocation, intent: intent) },
            palette: BrowserAssistantPalette(theme: windowShell.theme, appearance: window?.effectiveAppearance ?? NSApp.effectiveAppearance),
            favicons: assistantFavicons, citation: { [weak self] in await self?.showAssistantCitation($0) ?? false }, errandSubmit: errandDraft ? { [weak self] in self?.submitErrand($0) ?? false } : nil,
            errand: errandOwner?.profileID == session.activeProfileID && errandOwner?.spaceID == session.organization?.spaceID && assistantEnabled ? errand : nil,
            close: { [weak self] in self?.closeAssistant() })
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
        errandDraft = false
        skillDraft.cancelInvocation(); skillDraft.text = ""
        guard assistantHost != nil else { return }
        contentCard.setAssistant(nil, width: 0)
        assistantHost = nil
        focusSelectedDocument()
    }
}
