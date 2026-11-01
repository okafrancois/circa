import AppKit
import BrowserCore

/// Deterministic provider used only by the confined Chromium smoke executable.
actor OrbitAssistantFixtureClient: BrowserAIProviderClient {
    nonisolated let id: BrowserAIProviderID
    let root: URL
    private var count = 0
    init(id: BrowserAIProviderID, root: URL) { self.id = id; self.root = root }
    func status(refresh: Bool) async -> BrowserAIProviderStatus {
        .init(id: id, state: .ready(.init(plan: nil, usage: nil)), models: [])
    }
    func startTurn(_ request: BrowserAITurnRequest) async -> BrowserAITurn {
        count += 1
        try? Data(request.prompt.utf8).write(to: root.appendingPathComponent("request-\(id.rawValue)-\(count).txt"))
        let pair = AsyncStream<BrowserAITurnEvent>.makeStream()
        let task = Task {
            for text in ["Synthetic ", "streamed ", "answer. ", "[1: \"Actors protect mutable state.\"]"] {
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
        for id in [BrowserAIProviderID.codex, .claudeCode] {
            let client = OrbitAssistantFixtureClient(id: id, root: runRoot)
            environment.ai.clientOverrides[id] = client
            environment.ai.statuses[id] = await client.status(refresh: false)
        }
        try? await environment.settings.updateAI {
            $0.isEnabled = true
            $0.readsCurrentTabOnRequest = true
        }
        guard let window = owner.window else { check("assistant.window", false); return }
        NSApp.setActivationPolicy(.regular)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? Data("\(getpid()) \(window.windowNumber)".utf8).write(to: runRoot.appendingPathComponent("assistant-ready"))
        var sequence = 0
        _ = await until(40) {
            let commandURL = self.runRoot.appendingPathComponent("input-\(sequence).json")
            if let data = try? Data(contentsOf: commandURL) {
                var result = self.assistantOwnedInput(data, window: window, owner: owner)
                if let conversation = owner.aiConversation {
                    result["conversation"] = conversation.id.uuidString
                    result["messages"] = conversation.messages.map { ["id": $0.id.uuidString, "text": $0.text] }
                    result["sources"] = conversation.selectedSources.count
                }
                if let encoded = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                    try? encoded.write(to: self.runRoot.appendingPathComponent("ack-\(sequence).json"), options: .atomic)
                }
                sequence += 1
            }
            return FileManager.default.fileExists(atPath: self.runRoot.appendingPathComponent("assistant-finish").path)
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
    /// Only the marked, mock-keychain smoke driver calls this mailbox. Events never leave this process.
    private func assistantOwnedInput(_ data: Data, window: NSWindow, owner: OrbitWindowController) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: runRoot.appendingPathComponent(".orbit-chromium-lab").path),
              NSApp.windows.contains(where: { $0 === window }),
              let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              windows.contains(where: {
                  ($0[kCGWindowNumber as String] as? Int) == window.windowNumber &&
                  ($0[kCGWindowOwnerPID as String] as? Int) == Int(getpid())
              }),
              let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = command["kind"] as? String else { return ["ok": false, "error": "Invalid owned window or command"] }
        var handled = false
        switch kind {
        case "shortcut":
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
                // The product's local monitor offers raw feature input before menu equivalents.
                if owner.window === window, let registry = owner.palette.registry,
                   registry.capturePaletteTarget()?.windowID == owner.id {
                    handled = registry.handleInputEvent(event)
                }
                if !handled { handled = window.performKeyEquivalent(with: event) }
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
        case "gesture":
            if let points = command["points"] as? [[Double]], points.count >= 2,
               points.allSatisfy({ $0.count == 2 }) {
                var events: [NSEvent] = []
                for (index, point) in points.enumerated() {
                    let type: NSEvent.EventType = index == 0 ? .leftMouseDown :
                        (index == points.count - 1 ? .leftMouseUp : .leftMouseDragged)
                    if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: point[0], y: point[1]),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: index,
                        clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) { events.append(event) }
                }
                if events.count == points.count {
                    // Tracking controls consume the queued drag/up from their own nested event loop.
                    for event in events.dropFirst() { NSApp.postEvent(event, atStart: false) }
                    window.sendEvent(events[0])
                    handled = true
                }
            }
        case "capture": handled = true
        default: break
        }
        let responder = window.firstResponder
        return ["ok": handled, "pid": Int(getpid()), "window": window.windowNumber,
                "responder": responder.map { String(describing: type(of: $0)) } ?? "none",
                "text": (responder as? NSTextView)?.string ?? (responder as? NSTextField)?.stringValue ?? ""]
    }
}
