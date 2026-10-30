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
        #expect(tab.space?.id == other.rawValue.uuidString)
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
        let firstURL = NSPropertySpecifier(containerClassDescription: tabDescription,
                                          containerSpecifier: space.appleScriptTabs[0].objectSpecifier, key: "URL")
        #expect(read([firstTitle, firstURL]) as? [String] == ["First", "about:blank"])
    }

    @Test("Every dictionary property and element evaluates through Cocoa KVC with the declared class")
    func dictionaryAccessors() throws {
        try loadDictionary()
        _ = NSApplication.shared
        let app = OrbitApplication()
        let previous = NSApp.delegate
        NSApp.delegate = app
        NSScriptExecutionContext.shared().topLevelObject = NSApp
        defer { withExtendedLifetime(app) {}; NSApp.delegate = previous }
        let window = CircaScriptWindow(id: "window", mode: "normal", scripting: app.scripting,
                                       isFocused: { false }, title: { "Window" })
        let space = CircaScriptSpace(id: "space", title: "Space", window: window)
        let tab = CircaScriptTab(id: "tab", title: "Page", url: "about:blank", location: "unpinned", loading: false, space: space)
        app.scripting.windows = [window]; window.appleScriptSpaces = [space]; space.appleScriptTabs = [tab]
        window.selectedTabID = { "tab" }; window.selectedSpaceID = { "space" }
        let cases: [(NSObject, [String], [(String, String)])] = [
            (NSApp, ["name", "isActive", "version"], [("appleScriptWindows", "WiND"), ("appleScriptSpaces", "sPaC"), ("appleScriptTabs", "tAbB")]),
            (window, ["id", "title", "mode", "incognito", "activeTab", "activeSpace"], [("appleScriptSpaces", "sPaC"), ("appleScriptTabs", "tAbB")]),
            (space, ["id", "title"], [("appleScriptTabs", "tAbB")]),
            (tab, ["id", "title", "URL", "loading", "location"], [])
        ]
        for (object, keys, elements) in cases {
            let description = try #require(object.classDescription as? NSScriptClassDescription)
            for key in keys {
                let specifier = NSPropertySpecifier(containerClassDescription: description, containerSpecifier: nil, key: key)
                #expect(specifier.objectsByEvaluating(withContainers: object) != nil, "Missing KVC property: \(key)")
            }
            for (key, code) in elements {
                #expect((description.perform(NSSelectorFromString("classDescriptionForKey:"), with: key)?.takeUnretainedValue() as? NSScriptClassDescription)?.appleEventCode == eventCode(code))
                let specifier = NSPropertySpecifier(containerClassDescription: description, containerSpecifier: nil, key: key)
                let values = try #require(specifier.objectsByEvaluating(withContainers: object) as? [NSObject])
                #expect(!values.isEmpty)
                for value in values { #expect((value.classDescription as? NSScriptClassDescription)?.appleEventCode == eventCode(code)) }
            }
        }
        window.selectedTabID = { nil }; window.selectedSpaceID = { "missing" }
        #expect(window.activeTab == nil && window.activeSpace == nil)
    }

    @Test("Nested window, Space and tab specifiers resolve by index, name and id and survive inventory replacement")
    func nestedSpecifiers() throws {
        try loadDictionary()
        _ = NSApplication.shared
        let app = OrbitApplication()
        let previous = NSApp.delegate
        NSApp.delegate = app
        NSScriptExecutionContext.shared().topLevelObject = NSApp
        defer { withExtendedLifetime(app) {}; NSApp.delegate = previous }
        let window = CircaScriptWindow(id: "window", mode: "normal", scripting: app.scripting, isFocused: { false }, title: { "Window" })
        let space = CircaScriptSpace(id: "space", title: "Space", window: window)
        let tab = CircaScriptTab(id: "tab", title: "Page", url: "about:blank", location: "unpinned", loading: false, space: space)
        app.scripting.windows = [window]; window.appleScriptSpaces = [space]; space.appleScriptTabs = [tab]
        for (container, key, expected, parent) in [
            (NSApp as NSObject, "appleScriptWindows", window as NSObject, nil as NSScriptObjectSpecifier?),
            (window, "appleScriptSpaces", space, window.objectSpecifier),
            (window, "appleScriptTabs", tab, window.objectSpecifier),
            (space, "appleScriptTabs", tab, space.objectSpecifier),
            (NSApp as NSObject, "appleScriptSpaces", space, nil),
            (NSApp as NSObject, "appleScriptTabs", tab, nil)
        ] {
            let description = try #require(container.classDescription as? NSScriptClassDescription)
            let id = try #require(expected.value(forKey: "id") as? String)
            let name = try #require(expected.value(forKey: "name") as? String)
            let specs: [NSScriptObjectSpecifier] = [
                NSIndexSpecifier(containerClassDescription: description, containerSpecifier: parent, key: key, index: 0),
                NSNameSpecifier(containerClassDescription: description, containerSpecifier: parent, key: key, name: name),
                NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: parent, key: key, uniqueID: id)
            ]
            for spec in specs {
                #expect(NSApp.delegate === app)
                #expect(spec.objectsByEvaluatingSpecifier as? NSObject === expected, "\(key) \(type(of: spec)) error \(specifierError(spec))")
            }

        }
        let stable = try #require(tab.objectSpecifier)
        let replacement = CircaScriptTab(id: "tab", title: "Changed", url: "about:blank#changed", location: "unpinned", loading: false, space: space)
        space.appleScriptTabs = [replacement]
        #expect(stable.objectsByEvaluatingSpecifier as? CircaScriptTab === replacement)
    }

    @Test("Raw count and get commands handle collection and missing values after suspension")
    func rawReadCommands() throws {
        try loadDictionary()
        _ = NSApplication.shared
        let app = OrbitApplication()
        let previous = NSApp.delegate
        NSApp.delegate = app
        NSScriptExecutionContext.shared().topLevelObject = NSApp
        defer { withExtendedLifetime(app) {}; NSApp.delegate = previous }
        let windows = NSPropertySpecifier(containerClassDescription: NSApp.classDescription as! NSScriptClassDescription,
                                          containerSpecifier: nil, key: "appleScriptWindows")
        let count = CircaCountScriptCommand(commandDescription: try commandDescription("core", "cnte"))
        count.directParameter = windows
        #expect(count.countValue() as? Int == 0)
        let window = CircaScriptWindow(id: "window", mode: "normal", scripting: app.scripting, isFocused: { false }, title: { "Window" })
        app.scripting.windows = [window]
        let populated = CircaCountScriptCommand(commandDescription: try commandDescription("core", "cnte"))
        populated.directParameter = NSPropertySpecifier(containerClassDescription: NSApp.classDescription as! NSScriptClassDescription,
                                                        containerSpecifier: nil, key: "appleScriptWindows")
        #expect(populated.countValue() as? Int == 1)
        let get = CircaGetScriptCommand(commandDescription: try commandDescription("core", "getd"))
        #expect(get.readValue() == nil)
        get.directParameter = window.objectSpecifier
        #expect(get.readValue() as? CircaScriptWindow === window)
    }

    @Test("Set evaluates a tab URL property and rejects missing, malformed and wrong-class receivers")
    func setCommand() async throws {
        try loadDictionary()
        _ = NSApplication.shared
        let app = OrbitApplication()
        let previous = NSApp.delegate
        NSApp.delegate = app
        NSScriptExecutionContext.shared().topLevelObject = NSApp
        defer { withExtendedLifetime(app) {}; NSApp.delegate = previous }
        let window = CircaScriptWindow(id: "window", mode: "normal", scripting: app.scripting, isFocused: { false }, title: { "Window" })
        let space = CircaScriptSpace(id: "space", title: "Space", window: window)
        let tab = CircaScriptTab(id: "tab", title: "Page", url: "about:blank", location: "unpinned", loading: false, space: space)
        app.scripting.windows = [window]; window.appleScriptSpaces = [space]; space.appleScriptTabs = [tab]
        var navigated: String?
        tab.action = { if case .navigate(let url) = $0 { navigated = url.absoluteString }; return nil }
        let command = CircaSetScriptCommand(commandDescription: try commandDescription("core", "setd"))
        command.directParameter = NSPropertySpecifier(containerClassDescription: tab.classDescription as! NSScriptClassDescription,
                                                      containerSpecifier: tab.objectSpecifier, key: "URL")
        command.arguments = ["Value": "https://automation.test/changed"]
        _ = try await command.setValue()
        #expect(navigated == "https://automation.test/changed")
        command.arguments = ["Value": "relative"]
        await #expect(throws: BrowserScriptError.invalidURL) { _ = try await command.setValue() }
        command.directParameter = window.objectSpecifier
        await #expect(throws: BrowserScriptError.invalidURL) { _ = try await command.setValue() }
        command.directParameter = nil
        await #expect(throws: BrowserScriptError.invalidURL) { _ = try await command.setValue() }
    }

    @Test("Action commands evaluate tab and Space receivers, dispatch every verb and reject missing targets")
    func actionCommands() async throws {
        try loadDictionary()
        _ = NSApplication.shared
        let app = OrbitApplication()
        let previous = NSApp.delegate
        NSApp.delegate = app
        NSScriptExecutionContext.shared().topLevelObject = NSApp
        defer { withExtendedLifetime(app) {}; NSApp.delegate = previous }
        let window = CircaScriptWindow(id: "window", mode: "normal", scripting: app.scripting, isFocused: { false }, title: { "Window" })
        let space = CircaScriptSpace(id: "space", title: "Space", window: window)
        let tab = CircaScriptTab(id: "tab", title: "Page", url: "about:blank", location: "unpinned", loading: false, space: space)
        app.scripting.windows = [window]; window.appleScriptSpaces = [space]; space.appleScriptTabs = [tab]
        var actions: [String] = []
        tab.action = { action in
            switch action {
            case .select: actions.append("select")
            case .close: actions.append("close")
            case .reload: actions.append("reload")
            case .back: actions.append("back")
            case .forward: actions.append("forward")
            case .stop: actions.append("stop")
            case .javascript(let text): return text
            case .navigate: break
            }
            return nil
        }
        for (suite, code) in [("CrSe", "lect"), ("core", "clos"), ("CrSu", "Rlod"), ("CrSu", "Back"), ("CrSu", "Fwd "), ("CrSu", "stop")] {
            let command = CircaActionScriptCommand(commandDescription: try commandDescription(suite, code))
            command.directParameter = tab.objectSpecifier
            _ = try await command.actionValue(app.scripting)
        }
        #expect(actions == ["select", "close", "reload", "back", "forward", "stop"])
        let execute = CircaActionScriptCommand(commandDescription: try commandDescription("CrSu", "ExJa"))
        execute.directParameter = tab.objectSpecifier; execute.arguments = ["javascript": "text"]
        await #expect(throws: BrowserScriptError.javaScriptDisabled) { _ = try await execute.actionValue(app.scripting) }
        app.scripting.allowsJavaScript = { true }
        #expect(try await execute.actionValue(app.scripting) as? String == "text")
        let focus = CircaActionScriptCommand(commandDescription: try commandDescription("SpaF", "ocus"))
        var focused = false
        space.focus = { focused = true }
        focus.directParameter = space.objectSpecifier
        _ = try await focus.actionValue(app.scripting)
        #expect(focused)
        focus.directParameter = nil
        await #expect(throws: BrowserScriptError.unavailable) { _ = try await focus.actionValue(app.scripting) }
    }

    @Test("Make resolves positional Space insertion, property keys and returned object specifiers")
    func makeCommand() async throws {
        try loadDictionary()
        _ = NSApplication.shared
        let app = OrbitApplication()
        let previous = NSApp.delegate
        NSApp.delegate = app
        NSScriptExecutionContext.shared().topLevelObject = NSApp
        defer { withExtendedLifetime(app) {}; NSApp.delegate = previous }
        let window = CircaScriptWindow(id: "window", mode: "normal", scripting: app.scripting, isFocused: { false }, title: { "Window" })
        let space = CircaScriptSpace(id: "space", title: "Space", window: window)
        app.scripting.windows = [window]; window.appleScriptSpaces = [space]
        app.scripting.refresh = {}
        window.makeTab = { url, spaceID in
            #expect(url.absoluteString == "about:blank#created")
            #expect(spaceID == "space")
            space.appleScriptTabs.append(CircaScriptTab(id: "created", title: "Created", url: url.absoluteString,
                                                       location: "unpinned", loading: false, space: space))
            return "created"
        }
        let command = CircaMakeScriptCommand(commandDescription: try commandDescription("core", "crel"))
        let position = NSPositionalSpecifier(position: .end, objectSpecifier: try #require(space.objectSpecifier))
        command.arguments = ["ObjectClass": eventCode("tAbB"), "Location": position,
                             "KeyDictionary": ["URL": "about:blank#created"]]
        let tabSpecifier = try await command.makeValue(app.scripting)
        #expect((tabSpecifier.objectsByEvaluatingSpecifier as? CircaScriptTab)?.id == "created")
        #expect(command.commandDescription.returnType == "NSScriptObjectSpecifier")
        #expect(tabSpecifier.descriptor?.descriptorType == eventCode("obj "))
        app.scripting.createWindow = { mode in #expect(mode == "incognito"); return window }
        command.arguments = ["ObjectClass": eventCode("WiND"), "KeyDictionary": ["mode": "incognito"]]
        let windowSpecifier = try await command.makeValue(app.scripting)
        #expect(windowSpecifier.objectsByEvaluatingSpecifier as? CircaScriptWindow === window)
        #expect(windowSpecifier.descriptor?.descriptorType == eventCode("obj "))
        let replies = try #require(BrowserScriptingController.replyValue([window, space, space.appleScriptTabs[0]]) as? [NSScriptObjectSpecifier])
        #expect(replies.count == 3)
        for reply in replies { #expect(reply.descriptor?.descriptorType == eventCode("obj ")) }
    }

    @Test("Retained scripting children become unavailable when their inventory parents disappear")
    func expiredInventory() throws {
        try loadDictionary()
        _ = NSApplication.shared
        var scripting: BrowserScriptingController? = BrowserScriptingController()
        var window: CircaScriptWindow? = CircaScriptWindow(id: "window", mode: "incognito", scripting: scripting!,
                                                          isFocused: { true }, title: { "Private" })
        var space: CircaScriptSpace? = CircaScriptSpace(id: "space", title: "Space", window: window!)
        let tab = CircaScriptTab(id: "tab", title: "Private", url: "about:blank#private", location: "unpinned", loading: false, space: space!)
        window?.appleScriptSpaces = [space!]; space?.appleScriptTabs = [tab]
        scripting?.targetWindowID = "window"
        #expect(tab.title == "Private")
        scripting = nil
        #expect(window?.title == "")
        window = nil
        #expect(space?.objectSpecifier == nil)
        #expect(tab.URL.isEmpty)
        space = nil
        #expect(tab.objectSpecifier == nil && tab.title.isEmpty && tab.URL.isEmpty)
    }

    @Test("Root specifiers use the registered application description for an unregistered native host subclass")
    func nativeHostClassDescription() throws {
        try loadDictionary()
        #expect(NSClassDescription(for: ScriptHostFixtureApplication.self) == nil)
        let description = try #require(BrowserScriptingController.applicationClassDescription(for: ScriptHostFixtureApplication.self))
        #expect(description.appleEventCode == eventCode("capp"))
        #expect(description.implementationClassName == "NSApplication")
        let reference = NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: nil,
                                            key: "appleScriptWindows", uniqueID: "synthetic-window")
        #expect(reference.descriptor?.descriptorType == eventCode("obj "))
    }

    private func specifierError(_ specifier: NSScriptObjectSpecifier) -> Int { specifier.evaluationErrorNumber }

    private func eventCode(_ text: String) -> FourCharCode { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    private func commandDescription(_ suite: String, _ command: String) throws -> NSScriptCommandDescription {
        try #require(NSScriptSuiteRegistry.shared().commandDescription(withAppleEventClass: eventCode(suite), andAppleEventCode: eventCode(command)))
    }

    private static var dictionaryLoaded = false

    private func loadDictionary() throws {
        guard !Self.dictionaryLoaded else { return }
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
        Self.dictionaryLoaded = true
    }
}
}

private final class ScriptHostFixtureApplication: NSApplication {}
