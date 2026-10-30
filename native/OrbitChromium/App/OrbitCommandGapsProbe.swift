import AppKit
import BrowserEngine
import ChromiumEngine

/// Synthetic qualification of native menu and character-based shortcut dispatch.
@MainActor
enum OrbitCommandGapsProbe {
    static let bundleID = "lab.orbit.orbit.command-gaps"

    private static func owns(_ owner: OrbitWindowController) -> Bool {
        guard Bundle.main.bundleIdentifier == bundleID,
              let configuration = activeSiteSessionConfiguration(), configuration.syntheticGuard != nil,
              configuration.usesMockKeychain, let window = owner.window,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
        return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
            && ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
    }

    static func run(_ owner: OrbitWindowController) async -> [String: Any] {
        guard owns(owner), let window = owner.window, let registry = owner.palette.registry else { return ["refused": true] }
        owner.session.openTab(url: URL(string: "about:blank")!)
        await owner.session.waitForPendingCommands()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while (owner.session.selectedSurface?.isReady != true || owner.session.selectedSurface?.navigationState.isLoading == true), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(250))
        owner.palette.dismiss()
        window.setFrameOrigin(NSPoint(x: -4000, y: 100))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(150))
        window.setFrameOrigin(NSPoint(x: -4000, y: 100))
        guard window.frame.maxX < 0, window.isKeyWindow else { return ["refused": true, "offscreen": window.frame.maxX < 0, "key": window.isKeyWindow] }
        let editor = NSTextView(frame: NSRect(x: 20, y: 20, width: 320, height: 80))
        editor.isRichText = true
        window.contentView?.addSubview(editor)
        defer { editor.removeFromSuperview() }
        guard owns(owner), window.makeFirstResponder(editor) else { return ["refused": true] }
        var checks: [String: Bool] = [:]
        var methods: [String: String] = [:]
        func item(_ id: BrowserCommandID, in menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            for row in menu.items {
                if row.identifier?.rawValue == id.rawValue { return row }
                if let found = item(id, in: row.submenu) { return found }
            }
            return nil
        }
        func invoke(_ id: BrowserCommandID, shortcut: Bool = false) -> Bool {
            guard owns(owner), window.frame.maxX < 0, window.isKeyWindow,
                  let row = item(id, in: NSApp.mainMenu), let action = row.action else { return false }
            methods[id.rawValue] = shortcut ? "character shortcut" : "menu action"
            if shortcut {
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: row.keyEquivalentModifierMask,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: row.keyEquivalent, charactersIgnoringModifiers: row.keyEquivalent, isARepeat: false, keyCode: 0) else { return false }
                return NSApp.mainMenu?.performKeyEquivalent(with: event) == true
            }
            return NSApp.sendAction(action, to: row.target, from: row)
        }
        for (id, expected): (BrowserCommandID, String) in [(.makeUpperCase, "HELLO WORLD"), (.makeLowerCase, "hello world"), (.capitalize, "Hello World"), (.delete, "")] {
            editor.string = "hello WORLD"
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            checks[id.rawValue] = invoke(id) && editor.string == expected
        }
        let toggles: [(BrowserCommandID, () -> Bool)] = [
            (.checkSpellingWhileTyping, { editor.isContinuousSpellCheckingEnabled }),
            (.checkGrammarWithSpelling, { editor.isGrammarCheckingEnabled }),
            (.correctSpellingAutomatically, { editor.isAutomaticSpellingCorrectionEnabled }),
            (.smartCopyPaste, { editor.smartInsertDeleteEnabled }),
            (.smartQuotes, { editor.isAutomaticQuoteSubstitutionEnabled }),
            (.smartDashes, { editor.isAutomaticDashSubstitutionEnabled }),
            (.smartLinks, { editor.isAutomaticLinkDetectionEnabled }),
            (.dataDetectors, { editor.isAutomaticDataDetectionEnabled }),
            (.textReplacement, { editor.isAutomaticTextReplacementEnabled })
        ]
        for (id, value) in toggles {
            let before = value()
            checks[id.rawValue] = invoke(id) && value() != before
            _ = invoke(id)
        }
        for id: BrowserCommandID in [.bold, .italic, .underline] {
            editor.string = "Synthetic text"
            editor.font = NSFont.systemFont(ofSize: 14)
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            editor.updateFontPanel()
            let accepted = invoke(id, shortcut: true)
            let font = editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            checks[id.rawValue] = accepted && (id == .bold ? traits.contains(.boldFontMask)
                : id == .italic ? traits.contains(.italicFontMask)
                : (editor.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int ?? 0) != 0)
        }
        guard owns(owner) else { return ["refused": true] }
        window.makeFirstResponder(owner.session.selectedSurface?.hostView)
        owner.showLibrary()
        await owner.session.waitForPendingCommands()
        checks["exit"] = invoke(.exit)
        await owner.session.waitForPendingCommands()
        checks["exit"] = checks["exit"] == true && !owner.library.isPresented
        guard owns(owner) else { return ["refused": true] }
        // The registry path must also change the same native editor, with no clipboard access.
        guard owns(owner) else { return ["refused": true] }
        window.makeFirstResponder(editor)
        editor.string = "registry"
        editor.setSelectedRange(NSRange(location: 0, length: 8))
        checks["registryAccepted"] = registry.dispatch(.makeUpperCase, origin: .palette)
        await owner.session.waitForPendingCommands()
        checks["registryEffect"] = editor.string == "REGISTRY"
        return ["pid": getpid(), "offscreen": window.frame.maxX < 0, "key": window.isKeyWindow,
                "checks": checks, "methods": methods]
    }
}
