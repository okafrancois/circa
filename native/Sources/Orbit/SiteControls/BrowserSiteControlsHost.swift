import AppKit
import BrowserEngine

/// The same SITE coordinator serves tabs, Peek and Little Orbit. Hosts supply only ownership,
/// document selection and an anchor; permission policy and persistence remain shared.
@MainActor
protocol BrowserSiteControlsHost<Engine>: AnyObject {
    associatedtype Engine: BrowserEngine
    var engine: Engine { get }
    var window: NSWindow? { get }
    var engineEventHooks: BrowserSurfaceEventHooks<Engine.Surface> { get }
    var siteControlSurface: Engine.Surface? { get }
    var siteControlSurfaces: [Engine.Surface] { get }
    var siteControlsClosed: Bool { get }
    var allowsAutomaticPictureInPicture: Bool { get }
    var isPreparingForTermination: Bool { get }
    var acceptsCommands: Bool { get }
    func owns(_ surface: Engine.Surface) -> Bool
    func isSitePermissionTarget(_ surface: Engine.Surface) -> Bool
    func prepareForSiteControlsPresentation()
    func installSiteControlsButton(_ button: NSView)
    func presentSiteControls(_ panel: BrowserSitePopover, rows: [NSView], button: NSView)
    func openExtensionStore(from surface: Engine.Surface)
}

// Hosts without a Space sidebar (Little Orbit) have no interactive presentation to retire.
extension BrowserSiteControlsHost {
    func prepareForSiteControlsPresentation() {}
    var allowsAutomaticPictureInPicture: Bool { true }
}

extension BrowserWindowController: BrowserSiteControlsHost {
    var allowsAutomaticPictureInPicture: Bool { settingsPreferences?.runtime.document.automaticPictureInPicture ?? true }
    func openExtensionStore(from surface: Surface) {
        guard acceptsCommands, isSitePermissionTarget(surface), let context = session.paletteContext,
              context.profileID == surface.profileID else { return }
        hideLibrary()
        session.openTab(url: URL(string: "https://chromewebstore.google.com/")!, from: context)
    }
    var siteControlSurface: Surface? { session?.selectedSurface }
    var siteControlSurfaces: [Surface] { session?.ownedSurfaces ?? [] }
    var siteControlsClosed: Bool { session?.isClosed != false }
    func prepareForSiteControlsPresentation() {
        sidebar.spaceSwipe.cancel()
    }
    func installSiteControlsButton(_ button: NSView) {
        guard button.superview == nil else { return }
        button.widthAnchor.constraint(equalToConstant: SidebarExtensionStrip.hitSize).isActive = true
        sidebar.addressContainer.installAccessory(button, onHover: true, order: 100)
    }
    func presentSiteControls(_ panel: BrowserSitePopover, rows: [NSView], button: NSView) {
        // Model/permission work may have suspended since admission; retire any new gesture too.
        prepareForSiteControlsPresentation()
        panel.onVisibilityChange = { [weak self] in
            guard let self else { return }
            sidebar.addressContainer.holdsAccessoriesVisible = siteControls.isPopoverShown
        }
        if isAddressFieldOnScreen { panel.show(rows: rows, anchor: button) }
        else {
            let top = contentCard.isFlipped ? contentCard.bounds.minY : contentCard.bounds.maxY - SiteControlTokens.anchorSize
            let rect = NSRect(x: contentCard.bounds.minX + SiteControlTokens.inset, y: top,
                              width: SiteControlTokens.anchorSize, height: SiteControlTokens.anchorSize)
            panel.show(rows: rows, anchor: contentCard, relativeRect: rect, edge: .minY)
        }
    }
}
