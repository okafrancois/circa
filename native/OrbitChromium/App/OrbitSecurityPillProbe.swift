import AppKit
import BrowserEngine
import ChromiumEngine

/// Opt-in qualification of the actual address and connection controls on loopback pages.
@MainActor
enum OrbitSecurityPillProbe {
    static func run(_ owner: OrbitWindowController, command: [String: String], root: URL) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.sec-pill",
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              let confinement = activeSyntheticDataGuard(), (try? confinement.checkInside(root)) != nil,
              let text = command["url"], let base = URL(string: text), base.host == "127.0.0.1",
              let tlsText = command["tls"], let tls = URL(string: tlsText), tls.host == "127.0.0.1",
              let trustedText = command["trusted"], let trusted = URL(string: trustedText), trusted.host == "127.0.0.1",
              let window = owner.window else { return ["refused": true] }
        func owns() -> Bool {
            let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
            return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
        }
        guard owns() else { return ["ownershipRefused": true] }
        owner.session.openTab(url: base)
        await owner.session.waitForQueuedCommands()
        guard let tab = owner.session.selectedSurface, let api = tab.nativePageServices else { return ["missingSurface": true] }
        guard owns() else { return ["ownershipRefused": true] }
        owner.focusSelectedDocument()
        func settled() async {
            for _ in 0..<200 {
                if tab.isReady && !tab.navigationState.isLoading { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        func evaluate(_ expression: String) async -> [String: Any]? {
            guard owns() else { return nil }
            return await OrbitPerformanceProbe.evaluate(tab, expression)
        }
        func snapshot() -> [String: Any] {
            let state = api.securityState()
            return ["value": owner.addressField.stringValue, "label": owner.addressField.displayLabel.stringValue,
                "glyph": owner.addressField.securitySymbol ?? "none", "committed": api.committedURL()?.absoluteString ?? "",
                "level": state?.level ?? -1, "certificateError": state?.certificateError ?? false,
                "interstitial": state?.interstitial ?? false, "displayed": state?.displayedMixedContent ?? false,
                "ran": state?.ranMixedContent ?? false]
        }
        let directory = root.appendingPathComponent("captures")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func capture(_ view: NSView, name: String) {
            guard owns() else { return }
            guard let host = view.window?.contentView else { return }
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let rect = view.convert(view.bounds, to: host).insetBy(dx: -4, dy: -4).intersection(host.bounds)
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) else { return }
            host.effectiveAppearance.performAsCurrentDrawingAppearance {
                host.display()
                host.cacheDisplay(in: rect, to: bitmap)
            }
            // Native blur is transparent in an offscreen cache. Export over the existing
            // material's conservative backdrop so alpha-only controls remain reviewable.
            guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide,
                pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: output) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let bounds = NSRect(x: 0, y: 0, width: output.pixelsWide, height: output.pixelsHigh)
            let appearance = host.effectiveAppearance
            let style = OrbitFloatingMaterial.style(for: appearance)
            style.background(over: style.variant == .dark ? .black : .white).setFill()
            bounds.fill()
            let nativeImage = NSImage(size: bounds.size)
            nativeImage.addRepresentation(bitmap)
            nativeImage.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            try? output.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
        func connection(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == "site-connection" { return view }
            for child in view.subviews { if let found = connection(child) { return found } }
            return nil
        }
        var rows: [String: Any] = [:]
        func record(_ name: String) async {
            // The stream must have updated the actual field before this capture; do not force a repaint from a model.
            try? await Task.sleep(for: .milliseconds(80))
            var row = snapshot()
            owner.sidebar.addressContainer.holdsAccessoriesVisible = true
            for appearance in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                var theme = owner.resolvedSpaceTheme(for: owner.session.snapshot?.activeSpaceID)
                theme.mode = appearance == "dark" ? .dark : .light
                owner.windowShell.apply(theme: theme, animated: false)
                window.appearance = NSApp.appearance
                try? await Task.sleep(for: .milliseconds(60))
                capture(owner.sidebar.addressContainer, name: name + "-pill-" + appearance)
                guard owns() else { return }
                owner.siteControls.show()
                try? await Task.sleep(for: .milliseconds(200))
                if let button = NSApp.windows.compactMap({ $0.contentView }).compactMap({ connection($0) }).first {
                    row["connectionLabel"] = button.toolTip ?? ""
                    button.window?.setFrameOrigin(NSPoint(x: -5000, y: -5000))
                    button.window?.appearance = NSApp.appearance
                    try? await Task.sleep(for: .milliseconds(60))
                    if let parent = button.superview { capture(parent, name: name + "-site-info-" + appearance) }
                }
                if owns(), owner.siteControls.isPopoverShown { owner.siteControls.toggle() }
            }
            rows[name] = row
        }
        await settled(); await record("neutral")
        let original = owner.addressField.stringValue
        _ = await evaluate("(()=>{try{history.pushState({},'', 'https://spoof.example.invalid/')}catch(e){};return {url:location.href}})()")
        rows["pushState"] = ["unchanged": owner.addressField.stringValue == original]
        tab.navigate(to: base.appendingPathComponent("slow"))
        try? await Task.sleep(for: .milliseconds(200))
        rows["slowPending"] = ["unchanged": owner.addressField.stringValue == original, "loading": tab.navigationState.isLoading]
        await settled()
        rows["slowCommitted"] = snapshot()
        tab.navigate(to: URL(string: "data:text/html,<title>Opaque</title>synthetic-secret")!)
        await settled(); await record("data")
        tab.navigate(to: base)
        await settled()
        _ = await evaluate("(()=>{location.href=URL.createObjectURL(new Blob(['<title>Blob</title>synthetic-secret'],{type:'text/html'}));return {requested:true}})()")
        try? await Task.sleep(for: .milliseconds(250))
        await settled(); await record("blob")
        tab.navigate(to: tls)
        await settled(); await record("certificate-error")
        tab.navigate(to: trusted.appendingPathComponent("secure"))
        await settled(); await record("secure")
        tab.navigate(to: trusted.appendingPathComponent("mixed-displayed"))
        await settled(); await record("mixed-displayed")
        tab.navigate(to: trusted.appendingPathComponent("mixed"))
        await settled(); await record("mixed-ran")
        rows["mixedExecuted"] = await evaluate("({ran:globalThis.mixedExecuted===true})")
        var idn = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        idn.host = "xn--pple-43d.com"
        tab.navigate(to: idn.url!)
        await settled(); await record("homograph")
        return rows
    }
}
