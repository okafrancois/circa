import AppKit
import BrowserCore
import ChromiumEngine

extension OrbitSmokeDriver {
    func boostRenameScenario(_ environment: OrbitEnvironment, _ owner: OrbitWindowController,
                             _ engine: ChromiumBrowserEngine) async {
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func check(_ name: String, _ value: Bool) { self.check("boost-rename." + name, value) }
        func gate(_ window: NSWindow?) -> Bool {
            guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.boost-rename.synthetic", let window,
                  let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]],
                  let row = rows.first,
                  (row[kCGWindowOwnerPID as String] as? Int32) == getpid(),
                  (row[kCGWindowNumber as String] as? Int) == window.windowNumber else {
                check("input-refused", false); return false
            }
            event("boost-rename-input-gate", ["pid": getpid(), "window": window.windowNumber, "passed": true])
            return true
        }
        owner.window?.setContentSize(NSSize(width: 1506, height: 920))
        owner.window?.center(); owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await environment.settings.markBoostsIntroductionSeen()
        let url = fixture.appendingPathComponent("fixture")
        guard gate(owner.window) else { return }
        owner.submitAddress(url.absoluteString)
        guard await committed(owner, url) != nil, gate(owner.window) else { return }
        owner.createBoost(); await owner.boostTask?.value
        guard let editor = owner.boostEditor, let panel = editor.window, let parent = owner.window else {
            check("create", false); return
        }
        panel.setFrameOrigin(NSPoint(x: parent.frame.maxX - 193, y: parent.frame.maxY - 735))
        panel.makeKeyAndOrderFront(nil)
        try? JSONSerialization.data(withJSONObject: ["pid": getpid(), "parent": parent.windowNumber, "panel": panel.windowNumber])
            .write(to: runRoot.appendingPathComponent("capture-window.json"))
        _ = await until(8) { FileManager.default.fileExists(atPath: self.runRoot.appendingPathComponent("capture-ready").path) }
        let menu = editor.editor.makeHeaderMenu()
        func openMenu() async -> Bool {
            guard gate(panel) else { return false }
            let target = BoostRenameMenuSelection(menu: menu) { gate(panel) }
            let timer = Timer(timeInterval: 0.7, target: target, selector: #selector(BoostRenameMenuSelection.selectRename), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            menu.popUp(positioning: nil, at: NSPoint(x: 40, y: 34), in: editor.editor)
            await pause(0.7)
            return editor.renameSheet != nil
        }
        await pause(0.5); event("boost-rename-cancel-start", [:])
        guard await openMenu(), let cancel = editor.renameSheet else { check("cancel-sheet", false); return }
        check("prefill", cancel.nameField.stringValue == "My Boost")
        check("selection", (cancel.nameField.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 8))
        check("default-button", parent.defaultButtonCell === cancel.done.cell)
        check("modal", owner.commandState.isModal)
        check("sheet-key-window", parent.isKeyWindow && NSApp.keyWindow === parent)
        await pause(0.9)
        guard gate(parent) else { return }
        cancel.cancel.performClick(nil)
        await pause(0.65)
        check("cancel", editor.renameSheet == nil && editor.session.boost.title == "My Boost")
        check("cancel-store", await editor.session.store.snapshot().boosts.first?.title == "My Boost")
        event("boost-rename-cancel-end", [:]); await pause(0.5)
        event("boost-rename-done-start", [:])
        guard await openMenu(), let done = editor.renameSheet, gate(parent),
              let text = done.nameField.currentEditor() as? NSTextView else { check("done-sheet", false); return }
        text.insertText("Orbit Recorder 10 Final", replacementRange: text.selectedRange())
        await pause(0.8)
        guard gate(parent) else { return }
        done.done.performClick(nil)
        await pause(0.5); await editor.session.pending?.value
        check("done", editor.renameSheet == nil && editor.session.boost.title == "Orbit Recorder 10 Final")
        check("persisted", await editor.session.store.snapshot().boosts.first?.title == "Orbit Recorder 10 Final")
        check("header", editor.editor.subviews.contains { ($0 as? NSButton)?.title == "Orbit Recorder 10 Final" })
        await pause(0.8); event("boost-rename-done-end", [:])
        // Exercise real field-editor command dispatch for Escape and Return, including blank input.
        guard gate(panel) else { return }; editor.beginRename(); await pause(0.4)
        guard let escaped = editor.renameSheet, gate(parent), let text = escaped.nameField.currentEditor() as? NSTextView else { return }
        text.doCommand(by: #selector(NSResponder.cancelOperation(_:))); await pause(0.4)
        check("escape", editor.renameSheet == nil && editor.session.boost.title == "Orbit Recorder 10 Final")
        guard gate(panel) else { return }; editor.beginRename(); await pause(0.4)
        guard let returned = editor.renameSheet, gate(parent), let text = returned.nameField.currentEditor() as? NSTextView else { return }
        text.insertText("   ", replacementRange: text.selectedRange())
        check("empty-disabled", !returned.done.isEnabled)
        guard gate(parent) else { return }; text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check("empty-return", editor.renameSheet === returned && !returned.isFinishing)
        guard gate(parent) else { return }; text.selectAll(nil)
        guard gate(parent) else { return }; text.insertText("Library renamed fixture", replacementRange: text.selectedRange())
        guard gate(parent) else { return }; text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await pause(0.5); await editor.session.pending?.value
        check("return", editor.session.boost.title == "Library renamed fixture" && editor.renameSheet == nil)
        guard gate(panel) else { return }
        editor.editor.onAllBoosts?()
        await owner.session.waitForPendingCommands()
        await owner.library.boostsTask?.value
        check("library", owner.library.boostsView.displayed.map(\.title) == ["Library renamed fixture"])
        guard gate(parent) else { return }
        owner.library.boostsView.searchField.stringValue = "Library renamed"
        owner.library.boostsView.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        check("library-search", owner.library.boostsView.displayed.count == 1)
        await pause(0.5)
    }
}

@MainActor
private final class BoostRenameMenuSelection: NSObject {
    let menu: NSMenu
    let gate: () -> Bool
    init(menu: NSMenu, gate: @escaping () -> Bool) { self.menu = menu; self.gate = gate }
    @objc func selectRename() {
        guard gate() else { menu.cancelTracking(); return }
        menu.cancelTracking()
        let item = menu.items[0]
        NSApp.sendAction(item.action!, to: item.target, from: item)
    }
}
