import AppKit
import BrowserCore
import BrowserEngine

/// One batch per display cycle. A run-loop fallback also flushes occluded windows, whose
/// display links may stop; ownership and document identity are rechecked by the consumer.
@MainActor
final class SidebarMetadataCoalescer: NSObject {
    var flush: (() -> Void)?
    private var link: CADisplayLink?
    private var fallback: DispatchWorkItem?

    func schedule(in view: NSView?) {
        guard fallback == nil else { return }
        if let view, view.window?.isVisible == true {
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            self.link = link
            link.add(to: .main, forMode: .common)
        }
        let work = DispatchWorkItem { [weak self] in self?.fire() }
        fallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: work)
    }

    @objc private func tick(_ link: CADisplayLink) { fire() }

    private func fire() {
        link?.invalidate()
        link = nil
        fallback?.cancel()
        fallback = nil
        flush?()
    }
}

struct SidebarEngineMetadata: Equatable {
    let generation: UInt64
    let url: URL?
    let title: String?
}

extension BrowserWindowController {
    func queueSidebarMetadata(for surface: Surface, persist: Bool = false) {
        guard owns(surface), let occurrence = session.occurrenceID(for: surface),
              let id = session.tabID(for: occurrence) else { return }
        sidebarMetadataIDs.insert(id)
        if persist { sidebarMetadataSurfaces[ObjectIdentifier(surface)] = (surface, surface.documentGeneration) }
        scheduleSidebarMetadata()
    }

    func scheduleSidebarMetadata() {
        sidebarMetadataCoalescer.flush = { [weak self] in self?.flushSidebarMetadata() }
        sidebarMetadataCoalescer.schedule(in: sidebar)
    }

    func flushSidebarMetadata() {
        let surfaces = sidebarMetadataSurfaces
        let ids = sidebarMetadataIDs
        sidebarMetadataSurfaces.removeAll(keepingCapacity: true)
        sidebarMetadataIDs.removeAll(keepingCapacity: true)
        guard !isPreparingForTermination, !session.isClosed else { return }
        for (surface, generation) in surfaces.values where owns(surface) && surface.documentGeneration == generation {
            guard let occurrence = session.occurrenceID(for: surface) else { continue }
            let value = SidebarEngineMetadata(generation: generation, url: surface.currentURL,
                                              title: surface.navigationState.title)
            let old = sidebarMetadataValues[occurrence]
            sidebarMetadataValues[occurrence] = value
            if old?.title != value.title || old?.generation != generation {
                session.updatePageTitle(for: surface, to: value.title, isCurrent: { [weak surface] in
                    surface?.documentGeneration == generation
                })
            }
        }
        sidebar.applyMetadata(ids, organization: session.organization)
    }
}
