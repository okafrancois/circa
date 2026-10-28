import AppKit
import BrowserEngine

extension BrowserQuickWindowWindowController: BrowserSiteControlsHost {
    func openExtensionStore(from surface: Surface) {
        guard acceptsCommands, isSitePermissionTarget(surface), let onNewTarget else { return }
        let url = URL(string: "https://chromewebstore.google.com/")!
        let request = BrowserNewSurfaceRequest(url: url, httpMethod: "GET", hasBody: false,
                                              isUserGesture: true, disposition: .newForegroundTab)
        var created: Surface?
        let destination = onNewTarget(surface, request) {
            if let created { return created }
            let fresh = engine.makeSurface(profileID: surface.profileID, delegate: self)
            created = fresh
            return fresh
        }
        guard let created else { return }
        guard let destination, destination === created, destination !== surface,
              destination.profileID == surface.profileID else { created.dispose(); return }
        destination.navigate(to: url)
    }
    var siteControlSurface: Surface? { surface.flatMap { container.owns($0) ? $0 : nil } }
    var siteControlSurfaces: [Surface] { container.surfaces }
    var siteControlsClosed: Bool { isClosed }
    var acceptsCommands: Bool { !isClosed && !isPreparingForTermination && !isPromotionInProgress }
    func owns(_ surface: Surface) -> Bool { container.owns(surface) }
    func isSitePermissionTarget(_ surface: Surface) -> Bool { !isClosed && !isPromotionInProgress && !surface.isDisposed && container.owns(surface) }
    func installSiteControlsButton(_ button: NSView) {
        guard button.superview == nil else { return }
        toolbar.addSubview(button)
        button.isHidden = true
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: SiteControlTokens.anchorSize),
            button.heightAnchor.constraint(equalToConstant: SiteControlTokens.anchorSize),
            button.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: OrbitTokens.Metrics.QuickWindow.addressLeadingInset)
        ])
    }
    func presentSiteControls(_ panel: BrowserSitePopover, rows: [NSView], button: NSView) {
        guard window?.isVisible == true else { return }
        panel.show(rows: rows, anchor: sourceSpaceBadge)
    }
    func surface(_ surface: Surface, requestsPermission request: BrowserPermissionRequest) async -> BrowserPermissionDecision {
        await siteControls.request(request, from: surface)
    }
}
