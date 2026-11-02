import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

extension BrowserWindowController {
    private var linkPreviewChoice: BrowserAIModelChoice? {
        guard let preferences = settingsPreferences?.runtime.document.ai,
              preferences.helpers.linkPreviewSummaries, !isPrivateWindow,
              let owner = pageCommandSurface(), owner.profileID == session.activeProfileID,
              let url = owner.navigationState.committedURL, BrowserLinkPreviewLoader.validURL(url),
              BrowserAIPolicy.allowsPageAccess(preferences, isPrivate: false, host: url.host), let service = aiService,
              let choice = preferences.defaultModels[.quick] ?? BrowserAIPolicy.automaticChoice(for: .quick, statuses: service.statuses),
              BrowserAIPolicy.choices(for: .quick, statuses: service.statuses).contains(choice),
              let status = service.statuses[choice.provider], status.state.isReady,
              status.state.usage?.limitReached != true else { return nil }
        return choice
    }

    func installLinkPreviewHelp() {
        guard linkPreviewHelp == nil, let window else { return }
        let help = BrowserLinkPreviewHelp()
        help.capture = { [weak self] point in await self?.captureLinkPreview(at: point) }
        linkPreviewHelp = help
        help.install(in: window)
    }

    private func captureLinkPreview(at point: NSPoint) async -> BrowserLinkPreviewHelp.Context? {
        guard let choice = linkPreviewChoice, let service = aiService,
              let source = pageCommandSurface(), let reader = source as? any BrowserLinkPreviewSource,
              let url = source.navigationState.committedURL, let window, window.isKeyWindow,
              source.hostView.window === window, let profile = session.activeProfileID,
              let preferences = settingsPreferences?.runtime.document.ai else { return nil }
        let space = session.organization?.spaceID
        let revision = source.documentGeneration
        let zoom = source.pageZoom
        let local = source.hostView.convert(point, from: nil)
        guard source.hostView.bounds.contains(local) else { return nil }
        let flipped = CGPoint(x: local.x, y: source.hostView.isFlipped ? local.y : source.hostView.bounds.height - local.y)
        let valid: @MainActor () -> Bool = { [weak self, weak source] in
            guard let self, let source else { return false }
            return source.documentGeneration == revision && source.pageZoom == zoom && source.navigationState.committedURL == url
                && pageCommandSurface() === source && session.activeProfileID == profile
                && session.organization?.spaceID == space && linkPreviewChoice == choice
                && settingsPreferences?.runtime.document.ai == preferences && self.window?.isVisible == true && self.window?.isKeyWindow == true
        }
        guard let target = try? await reader.previewLink(at: flipped, revision: revision, isCurrent: valid), valid(),
              BrowserLinkPreviewLoader.validURL(target.url),
              BrowserAIPolicy.allowsPageAccess(preferences, isPrivate: false, host: target.url.host) else { return nil }
        let box = target.bounds
        let anchor = NSRect(x: box.minX, y: source.hostView.isFlipped ? box.minY : source.hostView.bounds.height - box.maxY,
                            width: box.width, height: box.height)
        let normalized = BrowserLinkPreviewTarget(id: target.id, url: target.url,
            title: target.title.isEmpty ? target.url.host ?? "" : target.title,
            description: target.description, bounds: target.bounds)
        return .init(target: normalized, profile: profile,
            anchor: window.convertToScreen(source.hostView.convert(anchor, to: nil)), preferences: preferences,
            choice: choice, client: service.client(choice.provider),
            palette: BrowserAssistantPalette(theme: windowShell.theme ?? .default, appearance: window.effectiveAppearance),
            icon: sidebarIcons.memoryCache.image(profile: profile, home: target.url), isCurrent: valid,
            allowed: { candidate in valid() && BrowserLinkPreviewLoader.validURL(candidate)
                && BrowserAIPolicy.allowsPageAccess(preferences, isPrivate: false, host: candidate.host) },
            matches: {
                guard valid(), let current = try? await reader.previewLink(at: flipped, revision: revision, isCurrent: valid), valid() else { return false }
                return current.id == target.id && current.url == target.url && current.bounds == target.bounds
            })
    }
}
