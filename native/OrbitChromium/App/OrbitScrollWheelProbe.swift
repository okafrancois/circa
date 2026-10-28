import AppKit
import BrowserCore
import ChromiumEngine

/// Real-event scroll diagnostics, available only through the confined synthetic probe.
@MainActor
enum OrbitScrollWheelProbe {
    private static var monitor: Any?
    private static var received: [[String: Any]] = []
    private static weak var switchSource: ChromiumSurface?
    static func run(_ owner: OrbitWindowController, command: [String: String]) async -> [String: Any] {
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                MainActor.assumeIsolated {
                    if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == 16962 {
                        received.append(["phase": event.phase.rawValue, "momentum": event.momentumPhase.rawValue,
                            "dx": event.scrollingDeltaX, "dy": event.scrollingDeltaY,
                            "precise": event.hasPreciseScrollingDeltas])
                        received = Array(received.suffix(200))
                    }
                }
                return event
            }
        }
        let step = command["step"] ?? "status"
        if step == "reset-events" { received.removeAll() }
        if step == "setup", let url = command["url"].flatMap(URL.init(string:)),
           let profile = owner.session.activeProfileID {
            owner.session.openTab(url: url)
            await owner.session.waitForQueuedCommands()
            owner.session.createSpace(name: "Wheel fixture", profileID: profile)
            await owner.session.waitForQueuedCommands()
            for _ in 0..<30 { owner.session.openTab(url: url, activate: false) }
            owner.session.openTab(url: url)
            await owner.session.waitForQueuedCommands()
        } else if step == "switch", let catalog = owner.session.catalog,
                  let active = owner.session.snapshot?.activeSpaceID,
                  let target = catalog.spaces.first(where: { $0.id != active })?.id {
            switchSource = owner.session.selectedSurface
            owner.sidebar.onSelectSpace?(target)
        } else if step == "creation" {
            owner.sidebar.spaceSwipe.presentCreationPage()
        } else if step == "dismiss-creation" {
            owner.sidebar.spaceSwipe.dismissCreationPage()
        } else if step == "library" {
            owner.showLibrary()
        } else if step == "dismiss-library" {
            owner.hideLibrary()
        } else if step == "peek", let url = command["url"].flatMap(URL.init(string:)) {
            _ = owner.openPeek(url)
        } else if step == "dismiss-peek" {
            owner.dismissPeek(animated: false)
        } else if step == "pill" {
            owner.sidebar.addressContainer.holdsAccessoriesVisible = true
        } else if step == "focus" {
            owner.window?.makeFirstResponder(owner.addressField)
        }
        var result: [String: Any] = ["received": received]
        if let surface = owner.session.selectedSurface,
           let expression = command["expression"] {
            result["evaluation"] = await OrbitPerformanceProbe.evaluate(surface, expression) ?? [:]
        }
        if let switchSource, let expression = command["expression"] {
            result["switchSourceEvaluation"] = await OrbitPerformanceProbe.evaluate(switchSource, expression) ?? [:]
        }
        let clip = owner.sidebar.page.pageScrollView.contentView
        if step == "reset-sidebar" {
            clip.scroll(to: .zero)
            owner.sidebar.page.pageScrollView.reflectScrolledClipView(clip)
        }
        result["sidebarY"] = clip.bounds.origin.y
        result["sidebarMaximumY"] = max(0, (clip.documentView?.bounds.height ?? 0) - clip.bounds.height)
        result["activeSpace"] = owner.session.snapshot?.activeSpaceID.rawValue.uuidString ?? ""
        result["swipeActive"] = owner.sidebar.spaceSwipe.isActive
        result["swipeOffset"] = owner.sidebar.spaceSwipe.offset
        result["creationVisible"] = owner.sidebar.spaceSwipe.isCreationPageVisible
        result["peekHidden"] = owner.peekOverlay.isHidden
        result["libraryHidden"] = owner.library.view.isHidden
        result["keyWindow"] = owner.window?.isKeyWindow == true
        if let window = owner.window {
            result["windowType"] = String(describing: type(of: window))
            func rect(_ view: NSView) -> [String: Double] {
                let screen = window.convertToScreen(view.convert(view.bounds, to: nil))
                let height = NSScreen.screens.first?.frame.height ?? 0
                return ["x": screen.minX, "y": height - screen.maxY, "width": screen.width, "height": screen.height]
            }
            result["sidebar"] = rect(owner.sidebar.page.pageScrollView)
            if let surface = owner.session.selectedSurface { result["page"] = rect(surface.hostView) }
        }
        return result
    }
}
