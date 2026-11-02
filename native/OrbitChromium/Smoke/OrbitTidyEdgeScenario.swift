import AppKit
import BrowserCore
import BrowserShell
import BrowserEngine
import ChromiumEngine

extension OrbitSmokeDriver {
    func tidyEdges(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        guard let window = owner.window, let tab = owner.session.organization?.selectedTab else { return }
        func owns() -> Bool {
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
            return rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
        }
        func mode(_ value: String) { try? Data(value.utf8).write(to: runRoot.appendingPathComponent("fixture-mode")) }
        func requests() -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: runRoot.path)) ?? []).filter { $0.hasPrefix("request-codex-") }.count
        }
        guard owns() else { return }
        mode("error")
        owner.togglePinSidebarTargets()
        await owner.session.waitForQueuedCommands()
        _ = await until(3) { requests() > 0 }
        try? await Task.sleep(for: .milliseconds(500))
        check("tidy.error-no-title", owner.session.organizationTab(tab.id)?.customTitle == nil)
        guard owns() else { return }
        owner.togglePinSidebarTargets(); await owner.session.waitForQueuedCommands()
        mode("slow")
        let beforeRename = requests()
        guard owns() else { return }
        owner.togglePinSidebarTargets(); await owner.session.waitForQueuedCommands()
        _ = await until(3) { requests() > beforeRename }
        guard owns() else { return }
        owner.renameSidebarNode(.tab(tab.id), to: "Manual title")
        await owner.session.waitForQueuedCommands()
        try? await Task.sleep(for: .seconds(4))
        check("tidy.stale-manual-title", owner.session.organizationTab(tab.id)?.customTitle == "Manual title")
        guard owns() else { return }
        owner.togglePinSidebarTargets(); await owner.session.waitForQueuedCommands()
        owner.session.renameTab(tab.id, to: nil); await owner.session.waitForQueuedCommands()
        let beforeRevoke = requests()
        guard owns() else { return }
        owner.togglePinSidebarTargets(); await owner.session.waitForQueuedCommands()
        _ = await until(3) { requests() > beforeRevoke }
        try? await environment.settings.updateAI { $0.helpers.tidyTitlesAndDownloads = false }
        try? await Task.sleep(for: .seconds(4))
        check("tidy.revoked-title", owner.session.organizationTab(tab.id)?.customTitle == nil)
        try? await environment.settings.updateAI { $0.helpers.tidyTitlesAndDownloads = true }
        mode("tidy")
        let collision = runRoot.appendingPathComponent("Synthetic notes.pdf")
        try? Data("synthetic collision".utf8).write(to: collision)
        owner.downloads.destinationProvider = { [root = runRoot!] _, _ in root.appendingPathComponent("collision-original.pdf") }
        var downloadIndex = 0
        func download() async {
            guard owns() else { return }
            downloadIndex += 1
            let page = fixture.appendingPathComponent("tidy.html").appending(queryItems: [.init(name: "download", value: String(downloadIndex))])
            owner.openTab(url: page)
            await owner.session.waitForQueuedCommands()
            _ = await committed(owner, page)
            guard owns(), let surface = owner.pageCommandSurface(), let data = try? JSONSerialization.data(withJSONObject: [
                "expression": "var a=document.createElement('a');a.href='/download.pdf';a.download='INV-2026-10.pdf';document.body.append(a);a.click();true", "userGesture": true]) else { return }
            _ = await surface.devToolsCall("Runtime.evaluate", params: String(decoding: data, as: UTF8.self))
        }
        let beforeCollision = requests()
        await download()
        _ = await until(5) { requests() > beforeCollision }
        try? await Task.sleep(for: .seconds(1))
        check("tidy.collision-preserved", (try? String(contentsOf: collision, encoding: .utf8)) == "synthetic collision"
            && FileManager.default.fileExists(atPath: runRoot.appendingPathComponent("collision-original.pdf").path) && owner.tidyDownloadPanel == nil)
        mode("slow")
        let missing = runRoot.appendingPathComponent("missing-original.pdf")
        owner.downloads.destinationProvider = { _, _ in missing }
        let beforeMissing = requests()
        await download()
        let missingStarted = await until(5) { requests() > beforeMissing }
        check("tidy.missing-request-started", missingStarted)
        if missing.deletingLastPathComponent() == runRoot { try? FileManager.default.removeItem(at: missing) }
        try? await Task.sleep(for: .seconds(4))
        check("tidy.missing-cancelled", missingStarted && !FileManager.default.fileExists(atPath: missing.path) && owner.tidyDownloadPanel == nil)
        try? await environment.settings.updateAI { $0.helpers.tidyTitlesAndDownloads = false }
        let disabled = runRoot.appendingPathComponent("disabled-original.pdf")
        owner.downloads.destinationProvider = { _, _ in disabled }
        let beforeDisabled = requests()
        await download()
        try? await Task.sleep(for: .seconds(1))
        check("tidy.disabled-no-request", requests() == beforeDisabled && FileManager.default.fileExists(atPath: disabled.path))
        try? await environment.settings.updateAI { $0.helpers.tidyTitlesAndDownloads = true }
        let held = runRoot.appendingPathComponent("disabled-held.pdf")
        if disabled.deletingLastPathComponent() == runRoot {
            try? FileManager.default.moveItem(at: disabled, to: held)
            owner.downloads.invalidateFileChecks(in: runRoot)
            let becameMissing = await until(3) { owner.downloads.coordinator.allSnapshots.contains { $0.destinationURL == disabled && $0.fileAvailability == .missing } }
            try? FileManager.default.moveItem(at: held, to: disabled)
            owner.downloads.invalidateFileChecks(in: runRoot)
            let becameAvailable = await until(3) { owner.downloads.coordinator.allSnapshots.contains { $0.destinationURL == disabled && $0.fileAvailability == .available } }
            try? await Task.sleep(for: .seconds(1))
            check("tidy.reenabled-does-not-rename-old-file", becameMissing && becameAvailable && requests() == beforeDisabled && FileManager.default.fileExists(atPath: disabled.path))
        }
        environment.ai.terminateNow()
    }
}
