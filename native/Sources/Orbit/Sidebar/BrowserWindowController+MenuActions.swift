import AppKit
import BrowserCore
import BrowserEngine

extension BrowserWindowController {
    /// Relative archiving is confined to Today in the captured Space. Split groups remain whole.
    func sidebarRelativeTodayTabs(above: Bool) -> [TabID] {
        guard let organization = session.organization else { return [] }
        let targets = Set(sidebar.commandTargets())
        let indices = organization.today.indices.filter { targets.contains(organization.today[$0].node) }
        guard let first = indices.first, let last = indices.last else { return [] }
        let items = organization.today.enumerated().filter { above ? $0.offset < first : $0.offset > last }
        return items.flatMap { _, item -> [TabID] in
            switch item {
            case .tab(let tab): return [tab.id]
            case .split(let split): return split.group.tabIDs
            case .folder: return []
            }
        }
    }

    var sidebarMuteSurface: Surface? {
        guard engine.capabilities.contains(.audioMuting), sidebarTabTargets.count == 1,
              let id = sidebarTabTargets.first, let surface = liveSidebarSurface(of: id), !surface.isDisposed else { return nil }
        return surface
    }

    func toggleSidebarMute() {
        guard let surface = sidebarMuteSurface else { return }
        let generation = surface.documentGeneration
        Task { [weak self, weak surface] in
            guard let self, let surface else { return }
            let media = await surface.requestMediaState()
            guard self.acceptsCommands, self.owns(surface), !surface.isDisposed,
                  surface.documentGeneration == generation, let muted = media.isAudioMuted else { return }
            do { try surface.setAudioMuted(!muted) }
            catch { self.session.onError?(error) }
            self.siteControls.refreshMedia(surface)
        }
    }
}
