import AppKit
import Foundation
import BrowserShell
import BrowserEngine
import OrbitChromiumBridge

private func uiText(_ english: String) -> String { BrowserText.string(english) }

extension ChromiumSurface {
    public func showDeveloperPanel(_ panel: BrowserDeveloperPanel) throws {
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        if panel == .elements { try perform(.inspectElements); return }
        guard ACRShowDevToolsPanel(token, panel.rawValue) == 1 else { throw BrowserEngineError.unsupportedOperation }
    }
    public func updateAutomaticPictureInPicture(isSelected: Bool, allowed: Bool) {
        let enter = !isSelected && allowed
        guard !isDisposed, isBrowserCreated, (enter != automaticPiPShouldEnter || isSelected != automaticPiPIsSelected) else { return }
        if enter { automaticPiPSourceWindow = documentView.window }
        automaticPiPShouldEnter = enter
        automaticPiPIsSelected = isSelected
        automaticPiPRevision &+= 1
        guard automaticPiPTask == nil else { return }
        automaticPiPTask = Task { [weak self] in
            guard let self else { return }
            defer { automaticPiPTask = nil }
            repeat {
                let revision = automaticPiPRevision
                let enter = automaticPiPShouldEnter
                let generation = documentGeneration
                let returning = automaticPiPIsSelected
                await reconcileAutomaticPiP(enter: enter, returning: returning, generation: generation)
                guard !isDisposed, !Task.isCancelled else { return }
                if revision == automaticPiPRevision { return }
            } while true
        }
    }

    /// Each frame gets an isolated world. Cross-origin players use their own native DOM and
    /// permissions policy; no Node/IPC is exposed and page replacements of DOM APIs do not run.
    private func reconcileAutomaticPiP(enter: Bool, returning: Bool, generation: UInt64) async {
        if returning || !enter {
            guard let session = automaticPiPSession else { return }
            automaticPiPSession = nil
            guard session.generation == generation else { return }
            automaticPiPPresentation?.prepareForReturn()
            // Exit through the renderer so Chromium returns the existing player inline without
            // pausing it. No added fade, scale or travel accompanies the window removal.
            _ = await evaluatePiP(BrowserAutomaticPiPScript.returnToSource, context: session.context)
            return
        }
        guard enter else { return }
        let (ok, treeData) = await devToolsCall("Page.getFrameTree")
        guard ok, let json = try? JSONSerialization.jsonObject(with: treeData) as? [String: Any],
              let tree = json["frameTree"] as? [String: Any] else { return }
        func frames(_ node: [String: Any]) -> [String] {
            let id = (node["frame"] as? [String: Any])?["id"] as? String
            return (id.map { [$0] } ?? []) + (node["childFrames"] as? [[String: Any]] ?? []).flatMap(frames)
        }
        for frame in frames(tree) {
            guard !isDisposed, documentGeneration == generation, !Task.isCancelled else { return }
            guard let parameters = try? JSONSerialization.data(withJSONObject: ["frameId": frame, "worldName": "OrbitAutomaticPiP"]) else { continue }
            let (created, worldData) = await devToolsCall("Page.createIsolatedWorld", params: String(decoding: parameters, as: UTF8.self))
            guard created, let world = try? JSONSerialization.jsonObject(with: worldData) as? [String: Any],
                  let context = world["executionContextId"] as? Int,
                  documentGeneration == generation, !isDisposed else { continue }
            guard enter, automaticPiPShouldEnter else { return }
            let expression = BrowserAutomaticPiPScript.enter
            guard let evaluation = try? JSONSerialization.data(withJSONObject: [
                "expression": expression, "contextId": context, "returnByValue": true,
                "userGesture": true, "awaitPromise": true
            ]) else { continue }
            automaticPiPPresentation?.finish()
            automaticPiPPresentation = ChromiumPictureInPicturePresentation(sourceWindow: automaticPiPSourceWindow)
            let (evaluated, resultData) = await evaluateAutomaticPiP(evaluation)
            guard evaluated, let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
                  result["exceptionDetails"] == nil else { automaticPiPPresentation?.finish(); continue }
            if (result["result"] as? [String: Any])?["value"] as? Bool == true {
                automaticPiPSession = (context, generation)
                return
            }
            automaticPiPPresentation?.finish()
        }
    }

    private func evaluateAutomaticPiP(_ parameters: Data) async -> (Bool, Data) {
        let scoped = ACRSetAutomaticPiP(token, 1) == 1
        guard scoped || ACRPatchLevel() < 9 else { return (false, Data()) }
        defer { if scoped { _ = ACRSetAutomaticPiP(token, 0) } }
        return await devToolsCall("Runtime.evaluate", params: String(decoding: parameters, as: UTF8.self))
    }

    private func evaluatePiP(_ expression: String, context: Int) async -> (Bool, Data) {
        guard let parameters = try? JSONSerialization.data(withJSONObject: [
            "expression": expression, "contextId": context, "returnByValue": true, "awaitPromise": true
        ]) else { return (false, Data()) }
        return await devToolsCall("Runtime.evaluate", params: String(decoding: parameters, as: UTF8.self))
    }
}


extension ChromiumSurface {
    func layoutHostedDeveloperTools() -> Bool {
        guard !isDisposed, isBrowserCreated else { return false }
        return ACRLayoutDevTools(token) == 1
    }
}

/// Only the outer native window is owned here. Chromium owns the frontend,
/// its dock menu/splitter, protocol connection and inspected-page geometry.
@MainActor
final class ChromiumDeveloperToolsPresentation: NSObject, NSWindowDelegate {
    private weak var surface: ChromiumSurface?
    private var window: ChromiumDevToolsWindow?
    private var focusTask: Task<Void, Never>?

    init(surface: ChromiumSurface) { self.surface = surface }

    func reconcile(requestsFocus: Bool) {
        focusTask?.cancel()
        focusTask = nil
        guard let surface, !surface.isDisposed,
              let pointer = ACRDevToolsContainer(surface.token) else { close(); return }
        let state = ACRDevToolsPresentation(surface.token)
        let container = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
        if state == 4 {
            if window == nil {
                let native = ChromiumDevToolsWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 640),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                native.isReleasedWhenClosed = false
                native.title = uiText("Developer Tools")
                native.setAccessibilityIdentifier("devtools-undocked")
                native.delegate = self
                native.requestClose = { [weak surface] in
                    guard let surface, !surface.isDisposed else { return }
                    _ = ACRCloseDevTools(surface.token)
                }
                window = native
            }
            if window?.contentView !== container { window?.contentView = container }
            if requestsFocus { window?.makeKeyAndOrderFront(nil) }
        } else {
            if let native = window {
                native.contentView = nil
                native.close()
                window = nil
            }
            let root = surface.hostView
            if container.superview !== root {
                container.frame = root.bounds
                root.addSubview(container, positioned: .below, relativeTo: surface.documentView)
            }
            _ = ACRLayoutDevTools(surface.token)
            if state == 0 || state == 5 { return }
            if requestsFocus, root.window?.isKeyWindow != true {
                surface.delegate?.surfaceDidRequestActivation(surface)
            }
        }
        guard requestsFocus else { return }
        focusTask = Task { @MainActor [weak self, weak surface] in
            for _ in 0..<20 {
                guard !Task.isCancelled, let self, let surface, !surface.isDisposed,
                      ACRDevToolsPresentation(surface.token) == state else { return }
                let target = state == 4 ? window : surface.hostView.window
                if let target, target.isVisible {
                    NSApp.activate(ignoringOtherApps: true)
                    target.makeKeyAndOrderFront(nil)
                    _ = ACRFocusDevTools(surface.token)
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        window?.requestClose?()
        return false
    }

    func close() {
        focusTask?.cancel()
        focusTask = nil
        window?.contentView = nil
        window?.close()
        window = nil
    }
}

@MainActor
private final class ChromiumDevToolsWindow: NSWindow {
    var requestClose: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if (modifiers == .command && key == "w") || (modifiers == [.command, .option] && key == "i") {
            requestClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
