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
        _ = await until(40) { FileManager.default.fileExists(atPath: self.runRoot.appendingPathComponent("assistant-finish").path) }
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
