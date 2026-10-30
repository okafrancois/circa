import AppKit
import BrowserCore
import BrowserShell
import BrowserEngineConformance
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Browser scripting", .serialized)
@MainActor
struct BrowserScriptingTests {
    @Test("Inventory maps active and inactive Spaces, stable tab identities and sidebar locations")
    func inventory() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); owner.window?.close() }
        let scripting = BrowserScriptingController()
        let firstSpace = try #require(owner.session.snapshot?.activeSpaceID)
        let original = try #require(owner.session.organization?.selectedTab?.id)
        owner.session.pinTabs([original])
        await owner.session.waitForPendingCommands()
        let profile = try #require(owner.session.activeProfileID)
        let other = try await environment.store.createSpace(name: "Automation", profileID: profile)
        owner.session.activateSpace(other)
        owner.session.openTab(url: URL(string: "https://automation.test/second")!)
        await owner.session.waitForPendingCommands()
        let window = await scripting.capture(owner, environment: environment)
        #expect(window.mode == "normal")
        #expect(window.appleScriptSpaces.count == 2)
        #expect(window.activeSpace?.id == other.rawValue.uuidString)
        #expect(window.appleScriptSpaces.first { $0.id == firstSpace.rawValue.uuidString }?.appleScriptTabs.first?.location == "pinned")
        #expect(window.activeTab?.URL == "https://automation.test/second")
        #expect(window.appleScriptTabs.contains { $0.id == original.rawValue.uuidString })
    }

    @Test("Creating, navigating and closing a tab route through the existing session")
    func mutations() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); owner.window?.close() }
        let scripting = BrowserScriptingController()
        var window = await scripting.capture(owner, environment: environment)
        let other = try await environment.store.createSpace(name: "Destination", profileID: try #require(owner.session.activeProfileID))
        let id = try await window.makeTab(URL(string: "https://automation.test/new")!, other.rawValue.uuidString)
        window = await scripting.capture(owner, environment: environment)
        let tab = try #require(window.appleScriptTabs.first { $0.id == id })
        #expect(tab.space.id == other.rawValue.uuidString)
        _ = try await tab.action(.navigate(URL(string: "https://automation.test/changed")!))
        #expect(owner.session.selectedSurface?.currentURL?.absoluteString == "https://automation.test/changed")
        _ = try await tab.action(.close)
        let after = await scripting.capture(owner, environment: environment)
        #expect(!after.appleScriptTabs.contains { $0.id == id })
    }

    @Test("JavaScript defaults off, persists only as a device setting and routes only when enabled")
    func javaScriptGate() async throws {
        let settings = try BrowserSettingsStore()
        #expect(await settings.snapshot().allowJavaScriptFromAppleEvents == false)
        try await settings.setAllowJavaScriptFromAppleEvents(true)
        let encoded = try JSONEncoder().encode(await settings.snapshot())
        #expect(try JSONDecoder().decode(BrowserSettingsDocument.self, from: encoded).allowJavaScriptFromAppleEvents)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "allowJavaScriptFromAppleEvents")
        #expect(try JSONDecoder().decode(BrowserSettingsDocument.self, from: JSONSerialization.data(withJSONObject: legacy)).allowJavaScriptFromAppleEvents == false)
        let scripting = BrowserScriptingController()
        let window = CircaScriptWindow(id: "window", mode: "normal", scripting: scripting, isFocused: { false }, title: { "Window" })
        let space = CircaScriptSpace(id: "space", title: "Space", window: window)
        let tab = CircaScriptTab(id: "tab", title: "Page", url: "https://automation.test", location: "unpinned", loading: false, space: space)
        var received: [String] = []
        tab.action = { action in if case .javascript(let script) = action { received.append(script); return "2" }; return nil }
        await #expect(throws: BrowserScriptError.javaScriptDisabled) { try await scripting.execute("1+1", in: tab) }
        #expect(received.isEmpty)
        #expect(throws: BrowserScriptError.javaScriptDisabled) { try scripting.validateNavigation(URL(string: "javascript:1+1")!) }
        scripting.allowsJavaScript = { true }
        #expect(try await scripting.execute("1+1", in: tab) == "2")
        #expect(received == ["1+1"])
    }

    @Test("Private titles, URLs and JavaScript require both an explicit window target and focus")
    func privateRedaction() async throws {
        let scripting = BrowserScriptingController()
        var focused = false
        let window = CircaScriptWindow(id: "private", mode: "incognito", scripting: scripting, isFocused: { focused }, title: { "Private page" })
        let space = CircaScriptSpace(id: "space", title: "Space", window: window)
        let tab = CircaScriptTab(id: "tab", title: "Private page", url: "https://private.test", location: "unpinned", loading: false, space: space)
        scripting.allowsJavaScript = { true }
        for (target, focus) in [(nil, false), (nil, true), ("other", true), ("private", false)] as [(String?, Bool)] {
            scripting.targetWindowID = target; focused = focus
            #expect(tab.title.isEmpty && tab.URL.isEmpty && window.title.isEmpty)
            await #expect(throws: BrowserScriptError.privateContent) { try await scripting.execute("1", in: tab) }
        }
        scripting.targetWindowID = "private"; focused = true
        #expect(tab.title == "Private page" && tab.URL == "https://private.test")
    }

    @Test("Cocoa specifiers resolve tabs by id, index and title")
    func specifiers() throws {
        _ = NSApplication.shared
        try loadDictionary()
        let description = try #require(NSScriptSuiteRegistry.shared().classDescription(withAppleEventCode: "sPaC".utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }))
        let scripting = BrowserScriptingController()
        let window = CircaScriptWindow(id: "window", mode: "normal", scripting: scripting, isFocused: { false }, title: { "Window" })
        let space = CircaScriptSpace(id: "space", title: "Space", window: window)
        let tab = CircaScriptTab(id: "stable", title: "Page", url: "about:blank", location: "unpinned", loading: false, space: space)
        space.appleScriptTabs = [tab]
        let specs: [NSScriptObjectSpecifier] = [
            NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: nil, key: "appleScriptTabs", uniqueID: "stable"),
            NSIndexSpecifier(containerClassDescription: description, containerSpecifier: nil, key: "appleScriptTabs", index: 0),
            NSNameSpecifier(containerClassDescription: description, containerSpecifier: nil, key: "appleScriptTabs", name: "Page")
        ]
        for spec in specs { #expect((spec.objectsByEvaluating(withContainers: space) as? CircaScriptTab)?.id == "stable") }
    }

    @Test("Suspended get reads raw scalar and empty or populated list values without packaging a second reply")
    func getValues() throws {
        _ = NSApplication.shared
        try loadDictionary()
        let application = OrbitApplication()
        let previousDelegate = NSApp.delegate
        NSApp.delegate = application
        defer { NSApp.delegate = previousDelegate }
        let scripting = application.scripting
        let window = CircaScriptWindow(id: "get-window", mode: "normal", scripting: scripting,
                                       isFocused: { false }, title: { "Window" })
        scripting.windows = [window]
        let space = CircaScriptSpace(id: "get-space", title: "Space", window: window)
        window.appleScriptSpaces = [space]
        let registry = NSScriptSuiteRegistry.shared()
        func code(_ text: String) -> FourCharCode { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
        let description = try #require(registry.commandDescription(withAppleEventClass: code("core"), andAppleEventCode: code("getd")))
        let tabs = NSPropertySpecifier(containerClassDescription: window.classDescription as! NSScriptClassDescription,
                                      containerSpecifier: window.objectSpecifier, key: "appleScriptTabs")
        let tabDescription = try #require(registry.classDescription(withAppleEventCode: code("tAbB")))
        let titles = NSPropertySpecifier(containerClassDescription: tabDescription, containerSpecifier: tabs, key: "title")
        func read(_ value: Any) -> Any? {
            let command = CircaGetScriptCommand(commandDescription: description)
            command.directParameter = value
            return command.readValue()
        }
        #expect((read(titles) as? [String]) == [])
        for (id, title) in [("first", "First"), ("second", "Second")] {
            space.appleScriptTabs.append(CircaScriptTab(id: id, title: title, url: "about:blank",
                location: "unpinned", loading: false, space: space))
        }
        #expect((read(titles) as? [String]) == ["First", "Second"])
        let firstTitle = NSPropertySpecifier(containerClassDescription: tabDescription,
                                            containerSpecifier: space.appleScriptTabs[0].objectSpecifier, key: "title")
        #expect(read(firstTitle) as? String == "First")
        #expect(read("literal") as? String == "literal")
    }

    private func loadDictionary() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("CircaScripting-" + UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let resources = temporary.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: root.appendingPathComponent("Scripting/Circa.sdef"), to: resources.appendingPathComponent("Circa.sdef"))
        let info: [String: Any] = ["CFBundleIdentifier": "lab.orbit.scripting.dictionary", "NSAppleScriptEnabled": true, "OSAScriptingDefinition": "Circa.sdef"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: temporary.appendingPathComponent("Contents/Info.plist"))
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/sdp")
        compile.arguments = ["-fst", "-o", resources.path, resources.appendingPathComponent("Circa.sdef").path]
        compile.standardOutput = FileHandle.nullDevice
        compile.standardError = FileHandle.nullDevice
        try compile.run(); compile.waitUntilExit()
        #expect(compile.terminationStatus == 0)
        NSScriptSuiteRegistry.shared().loadSuites(from: try #require(Bundle(url: temporary)))
    }
}
}
