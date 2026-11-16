import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Foundation

/// Synthetic-only proof that history deletions in Circa also leave the engine's own history.
/// Visits loopback pages on two hosts, opens Library > History in its own window, and shows the
/// engine's history page of the same profile (a windowless chrome://history page, which reloads
/// itself on every engine history deletion) in a second window of this process. It then deletes
/// one host, one visit and a time interval through the Library; a second launch deletes the last
/// hour. Both lists are recorded after each step. The external script records the two windows (window IDs
/// published only after their owner PID is verified) and reads the engine's History database
/// read-only after the clean shutdown.
@MainActor
enum OrbitHistoryEnginePurgeProbe {
    static let bundleID = "lab.orbit.orbit.history-engine-purge"

    static func run(_ owner: OrbitWindowController, environment: OrbitEnvironment, command: [String: String],
                    root: URL) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true,
              let text = command["url"], let base = URL(string: text), base.host == "127.0.0.1", base.scheme == "http",
              let port = base.port, let alternate = URL(string: "http://localhost:\(port)/"),
              let window = owner.window, owns(window), let profile = owner.session.activeProfileID
        else { return ["refused": true] }
        var result: [String: Any] = [:]
        let recorder = owner.library.history.recorder

        let period = command["step"] == "period"
        // 1. Visits: two pages on each loopback host, then a later one for the interval step. The
        //    period run (second launch) adds one more visit to the page the first run kept.
        let pages = period ? [alternate.appendingPathComponent("zeta")]
            : [base.appendingPathComponent("alpha"), base.appendingPathComponent("beta"),
               alternate.appendingPathComponent("gamma"), alternate.appendingPathComponent("delta")]
        for page in pages { guard await visit(owner, page) else { return ["navigation": page.lastPathComponent] } }
        var intervalStart = Date()
        if !period {
            try? await Task.sleep(for: .milliseconds(1500))
            intervalStart = Date()
            guard await visit(owner, base.appendingPathComponent("epsilon")) else { return ["navigation": "epsilon"] }
        }
        await recorder.flush()

        // 2. The engine's own history page of this profile, and its live mirror window.
        let delegate = EnginePageDelegate()
        let engine = environment.engine.makeSurface(profileID: profile, delegate: delegate)
        defer { engine.dispose() }
        engine.navigate(to: URL(string: "chrome://history/")!)
        for _ in 0..<200 {
            if engine.isReady, !engine.navigationState.isLoading, engine.navigationState.committedURL?.host == "history" { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        try? await Task.sleep(for: .milliseconds(600))
        let mirror = EngineHistoryWindow(beside: window)
        defer { mirror.window.close() }
        var engineRows: [[String: Any]] = []
        let refresh = Task { @MainActor in
            while !Task.isCancelled {
                engineRows = await engineHistory(engine)
                mirror.show(engineRows, circa: owner.library.history.visits)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { refresh.cancel() }

        owner.library.historyConfirmation = { _ in .alertFirstButtonReturn }
        owner.showLibrary(.history)
        await owner.session.waitForQueuedCommands()
        await owner.library.history.task?.value
        window.setFrame(NSRect(x: 60, y: 140, width: 900, height: 640), display: true)
        mirror.window.setFrame(NSRect(x: 970, y: 140, width: 620, height: 640), display: true)
        window.makeKeyAndOrderFront(nil)
        mirror.window.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(700))
        result["before"] = snapshot(engineRows, owner)
        guard owns(mirror.window) else { return result.merging(["mirror": false]) { $1 } }
        // Ask the script to start both recordings, then give it a moment.
        try? "\(window.windowNumber):\(mirror.window.windowNumber)"
            .write(to: root.appendingPathComponent("history-windows.txt"), atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(3000))

        func step(_ name: String, _ action: () async -> Void) async {
            let started = ContinuousClock.now
            await action()
            await owner.library.deletionTask?.value
            await recorder.flushEngineRemovals()
            result[name + "Milliseconds"] = Int((ContinuousClock.now - started) / .milliseconds(1))
            result[name + "Engine"] = ChromiumBrowserEngine.lastHistoryRemovalReport
            try? await Task.sleep(for: .milliseconds(2500))
            result[name] = snapshot(engineRows, owner)
        }
        if period {
            // The Library's "Delete History > Last Hour" (confirmed): a period the engine's
            // clear-browsing-data path removes by itself.
            await step("lastHour") {
                owner.library.historyView.onDeleteRange?(1)
                await owner.library.confirmationTask?.value
            }
            try? "stop".write(to: root.appendingPathComponent("history-stop.txt"), atomically: true, encoding: .utf8)
            owner.library.historyConfirmation = nil
            let engineNames = ((result["before"] as? [String: Any])?["engine"] as? [String] ?? []).compactMap { URL(string: $0)?.lastPathComponent }
            let after = result["lastHour"] as? [String: Any]
            // The restored tab reloads the page it showed at quit, which is a new visit too.
            result["passed"] = Set(["alpha", "zeta"]).isSubset(of: engineNames)
                && (after?["engine"] as? [String])?.isEmpty == true && (after?["circa"] as? [String])?.isEmpty == true
            return result
        }
        // 3. One site, through the Library row's "Delete History for This Site" (confirmed).
        await step("site") {
            if let row = owner.library.history.visits.first(where: { $0.url.host == "localhost" }) {
                owner.library.historyView.onDeleteSite?(row)
                await owner.library.confirmationTask?.value
            }
        }
        // 4. One visit, through the Library row's Delete.
        await step("visit") {
            if let row = owner.library.history.visits.first(where: { $0.url.lastPathComponent == "beta" }) {
                owner.library.historyView.onDelete?(row)
            }
        }
        // 5. A custom interval (the range sheet's result) covering only the latest visit.
        await step("interval") {
            _ = await owner.library.history.delete(.interval(DateInterval(start: intervalStart, end: Date().addingTimeInterval(1))),
                                                   in: profile)
        }
        try? await Task.sleep(for: .milliseconds(3000))  // The final state stays on screen.
        try? "stop".write(to: root.appendingPathComponent("history-stop.txt"), atomically: true, encoding: .utf8)
        owner.library.historyConfirmation = nil

        let urls = { (name: String) in ((result[name] as? [String: Any])?["engine"] as? [String]) ?? [] }
        let circa = { (name: String) in ((result[name] as? [String: Any])?["circa"] as? [String]) ?? [] }
        let names = { (list: [String]) in Set(list.compactMap { URL(string: $0)?.lastPathComponent }) }
        result["passed"] = names(urls("before")) == ["alpha", "beta", "gamma", "delta", "epsilon"]
            && names(urls("site")) == ["alpha", "beta", "epsilon"] && names(circa("site")) == ["alpha", "beta", "epsilon"]
            && names(urls("visit")) == ["alpha", "epsilon"] && names(circa("visit")) == ["alpha", "epsilon"]
            && names(urls("interval")) == ["alpha"] && names(circa("interval")) == ["alpha"]
        return result
    }

    private static func visit(_ owner: OrbitWindowController, _ url: URL) async -> Bool {
        owner.submitAddress(url.absoluteString)
        await owner.session.waitForPendingCommands()
        for _ in 0..<250 {
            if let surface = owner.session.selectedSurface, surface.isReady, !surface.navigationState.isLoading,
               surface.navigationState.committedURL == url {
                try? await Task.sleep(for: .milliseconds(350))
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// What the engine's history page lists (newest first).
    private static func engineHistory(_ surface: ChromiumSurface) async -> [[String: Any]] {
        let value = await OrbitPerformanceProbe.evaluate(surface, """
            (() => { const list = document.querySelector('history-app')?.shadowRoot?.querySelector('history-list');
              return {rows: (list?.historyData_ ?? []).map(e => ({url: e.url, title: e.title, time: e.time}))}; })()
            """)
        return value?["rows"] as? [[String: Any]] ?? []
    }

    private static func snapshot(_ rows: [[String: Any]], _ owner: OrbitWindowController) -> [String: Any] {
        ["engine": rows.compactMap { $0["url"] as? String },
         "circa": owner.library.history.visits.map(\.url.absoluteString)]
    }

    private static func owns(_ window: NSWindow) -> Bool {
        guard window.isVisible,
              let entries = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
        else { return false }
        return entries.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
            && ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
    }

    /// Allows exactly the engine history page; never opens windows, downloads or permissions.
    private final class EnginePageDelegate: BrowserEngineSurfaceDelegate {
        typealias Surface = ChromiumSurface
        func surfaceDidStartNavigation(_ surface: Surface) {}
        func surfaceDidCommitNavigation(_ surface: Surface) {}
        func surfaceDidFinishNavigation(_ surface: Surface) {}
        func surfaceDidFailNavigation(_ surface: Surface) {}
        func surfaceDidRequestClose(_ surface: Surface) {}
        func surface(_ surface: Surface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
        func surface(_ surface: Surface, createSurfaceFor request: BrowserNewSurfaceRequest, make: () -> Surface) -> Surface? { nil }
        func surface(_ surface: Surface, requestsPermission request: BrowserPermissionRequest) async -> BrowserPermissionDecision { .deny }
        func surface(_ surface: Surface, decidePolicyFor action: BrowserNavigationAction,
                     decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
            decision.decide(action.url?.absoluteString == "chrome://history/" ? .allow : .cancel)
        }
    }

    /// Lab window mirroring the engine's history page next to the Library, synthetic data only.
    @MainActor
    private final class EngineHistoryWindow {
        let window: NSWindow
        private let text = NSTextView()

        init(beside owner: NSWindow) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Engine history — chrome://history (same profile)"
            let scroll = NSScrollView()
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            text.isEditable = false
            text.textContainerInset = NSSize(width: 18, height: 18)
            text.autoresizingMask = [.width]
            window.contentView = scroll
        }

        func show(_ rows: [[String: Any]], circa: [BrowserHistoryVisit]) {
            let output = NSMutableAttributedString()
            let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                                                          .foregroundColor: NSColor.labelColor]
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                                       .foregroundColor: NSColor.labelColor]
            let muted: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            output.append(NSAttributedString(string: "Engine history: \(rows.count) entries\n", attributes: heading))
            output.append(NSAttributedString(string: "Read live from the engine's own history page of this profile.\n\n",
                                             attributes: muted))
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            for row in rows {
                let url = row["url"] as? String ?? ""
                let time = (row["time"] as? Double).map { formatter.string(from: Date(timeIntervalSince1970: $0 / 1000)) } ?? ""
                output.append(NSAttributedString(string: "\(time)  \(url)\n", attributes: body))
            }
            if rows.isEmpty { output.append(NSAttributedString(string: "(empty)\n", attributes: muted)) }
            output.append(NSAttributedString(string: "\nCirca history: \(circa.count) visits\n", attributes: muted))
            text.textStorage?.setAttributedString(output)
        }
    }
}
