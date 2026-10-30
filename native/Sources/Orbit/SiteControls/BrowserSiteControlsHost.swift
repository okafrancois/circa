import AppKit
import BrowserCore
import BrowserEngine

enum BrowserSiteTopAction: CaseIterable {
    case newBoost, captureRegion, captureFullPage
}

/// The same SITE coordinator serves tabs, Peek and Little Circa. Hosts supply only ownership,
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
    func canPerformSiteAction(_ action: BrowserSiteTopAction, on surface: Engine.Surface) -> Bool
    func performSiteAction(_ action: BrowserSiteTopAction, on surface: Engine.Surface)
}

// Hosts without a Space sidebar (Little Circa) have no interactive presentation to retire.
extension BrowserSiteControlsHost {
    func prepareForSiteControlsPresentation() {}
    var allowsAutomaticPictureInPicture: Bool { true }
    func canPerformSiteAction(_ action: BrowserSiteTopAction, on surface: Engine.Surface) -> Bool { false }
    func performSiteAction(_ action: BrowserSiteTopAction, on surface: Engine.Surface) {}
}

extension BrowserWindowController: BrowserSiteControlsHost {
    func canPerformSiteAction(_ action: BrowserSiteTopAction, on surface: Surface) -> Bool {
        guard acceptsCommands, owns(surface), !surface.isDisposed, siteControlSurface === surface else { return false }
        switch action {
        case .newBoost:
            guard settingsPreferences?.runtime.document.enablesBoostsOnWebsites != false,
                  !isPrivateWindow, boostsRuntime != nil, let url = surface.navigationState.url,
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.user == nil, parts.password == nil, let scheme = parts.scheme,
                  ["http", "https"].contains(scheme), let host = parts.encodedHost else { return false }
            return (try? BrowserBoostHostPattern(host: host, schemes: [scheme == "https" ? .https : .http], port: parts.port)) != nil
        case .captureRegion: return engine.capabilities.contains(.snapshots)
        case .captureFullPage: return engine.capabilities.contains(.fullPageSnapshots)
        }
    }

    func performSiteAction(_ action: BrowserSiteTopAction, on surface: Surface) {
        guard canPerformSiteAction(action, on: surface) else { return }
        switch action {
        case .newBoost:
            // Establish the panel's tab as page authority before the existing editor command.
            surface.focusDocument()
            guard pageCommandSurface() === surface else { return }
            createBoost()
        case .captureRegion: capture.begin(on: surface)
        case .captureFullPage: capture.begin(fullPage: true, on: surface)
        }
    }

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
