import AppKit
import BrowserCore
import Carbon
import OSAKit

/// Fixed, self-addressed scripts only. The synthetic command endpoint never accepts script text.
@MainActor
enum OrbitScriptingProbe {
    static let bundleID = "lab.orbit.orbit.applescript-verify"

    static func run(_ app: OrbitApplication, owner: OrbitWindowController, root: URL,
                    command: [String: String]) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == bundleID,
              let guardRoot = activeSyntheticDataGuard(), (try? guardRoot.checkInside(root)) != nil,
              activeSiteSessionConfiguration()?.usesMockKeychain == true,
              let window = owner.window, window.windowController === owner,
              NSApp.windows.contains(where: { $0 === window }),
              NSRunningApplication.current.processIdentifier == getpid(),
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier) == [getpid()] else { return ["refused": true] }
        // A non-prompting admission check precedes even script compilation.
        let address = NSAppleEventDescriptor(processIdentifier: getpid())
        let permission = AEDeterminePermissionToAutomateTarget(address.aeDesc, typeWildCard, typeWildCard, false)
        guard permission == noErr else { return ["refused": true, "permission": permission] }
        let output = root.appendingPathComponent("scripting-state.json")
        var checks: [String] = []
        var stage = "self-count"
        func publish(_ status: String, _ detail: String = "") {
            let values: [String: Any] = ["pid": getpid(), "status": status, "stage": stage,
                                         "checks": checks, "detail": detail]
            if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) {
                try? data.write(to: output, options: .atomic)
            }
        }
        func script(_ name: String, _ body: String) async throws -> String {
            stage = name; publish("running")
            let result = await execute("tell application id \"" + bundleID + "\"\n" + body + "\nend tell")
            guard result.code == 0 else { throw ProbeFailure(message: "\(result.code): \(result.text)") }
            checks.append(name)
            return result.text
        }
        app.confirmQuit = { .quit }
        do {
            let count = try await script("self-count", "return (count windows) as text")
            guard Int(count).map({ $0 > 0 }) == true else { throw ProbeFailure(message: "No scripting window") }
            if command["operation"] == "spike" {
                publish("passed", count)
                return ["passed": true, "checks": checks]
            }
            guard let settings = app.environment?.settings else { throw ProbeFailure(message: "Missing settings") }
            try await settings.setAllowJavaScriptFromAppleEvents(false)
            _ = try await script("inventory", """
                set windowIDs to id of windows
                set windowNames to name of windows
                if (count windowIDs) is not (count windowNames) then error "Window inventory mismatch"
                set spaceIDs to id of spaces of window 1
                set spaceNames to title of spaces of window 1
                if (count spaceIDs) is not (count spaceNames) then error "Space inventory mismatch"
                set listedTitles to title of tabs of window 1
                set listedURLs to URL of tabs of window 1
                if (count listedTitles) is not (count listedURLs) then error "Inventory mismatch"
                return count listedURLs
                """)
            _ = try await script("make-set-read", """
                set initialCount to count tabs of window 1
                set createdTab to make new tab at end of tabs of front window with properties {URL:"about:blank#created"}
                set createdID to id of createdTab
                if (count tabs of window 1) is not initialCount + 1 then error "Create failed"
                delay 0.3
                set URL of createdTab to "about:blank#changed"
                delay 0.3
                set readBack to {id, title, URL} of createdTab
                if item 1 of readBack is not createdID then error "Identity changed"
                if item 3 of readBack is not "about:blank#changed" then error "URL did not change"
                return createdID
                """)
            // Return-value object specifiers are exercised again in each independently compiled script.
            _ = try await script("select-reload-back", """
                set t to last tab of window 1
                select t
                if id of active tab of window 1 is not id of t then error "Selection failed"
                reload t
                delay 0.2
                go back t
                delay 0.2
                if URL of t is not "about:blank#created" then error "Back destination mismatch"
                go forward t
                delay 0.2
                if URL of t is not "about:blank#changed" then error "Forward destination mismatch"
                stop t
                return id of t
                """)
            _ = try await script("javascript-disabled", """
                try
                    execute (last tab of window 1) javascript "'synthetic-text'"
                    error "JavaScript unexpectedly allowed" number 999
                on error messageText number errorNumber
                    if errorNumber is not -1743 then error messageText number errorNumber
                    if messageText does not contain "Allow JavaScript" then error "Unexpected refusal"
                end try
                return "refused"
                """)
            try await settings.setAllowJavaScriptFromAppleEvents(true)
            do {
                // Allow the real renderer to commit the same-document navigation.
                try await Task.sleep(for: .milliseconds(300))
                let value = try await script("javascript-enabled", """
                    return execute (last tab of window 1) javascript "'synthetic-text'"
                    """)
                guard value == "synthetic-text" else { throw ProbeFailure(message: "Wrong JavaScript text: " + value) }
            } catch {
                try await settings.setAllowJavaScriptFromAppleEvents(false)
                throw error
            }
            try await settings.setAllowJavaScriptFromAppleEvents(false)
            _ = try await script("javascript-disabled-again", """
                try
                    execute (last tab of window 1) javascript "'synthetic-text'"
                    error "JavaScript unexpectedly allowed" number 999
                on error messageText number errorNumber
                    if errorNumber is not -1743 then error messageText number errorNumber
                end try
                return "refused"
                """)
            _ = try await script("close-spaces-focus", """
                set beforeClose to count tabs of window 1
                close (last tab of window 1)
                if (count tabs of window 1) is not beforeClose - 1 then error "Close failed"
                set spaceNames to title of spaces of window 1
                if (count spaceNames) < 1 then error "No Spaces"
                focus (space 1 of window 1)
                if id of active space of window 1 is not id of space 1 of window 1 then error "Space focus failed"
                return count spaceNames
                """)
            _ = try await script("default-tab-active-set-window", """
                set defaultTab to make new tab with properties {URL:"about:blank#default"}
                if id of active tab of front window is not id of defaultTab then error "Default selection failed"
                set URL of active tab of front window to "about:blank#active-set"
                delay 0.2
                if URL of defaultTab is not "about:blank#active-set" then error "Active URL did not change"
                close defaultTab
                set initialWindows to count windows
                set createdWindow to make new window
                if (count windows) is not initialWindows + 1 then error "Window creation failed"
                close createdWindow
                return "default-and-window-ok"
                """)
            _ = try await script("make-private", """
                set privateWindow to make new window with properties {mode:"incognito"}
                set privateTab to make new tab at end of tabs of privateWindow with properties {URL:"about:blank#private"}
                return id of privateWindow
                """)
            _ = try await script("private-unfocused", """
                set privateWindow to first window whose incognito is true
                set normalWindow to first window whose incognito is false
                focus normalWindow
                if URL of last tab of privateWindow is not "" then error "Private URL leaked without focus"
                if title of last tab of privateWindow is not "" then error "Private title leaked without focus"
                return "redacted"
                """)
            _ = try await script("private-focused", """
                set privateWindow to first window whose incognito is true
                focus privateWindow
                if URL of last tab of privateWindow is not "about:blank#private" then error "Focused private URL unavailable"
                return "explicit-focused"
                """)
            _ = try await script("private-global-redaction", """
                set globalURLs to URL of tabs
                if globalURLs contains "about:blank#private" then error "Global inventory leaked private URL"
                close (first window whose incognito is true)
                return "redacted"
                """)
            stage = "jxa-self-inventory"; publish("running")
            let jxa = await execute("""
                const app = Application("\(bundleID)");
                const windows = app.windows();
                if (!windows.length) throw Error("No windows");
                const titles = windows[0].tabs.title();
                const urls = windows[0].tabs.url();
                if (titles.length !== urls.length) throw Error("Inventory mismatch");
                "self-jxa-ok";
                """, javaScript: true)
            guard jxa.code == 0, jxa.text == "self-jxa-ok" else { throw ProbeFailure(message: "\(jxa.code): \(jxa.text)") }
            checks.append(stage)
            publish("passed")
            return ["passed": true, "checks": checks, "javaScriptSettingOff": !settings.document.allowJavaScriptFromAppleEvents]
        } catch {
            if let settings = app.environment?.settings { try? await settings.setAllowJavaScriptFromAppleEvents(false) }
            publish("failed", String(describing: error))
            return ["passed": false, "checks": checks, "stage": stage, "error": String(describing: error)]
        }
    }

    private struct ProbeFailure: Error { let message: String }
    private struct ScriptResult: Sendable { let code: Int; let text: String }

    // The main actor must remain free to receive the event and resume suspended Cocoa commands.
    // Each OSA object is created, compiled, executed and destroyed on a single worker thread.
    private static func execute(_ source: String, javaScript: Bool = false) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                autoreleasepool {
                    var error: NSDictionary?
                    let result: NSAppleEventDescriptor?
                    if javaScript {
                        guard let language = OSALanguage(forName: "JavaScript") else {
                            continuation.resume(returning: ScriptResult(code: -1, text: "JXA unavailable"))
                            return
                        }
                        let script = OSAScript(source: source, language: language)
                        if script.compileAndReturnError(&error) { result = script.executeAndReturnError(&error) }
                        else { result = nil }
                    } else {
                        let script = NSAppleScript(source: source)
                        if script?.compileAndReturnError(&error) == true { result = script?.executeAndReturnError(&error) }
                        else { result = nil }
                    }
                    continuation.resume(returning: ScriptResult(
                        code: (error?["NSAppleScriptErrorNumber"] as? Int) ?? (error?["OSAScriptErrorNumber"] as? Int) ?? (error == nil ? 0 : -1),
                        text: error.map { String(describing: $0) } ?? result?.stringValue ?? result?.description ?? ""))
                }
            }
        }
    }
}
