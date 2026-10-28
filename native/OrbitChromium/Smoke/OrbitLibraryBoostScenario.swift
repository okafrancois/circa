import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

extension OrbitSmokeDriver {
    /// Visible end-to-end qualification on a loopback document and mock storage only.
    func libraryBoostScenario(_ environment: OrbitEnvironment, _ owner: OrbitWindowController,
                              _ engine: ChromiumBrowserEngine) async {
        func check(_ name: String, _ value: Bool) { self.check("library-boost." + name, value) }
        func pause(_ seconds: Double = 0.8) async { try? await Task.sleep(for: .seconds(seconds)) }
        func capture(_ name: String) {
            guard let view = owner.window?.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?.write(to: runRoot.appendingPathComponent(name + ".png"))
        }
        func evaluate(_ script: String, on surface: ChromiumSurface) async -> String? {
            try? await engine.conformanceProbe?.evaluateScript(script, in: surface)
        }
        owner.window?.setContentSize(NSSize(width: 1506, height: 949))
        owner.window?.center()
        owner.showWindow(nil)
        owner.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let window = owner.window {
            let metadata: [String: Any] = ["number": window.windowNumber,
                "x": window.frame.minX, "y": window.frame.minY,
                "width": window.frame.width, "height": window.frame.height]
            try? JSONSerialization.data(withJSONObject: metadata).write(to: runRoot.appendingPathComponent("window.json"))
        }
        let url = fixture.appendingPathComponent("fixture")
        owner.submitAddress(url.absoluteString)
        guard let source = await committed(owner, url), let profile = owner.session.activeProfileID else {
            check("fixture", false); return
        }
        owner.createBoost()
        await owner.boostTask?.value
        guard let created = owner.boostEditor else { check("create", false); return }
        created.editor.onClose?()
        await created.session.pending?.value
        owner.showLibrary(.boosts)
        await owner.session.waitForPendingCommands()
        await owner.library.boostsTask?.value
        let selected = owner.session.snapshot?.selectedOccurrenceID
        let count = owner.session.ownedSurfaces.count
        capture("library-before")
        await pause(2)
        event("library-boost-open", [:])
        owner.library.boostsView.onOpen?(created.session.boost, profile)
        await owner.boostTask?.value
        guard let page = owner.presentedPeekSurface, let editor = owner.boostEditor else { check("open", false); return }
        _ = await until(5) { page.navigationState.committedURL?.port == fixture.port && !page.navigationState.isLoading }
        check("library-retained", owner.library.isPresented && owner.library.category == .boosts)
        check("selection-retained", owner.session.snapshot?.selectedOccurrenceID == selected && owner.session.ownedSurfaces.count == count)
        check("stored-origin", page.currentURL?.scheme == fixture.scheme && page.currentURL?.host == fixture.host && page.currentURL?.port == fixture.port)
        check("overlay-page", owner.pageCommandSurface() === page && editor.pageHost === page.hostView)
        await pause(1)
        capture("library-overlay")
        editor.session.edit { $0.fontFamily = "Courier"; $0.customCSS = "h1 { color: rgb(190, 30, 70) !important; }" }
        await editor.session.pending?.value
        check("live-css", await evaluate("String(getComputedStyle(document.querySelector('h1')).color)", on: page) == "rgb(190, 30, 70)")
        owner.beginBoostZap(editor)
        if let picker = editor.zapView {
            let picked = try? await picker.inspect?(NSPoint(x: 120, y: 160))
            check("zap-inspection", picked != nil)
            picker.onZap?("#zap")
            await editor.session.pending?.value
            check("live-zap", await evaluate("String(getComputedStyle(document.querySelector('#zap')).display)", on: page) == "none")
            picker.onDone?()
            check("zap-done", editor.zapView == nil && !editor.editor.isZapping)
        } else { check("zap-picker", false) }
        if let preferences = owner.settingsPreferences?.runtime {
            do {
                try await preferences.setEnablesBoostsOnWebsites(false)
                await pause(0.4)
                check("global-disabled", await evaluate("String(getComputedStyle(document.querySelector('#zap')).display !== 'none')", on: page) == "true")
                try await preferences.setEnablesBoostsOnWebsites(true)
                await pause(0.4)
                check("global-enabled", await evaluate("String(getComputedStyle(document.querySelector('#zap')).display)", on: page) == "none")
            } catch { check("global-preference", false) }
        } else { check("global-preference", false) }
        await pause(1)
        capture("library-edited")
        editor.editor.onClose?()
        check("editor-done-retains-page", owner.isPeekPresented && owner.library.isPresented)
        owner.peek.overlay.onClose?()
        await pause()
        check("close-retains-library", owner.library.isPresented && !owner.isPeekPresented && owner.boostEditor == nil && page.isDisposed)
        capture("library-closed")
        owner.library.boostsView.onOpen?(created.session.boost, profile)
        await owner.boostTask?.value
        guard let reopened = owner.presentedPeekSurface else { check("reopen", false); return }
        _ = await until(5) { !reopened.navigationState.isLoading }
        _ = await evaluate("window.libraryMarker = 42; 'ok'", on: reopened)
        await pause()
        owner.peek.overlay.onOpenInTab?()
        _ = await until(5) { !owner.isPeekPresented && owner.session.selectedSurface === reopened }
        await owner.session.waitForPendingCommands()
        await pause()
        let marker = await evaluate("String(window.libraryMarker)", on: reopened)
        check("expand-retains-document", owner.session.selectedSurface === reopened && !reopened.isDisposed && marker == "42")
        check("expand-dismisses-library", !owner.library.isPresented && owner.session.ownedSurfaces.count == count + 1)
        check("expand-editor", owner.boostEditor?.pageHost === reopened.hostView && source !== reopened)
        capture("library-expanded")
        await pause(2)
    }
}
