import AppKit
import QuartzCore
import BrowserCore
import ChromiumEngine

/// Deterministic provider used only by the confined Chromium smoke executable.
actor OrbitAssistantFixtureClient: BrowserAIProviderClient {
    nonisolated let id: BrowserAIProviderID
    let root: URL
    private var count = 0
    init(id: BrowserAIProviderID, root: URL) { self.id = id; self.root = root }
    func status(refresh: Bool) async -> BrowserAIProviderStatus {
        let mode = (try? String(contentsOf: root.appendingPathComponent("provider-state-\(id.rawValue)"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let state: BrowserAIProviderState
        switch mode {
        case "signed-out": state = .signedOut
        case "missing": state = .notInstalled
        case "unavailable": state = .unavailable(.programNotResponding)
        case "usage", "quota": state = .ready(.init(plan: "Synthetic plan", usage: .init(windows: [.init(span: .fiveHours, usedPercent: mode == "quota" ? 100 : 42, resetsAt: nil)])))
        default: state = .ready(.init(plan: nil, usage: nil))
        }
        return .init(id: id, state: state, models: [.init(provider: id, id: id == .claudeCode ? "sonnet" : "synthetic-codex", displayName: id == .claudeCode ? "Sonnet" : "Synthetic model", efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "low")])
    }
    func startTurn(_ request: BrowserAITurnRequest) async -> BrowserAITurn {
        count += 1
        try? Data(request.prompt.utf8).write(to: root.appendingPathComponent("request-\(id.rawValue)-\(count).txt"))
        let selection = ["provider": id.rawValue, "model": request.model ?? "", "effort": request.effort ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: selection, options: [.sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("selection-\(id.rawValue)-\(count).json"))
        }
        let mode = (try? String(contentsOf: root.appendingPathComponent("fixture-mode"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let passage = (try? String(contentsOf: root.appendingPathComponent("fixture-passage"), encoding: .utf8)) ?? "Actors protect mutable state."
        let pair = AsyncStream<BrowserAITurnEvent>.makeStream()
        let task = Task {
            if mode == "error" || mode == "quota" {
                pair.continuation.yield(.failed(mode == "quota" ? .limitReached(resetsAt: nil) : .failed))
                pair.continuation.finish()
                return
            }
            if mode == "slow" {
                do { try await Task.sleep(for: .milliseconds(3500)) } catch { return }
            }
            let chunks = mode == "code"
                ? ["Use `await` safely. ", "A wrapped run: `await actor.update(value: value, revalidateAfterSuspension: true, preserveSelection: true)` ", "[1: \"\(passage)\"]"]
                : ["Synthetic ", "streamed ", "answer. ", "[1: \"\(passage)\"]"]
            for text in chunks {
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                pair.continuation.yield(.text(text))
            }
            pair.continuation.yield(.completed)
            pair.continuation.finish()
        }
        return BrowserAITurn(events: pair.stream, interrupt: {
            task.cancel()
            pair.continuation.yield(.interrupted)
            pair.continuation.finish()
        })
    }
    func shutdown() async {}
}

extension OrbitSmokeDriver {
    func assistantInteractive(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        environment.ai.terminateNow()
        _ = await until(10) { !environment.ai.isChecking }
        if !arguments.contains("--orbit-smoke-assistant-live") {
        for id in [BrowserAIProviderID.codex, .claudeCode] {
            let client = OrbitAssistantFixtureClient(id: id, root: runRoot)
            environment.ai.clientOverrides[id] = client
            environment.ai.statuses[id] = await client.status(refresh: false)
        }
        }
        let assistantDisabled = arguments.contains("--orbit-smoke-assistant-disabled")
        let readingDisabled = arguments.contains("--orbit-smoke-assistant-read-off")
        let siteExcluded = arguments.contains("--orbit-smoke-assistant-excluded")
        try? await environment.settings.updateAI {
            $0.isEnabled = !assistantDisabled
            $0.readsCurrentTabOnRequest = !readingDisabled
            if siteExcluded { $0.disabledSites = ["127.0.0.1"] }
        }
        if arguments.contains("--orbit-smoke-assistant-live") {
            environment.ai.refresh(explicit: true, keepRunning: true)
            _ = await until(15) { !environment.ai.isChecking }
        }
        if arguments.contains("--orbit-smoke-assistant-folder"), let space = owner.session.organization?.spaceID {
            var members: [BrowserOrganizationNode] = []
            for name in ["folder-a", "folder-b"] {
                let url = fixture.appendingPathComponent(name)
                owner.openTab(url: url)
                _ = await committed(owner, url)
                if let tab = owner.session.organization?.selectedTab { members.append(.tab(tab.id)) }
            }
            _ = await owner.session.createFolder(title: "Synthetic folder", at: .init(.pinned(space)), containing: members).value
        }
        if arguments.contains("--orbit-smoke-assistant-private"), let application {
            application.createPrivateCommandWindow()
            await application.waitForPrivateWindowCommands()
        }
        owner.openTab(url: fixture)
        _ = await committed(owner, fixture)
        guard let window = owner.window else { check("assistant.window", false); return }
        application?.windowPresenter = { controller, activate in
            if activate { controller.showWindow(nil) }
            else { controller.window?.orderFront(nil) }
        }
        NSApp.setActivationPolicy(.regular)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? Data("\(getpid()) \(window.windowNumber)".utf8).write(to: runRoot.appendingPathComponent("assistant-ready"))
        var sequence = 0
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            let controllers = application.map { Array($0.windows.windows.values) } ?? environment.liveControllers
            for controller in controllers {
                guard let window = controller.window else { continue }
                if !window.isVisible || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
                    window.center()
                    window.makeKeyAndOrderFront(nil)
                }
            }
            let commandURL = self.runRoot.appendingPathComponent("input-\(sequence).json")
            if let data = try? Data(contentsOf: commandURL) {
                let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let targetNumber = command?["window"] as? Int ?? window.windowNumber
                let targetOwner = controllers.first { $0.window?.windowNumber == targetNumber } ?? owner
                guard let targetWindow = controllers.compactMap(\.window).first(where: { $0.windowNumber == targetNumber })
                    ?? NSApp.windows.first(where: { $0.windowNumber == targetNumber }) else { sequence += 1; continue }
                if command?["kind"] as? String == "fixture-status" && !arguments.contains("--orbit-smoke-assistant-live") {
                    for id in [BrowserAIProviderID.codex, .claudeCode] {
                        if let client = environment.ai.clientOverrides[id] {
                            environment.ai.statuses[id] = await client.status(refresh: true)
                        }
                    }
                }
                if command?["kind"] as? String == "space-polarity",
                   let space = targetOwner.session.organization?.spaceID,
                   let profile = targetOwner.session.activeProfileID {
                    let dark = command?["dark"] as? Bool ?? false
                    let theme = BrowserSpaceThemePresets.theme(family: BrowserSpaceThemePresets.greyscale, index: dark ? 8 : 0, mode: dark ? .dark : .light)
                    _ = try? await targetOwner.session.setSpaceTheme(theme, for: space, profileID: profile)
                }
                var result = self.assistantOwnedInput(data, window: targetWindow, owner: targetOwner)
                result["cardRadius"] = targetOwner.contentCard.cornerRadius
                result["fullscreen"] = targetWindow.styleMask.contains(.fullScreen)

                result["windows"] = controllers.compactMap { controller -> [String: Any]? in
                    guard let window = controller.window else { return nil }
                    return ["window": window.windowNumber, "owner": controller.id.uuidString, "private": controller.isPrivateWindow, "visible": window.isVisible, "onActiveSpace": window.isOnActiveSpace,
                            "occluded": !window.occlusionState.contains(.visible), "alpha": window.alphaValue,
                            "miniaturized": window.isMiniaturized, "tabbedWindows": window.tabbedWindows?.map(\.windowNumber) ?? [],
                            "frame": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height]]
                }
                if let panel = targetOwner.assistantHost {
                    let frame = targetOwner.contentCard.convert(panel.bounds, from: panel)
                    result["panelFrame"] = [frame.minX, frame.minY, frame.width, frame.height]
                    if let clip = panel.superview {
                        result["assistantRadius"] = clip.layer?.cornerRadius

                        let visible = targetOwner.contentCard.convert(clip.bounds, from: clip)
                        result["panelRevealFrame"] = [visible.minX, visible.minY, visible.width, visible.height]
                    }
                }
                if let settings = application?.settingsWindow?.window {
                    result["settingsWindow"] = settings.windowNumber
                    result["settingsVisible"] = settings.isVisible
                }
                result["assistantPopups"] = NSApp.windows.filter {
                    $0.identifier?.rawValue == "assistant-popup"
                }.map { popup in
                    ["window": popup.windowNumber, "parent": popup.parent?.windowNumber ?? 0,
                     "visible": popup.isVisible] as [String: Any]
                }
                result["uptime"] = ProcessInfo.processInfo.systemUptime
                result["frame"] = [targetWindow.frame.minX, targetWindow.frame.minY, targetWindow.frame.width, targetWindow.frame.height]
                if let surface = targetOwner.session.selectedSurface,
                   ["capture", "read-probe"].contains(command?["kind"] as? String ?? "") {
                    let host = surface.hostView
                    result["pageHost"] = ["width": host.bounds.width, "height": host.bounds.height,
                        "window": host.window?.windowNumber ?? 0, "hidden": host.isHiddenOrHasHiddenAncestor,
                        "children": host.subviews.map { ["type": String(describing: type(of: $0)), "width": $0.bounds.width,
                            "height": $0.bounds.height, "window": $0.window?.windowNumber ?? 0, "hidden": $0.isHiddenOrHasHiddenAncestor] }]
                    result["pageReads"] = await self.assistantReadProbe(surface, install: command?["kind"] as? String == "read-probe")
                    let (_, document) = await surface.devToolsCall("Runtime.evaluate", params: #"{"expression":"JSON.stringify({url:location.href,marks:Array.from(document.querySelectorAll('mark')).map(n=>n.textContent),scrollY:scrollY})","returnByValue":true}"#)
                    result["document"] = String(decoding: document, as: UTF8.self)
                }
                if targetOwner.window === targetWindow, let conversation = targetOwner.aiConversation {
                    result["conversation"] = conversation.id.uuidString
                    result["messages"] = conversation.messages.map { ["id": $0.id.uuidString, "text": $0.text] }
                    result["sources"] = conversation.selectedSources.count
                    result["sourceIDs"] = conversation.selectedSources.map { $0.id.uuidString }
                    result["running"] = conversation.isRunning
                    result["provider"] = conversation.choice.provider.rawValue
                    result["model"] = conversation.choice.model
                    result["effort"] = conversation.choice.effort
                }
                if let encoded = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                    try? encoded.write(to: self.runRoot.appendingPathComponent("ack-\(sequence).json"), options: .atomic)
                }
                sequence += 1
            }
            if FileManager.default.fileExists(atPath: self.runRoot.appendingPathComponent("assistant-finish").path) { break }
            try? await Task.sleep(for: .milliseconds(30))
        }
        if let conversation = owner.aiConversation {
            let evidence: [String: Any] = ["conversation": conversation.id.uuidString,
                "messages": conversation.messages.map { ["id": $0.id.uuidString, "text": $0.text] },
                "sources": conversation.selectedSources.count]
            if let data = try? JSONSerialization.data(withJSONObject: evidence) {
                try? data.write(to: runRoot.appendingPathComponent("assistant-state.json"))
            }
            conversation.close()
        }
    }
}


extension OrbitSmokeDriver {
    /// Counts extraction walkers in the reader's isolated world, on synthetic pages only.
    private func assistantReadProbe(_ surface: ChromiumSurface, install: Bool) async -> Int? {
        let (ok, data) = await surface.devToolsCall("Page.getFrameTree")
        guard ok, let tree = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let node = tree["frameTree"] as? [String: Any], let frame = node["frame"] as? [String: Any],
              let id = frame["id"] as? String,
              let params = try? JSONSerialization.data(withJSONObject: ["frameId": id, "worldName": "OrbitAssistantData"]) else { return nil }
        let (_, worldData) = await surface.devToolsCall("Page.createIsolatedWorld", params: String(decoding: params, as: UTF8.self))
        guard let world = try? JSONSerialization.jsonObject(with: worldData) as? [String: Any],
              let context = world["executionContextId"] as? Int else { return nil }
        let delay = FileManager.default.fileExists(atPath: runRoot.appendingPathComponent("delay-extraction").path) ? "const end=performance.now()+1800;while(performance.now()<end){};" : ""
        let script = install ? "(()=>{if(!globalThis.__ownedReaderProbe){globalThis.__ownedReaderProbe={count:0};const original=Document.prototype.createTreeWalker;Document.prototype.createTreeWalker=function(...args){globalThis.__ownedReaderProbe.count++;\(delay)return Reflect.apply(original,this,args)}}return globalThis.__ownedReaderProbe.count})()" : "globalThis.__ownedReaderProbe?.count ?? 0"
        guard let evaluation = try? JSONSerialization.data(withJSONObject: ["contextId": context, "expression": script, "returnByValue": true]) else { return nil }
        let (_, reply) = await surface.devToolsCall("Runtime.evaluate", params: String(decoding: evaluation, as: UTF8.self))
        let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
        return (json?["result"] as? [String: Any])?["value"] as? Int
    }
}


extension OrbitSmokeDriver {
    /// Only the marked, mock-keychain smoke driver calls this mailbox. Events never leave this process.
    private func assistantOwnedInput(_ data: Data, window: NSWindow, owner: OrbitWindowController) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: runRoot.appendingPathComponent(".orbit-chromium-lab").path),
              (owner.window === window || NSApp.windows.contains(where: { $0 === window })),
              let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              windows.contains(where: {
                  ($0[kCGWindowNumber as String] as? Int) == window.windowNumber &&
                  ($0[kCGWindowOwnerPID as String] as? Int) == Int(getpid())
              }),
              let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = command["kind"] as? String else { return ["ok": false, "error": "Invalid owned window or command"] }
        assistantInputWindow = window
        defer { assistantInputWindow = nil }
        var handled = false
        switch kind {
        case "shortcut", "native-shortcut", "menu-shortcut":
            var modifiers: NSEvent.ModifierFlags = []
            for flag in command["modifiers"] as? [String] ?? [] {
                switch flag {
                case "command": modifiers.insert(.command)
                case "option": modifiers.insert(.option)
                case "shift": modifiers.insert(.shift)
                case "control": modifiers.insert(.control)
                default: break
                }
            }
            if let key = command["text"] as? String,
               let event = BrowserGlobalQuickWindowShortcut.layoutEvent(for: .init(key: key, modifiers: modifiers)) {
                if kind == "native-shortcut", let native = NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: key,
                    charactersIgnoringModifiers: key, isARepeat: false, keyCode: event.keyCode) {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.postEvent(native, atStart: false)
                    return ["ok": true, "pid": Int(getpid()), "window": window.windowNumber, "queued": true]
                }
                // The product's local monitor offers raw feature input before menu equivalents.
                if owner.window === window, let registry = owner.palette.registry,
                   registry.capturePaletteTarget()?.windowID == owner.id {
                    let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true },
                        firstResponder: { window.firstResponder })
                    handled = keyboard.handle(event)
                }
                if !handled && kind != "menu-shortcut" { handled = window.performKeyEquivalent(with: event) }
                if !handled { handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false }
            }
        case "text":
            if let text = command["text"] as? String, let client = window.firstResponder as? NSTextInputClient {
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                handled = true
            }
        case "command":
            let commands = ["return": "insertNewline:", "tab": "insertTab:", "escape": "cancelOperation:"]
            if let name = command["text"] as? String, let selector = commands[name], let responder = window.firstResponder {
                responder.doCommand(by: NSSelectorFromString(selector))
                handled = true
            }
        case "gesture", "native-gesture":
            if let points = command["points"] as? [[Double]], points.count >= 2,
               points.allSatisfy({ $0.count == 2 }) {
                var pointerModifiers: NSEvent.ModifierFlags = []
                for flag in command["modifiers"] as? [String] ?? [] {
                    if flag == "shift" { pointerModifiers.insert(.shift) }
                    if flag == "option" { pointerModifiers.insert(.option) }
                    if flag == "command" { pointerModifiers.insert(.command) }
                    if flag == "control" { pointerModifiers.insert(.control) }
                }
                var events: [NSEvent] = []
                for (index, point) in points.enumerated() {
                    let type: NSEvent.EventType = index == 0 ? .leftMouseDown :
                        (index == points.count - 1 ? .leftMouseUp : .leftMouseDragged)
                    if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: point[0], y: point[1]),
                        modifierFlags: pointerModifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: index,
                        clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                        events.append(event)
                    }
                }
                if events.count == points.count {
                    // Tracking controls consume the queued drag/up from their own nested event loop.
                    if kind == "native-gesture" {
                        for event in events { NSApp.postEvent(event, atStart: false) }
                    } else {
                        for event in events.dropFirst() { NSApp.postEvent(event, atStart: false) }
                        window.sendEvent(events[0])
                    }
                    handled = true
                }
            }
        case "resize-window":
            if let size = command["size"] as? [Double], size.count == 2,
               (640...1440).contains(size[0]), (480...900).contains(size[1]) {
                window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: size[0], height: size[1])), display: true)
                window.contentView?.layoutSubtreeIfNeeded()
                handled = true
            }
        case "mouse-move":
            if let point = command["point"] as? [Double], point.count == 2,
               let content = window.contentView {
                let location = content.convert(NSPoint(x: point[0], y: point[1]), from: nil)
                if content.bounds.contains(location), let target = content.hitTest(location),
                   let event = NSEvent.mouseEvent(with: .mouseMoved,
                    location: NSPoint(x: point[0], y: point[1]), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                    target.mouseMoved(with: event)
                    handled = true
                }
            }
        case "scroll":
            if let point = command["point"] as? [Double], point.count == 2,
               let delta = command["delta"] as? Int32, abs(Int64(delta)) <= 100,
               let content = window.contentView {
                let location = content.convert(NSPoint(x: point[0], y: point[1]), from: nil)
                if content.bounds.contains(location), let target = content.hitTest(location),
                   let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                       wheel1: delta, wheel2: 0, wheel3: 0),
                   let event = NSEvent(cgEvent: wheel) {
                    target.scrollWheel(with: event)
                    handled = true
                }
            }
        case "sample-motion":
            let destination = runRoot.appendingPathComponent("motion-\(UUID().uuidString).json")
            Task { @MainActor in
                var samples: [[String: Any]] = []
                let start = ProcessInfo.processInfo.systemUptime
                while ProcessInfo.processInfo.systemUptime - start < 2 {
                    var layers: [[String: Any]] = []
                    func collect(_ layer: CALayer, path: String) {
                        if let presentation = layer.presentation() {
                            let transform = presentation.transform
                            layers.append(["path": path, "opacity": presentation.opacity,
                                "frame": [presentation.frame.minX, presentation.frame.minY, presentation.frame.width, presentation.frame.height],
                                "scale": [transform.m11, transform.m22], "animations": layer.animationKeys() ?? []])
                        }
                        for (index, child) in (layer.sublayers ?? []).enumerated() { collect(child, path: "\(path)/\(index)") }
                    }
                    for candidate in NSApp.windows where candidate === window || candidate.parent === window {
                        if let layer = candidate.contentView?.layer { collect(layer, path: String(candidate.windowNumber)) }
                    }
                    samples.append(["uptime": ProcessInfo.processInfo.systemUptime, "layers": layers])
                    try? await Task.sleep(for: .milliseconds(16))
                }
                if let data = try? JSONSerialization.data(withJSONObject: samples) { try? data.write(to: destination) }
            }
            handled = true
        case "raise-window":
            // A laboratory window can be shown without switching the owner's desktop.
            window.collectionBehavior.remove(.moveToActiveSpace)
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            handled = window.isVisible
        case "fullscreen":
            window.toggleFullScreen(nil)
            handled = true
        case "capture", "read-probe", "fixture-status", "space-polarity": handled = true
        default: break
        }
        let responder = window.firstResponder
        return ["ok": handled, "pid": Int(getpid()), "window": window.windowNumber,
                "responder": responder.map { String(describing: type(of: $0)) } ?? "none",
                "text": (responder as? NSTextView)?.string ?? (responder as? NSTextField)?.stringValue ?? ""]
    }
}
