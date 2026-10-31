import AppKit
import BrowserCore
import BrowserShell
import ChromiumEngine

extension OrbitSmokeDriver {
    /// Repeats archive preview -> close -> hide Library with timings from 0 to 300 ms, on this process's own window.
    /// `--orbit-smoke-stress-range=START:COUNT` selects the iterations of this session.
    func littleArchiveStress(_ application: OrbitApplication, _ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        func check(_ name: String, _ passed: Bool) { self.check("archive-stress." + name, passed) }
        guard let window = owner.window else { check("context", false); return }
        func ownsWindow() -> Bool {
            guard window.windowNumber > 0 else { return false }
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
            return rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
        }
        environment.autoArchive.scheduler.stop()
        let range = arguments.first { $0.hasPrefix("--orbit-smoke-stress-range=") }.map { String($0.dropFirst("--orbit-smoke-stress-range=".count)) } ?? "0:12"
        let parts = range.split(separator: ":").compactMap { Int($0) }
        let start = parts.first ?? 0, count = parts.count > 1 ? parts[1] : 12
        let delays = [0, 5, 15, 30, 50, 80, 120, 160, 200, 250, 300]
        func find(_ identifier: String, in parent: NSView) -> NSView? {
            if parent.accessibilityIdentifier() == identifier { return parent }
            for child in parent.subviews { if let found = find(identifier, in: child) { return found } }
            return nil
        }
        do {
            window.setFrame(NSRect(x: -8000, y: 0, width: 1100, height: 780), display: false)
            window.orderFront(nil)
            for name in ["stress-one", "stress-two", "stress-three"] {
                owner.session.openTab(url: fixture.appendingPathComponent(name))
                await owner.session.waitForPendingCommands()
                owner.session.closeSelectedTab()
                await owner.session.waitForPendingCommands()
            }
            let registry = application.commands.registry
            var failures = 0
            for index in start..<(start + count) {
                let delay = delays[index % delays.count]
                let withFilter = index % 3 == 0
                owner.showArchive()
                await owner.session.waitForPendingCommands()
                await owner.archive.task?.value
                owner.library.view.acceptsLibraryInput = true
                try await Task.sleep(for: .milliseconds(250))
                if withFilter, ownsWindow(), let filter = find("archive-filter", in: window.contentView!) as? NSButton {
                    filter.performClick(nil)
                    if ownsWindow() { (find("archive-filter-closed", in: window.contentView!) as? NSButton)?.performClick(nil) }
                    if ownsWindow() { (find("archive-filter-done", in: window.contentView!) as? NSButton)?.performClick(nil) }
                }
                let table = owner.archive.view.table
                guard let row = owner.archive.view.rows.firstIndex(where: { if case .tab = $0 { return true }; return false }) else { check("row-\(index)", false); failures += 1; continue }
                guard ownsWindow() else { check("window-owner-\(index)", false); failures += 1; continue }
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if let action = table.action { _ = NSApp.sendAction(action, to: table.target, from: table) }
                let opened = await until(6, { owner.isPeekPresented })
                // Vary how far the open animation has run before closing.
                try await Task.sleep(for: .milliseconds(150 + (index % 4) * 200))
                let target = registry.captureTarget(windowID: application.windows.selectedWindowID)
                // Command-W resolves to archiveTab while the archive preview is active.
                let handled = ownsWindow() && registry.dispatch(.archiveTab, origin: .keyboard, target: target)
                if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                guard ownsWindow() else { check("hide-owner-\(index)", false); failures += 1; continue }
                owner.hideLibrary()
                try await Task.sleep(for: .milliseconds(900))
                await owner.session.waitForPendingCommands()
                let clean = opened && handled && !owner.isPeekPresented && !owner.library.isPresented && owner.archive.previewTabID == nil
                if !clean { failures += 1 }
                record("archive-stress.iteration-\(index)", clean ? "proven" : "failed",
                       ["delayMs": delay, "filter": withFilter, "opened": opened,
                        "handled": handled, "peek": owner.isPeekPresented, "library": owner.library.isPresented])
            }
            check("session-\(start)-\(count)", failures == 0)
        } catch { check("operation", false) }
    }
}
