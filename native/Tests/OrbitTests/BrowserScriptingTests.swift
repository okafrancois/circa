import AppKit
import BrowserCore
import BrowserEngine
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
        let nativeReply = try #require(try BrowserScriptingController.replyValue(read([firstTitle, firstURL]), returnType: "any") as? NSAppleEventDescriptor)
        #expect(nativeReply.numberOfItems == 2)
        #expect(nativeReply.atIndex(1)?.stringValue == "First")
        #expect(nativeReply.atIndex(2)?.stringValue == "about:blank")
        let activeReply = try #require(try BrowserScriptingController.replyValue(space.appleScriptTabs[0], returnType: "any") as? NSAppleEventDescriptor)
        #expect((NSScriptObjectSpecifier(descriptor: activeReply)?.objectsByEvaluatingSpecifier as? CircaScriptTab)?.id == "first")
        #expect(try BrowserScriptingController.replyValue([], returnType: "any") is NSAppleEventDescriptor)
        #expect(try BrowserScriptingController.replyValue(true, returnType: "any") is NSAppleEventDescriptor)
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

    @Test("Headless Cocoa creation, reply round trips and commands mutate synthetic sessions")
    func cocoaSessionCommands() async throws {
        try loadDictionary()
        _ = NSApplication.shared
        let app = OrbitApplication()
        let previous = NSApp.delegate
        let context = NSScriptExecutionContext.shared()
        let previousTop = context.topLevelObject
        NSApp.delegate = app; context.topLevelObject = NSApp
        let fixture = HeadlessScriptingSession(scripting: app.scripting)
        defer {
            fixture.close()
            NSApp.delegate = previous; context.topLevelObject = previousTop
        }
        app.scripting.refresh = { await fixture.refresh() }
        app.scripting.createWindow = { try await fixture.makeWindow($0) }
        _ = try await fixture.makeWindow("normal")

        func roundTrip(_ specifier: NSScriptObjectSpecifier) throws -> NSScriptObjectSpecifier {
            let descriptor = try #require(specifier.descriptor)
            #expect(descriptor.descriptorType == eventCode("obj "))
            return try #require(NSScriptObjectSpecifier(descriptor: descriptor))
        }
        func make(_ code: String, location: NSPositionalSpecifier? = nil,
                  properties: [String: Any] = [:]) async throws -> NSScriptObjectSpecifier {
            let command = CircaMakeScriptCommand(commandDescription: try commandDescription("core", "crel"))
            command.arguments = ["ObjectClass": eventCode(code), "KeyDictionary": properties]
            if let location { command.arguments?["Location"] = location }
            let reference = try await command.makeValue(app.scripting)
            #expect(context.topLevelObject as? NSApplication === NSApp)
            #expect(reference.objectsByEvaluatingSpecifier != nil, "Returned reference unavailable: \(reference), windows: \(fixture.scripting.windows.map(\.id)), error: \(reference.evaluationErrorNumber)")
            return try roundTrip(reference)
        }
        let front = NSIndexSpecifier(containerClassDescription: try #require(NSApp.classDescription as? NSScriptClassDescription),
                                     containerSpecifier: nil, key: "appleScriptWindows", index: 0)
        // This is the exact collection insertion form produced by "end of tabs of front window".
        let tabs = NSPropertySpecifier(containerClassDescription: try #require(fixture.scripting.windows[0].classDescription as? NSScriptClassDescription),
                                       containerSpecifier: front, key: "appleScriptTabs")
        func countTabs(_ expected: Int) throws {
            for (receiver, arguments) in [(front as Any, ["ObjectClass": eventCode("tAbB")]),
                                           (tabs as Any, [:]),
                                           (try #require(front.descriptor) as Any, ["ObjectClass": eventCode("tAbB")]),
                                           (try #require(tabs.descriptor) as Any, [:])] {
                let count = CircaCountScriptCommand(commandDescription: try commandDescription("core", "cnte"))
                count.directParameter = receiver; count.arguments = arguments
                #expect(count.countValue() as? Int == expected)
            }
        }
        try countTabs(0)
        let created = try await make("tAbB", location: NSPositionalSpecifier(position: .end, objectSpecifier: tabs),
                                     properties: ["URL": "about:blank#created"])
        let tab = try #require(created.objectsByEvaluatingSpecifier as? CircaScriptTab)
        #expect(tab.URL == "about:blank#created")
        #expect(fixture.sessions[0].session.organization?.selectedTab?.id.rawValue.uuidString == tab.id)
        #expect(fixture.scripting.windows[0].appleScriptTabs.count == 1)
        try countTabs(1)
        let active = NSPropertySpecifier(containerClassDescription: try #require(fixture.scripting.windows[0].classDescription as? NSScriptClassDescription),
                                         containerSpecifier: front, key: "activeTab")
        let get = CircaGetScriptCommand(commandDescription: try commandDescription("core", "getd"))
        get.directParameter = try #require(active.descriptor)
        let activeReply = try #require(BrowserScriptingController.replyValue(get.readValue()) as? NSScriptObjectSpecifier)
        #expect((try roundTrip(activeReply).objectsByEvaluatingSpecifier as? CircaScriptTab)?.id == tab.id)
        let set = CircaSetScriptCommand(commandDescription: try commandDescription("core", "setd"))
        set.directParameter = try #require(NSPropertySpecifier(containerClassDescription: try #require(tab.classDescription as? NSScriptClassDescription),
                                                  containerSpecifier: active, key: "URL").descriptor)
        set.arguments = ["Value": "about:blank#changed"]
        _ = try await set.setValue()
        #expect(fixture.sessions[0].session.selectedSurface?.currentURL?.absoluteString == "about:blank#changed")

        func action(_ suite: String, _ code: String, target: NSScriptObjectSpecifier = created,
                    arguments: [String: Any] = [:]) async throws -> Any? {
            await app.scripting.refresh()
            let command = CircaActionScriptCommand(commandDescription: try commandDescription(suite, code))
            command.directParameter = try #require(target.descriptor); command.arguments = arguments
            return try await command.actionValue(app.scripting)
        }
        _ = try await action("CrSe", "lect")
        _ = try await action("CrSu", "Rlod")
        _ = try await action("CrSu", "Back")
        #expect(fixture.sessions[0].session.selectedSurface?.currentURL?.absoluteString == "about:blank#created")
        _ = try await action("CrSu", "Fwd ")
        #expect(fixture.sessions[0].session.selectedSurface?.currentURL?.absoluteString == "about:blank#changed")
        _ = try await action("CrSu", "stop")
        await #expect(throws: BrowserScriptError.javaScriptDisabled) {
            _ = try await action("CrSu", "ExJa", arguments: ["javascript": "'synthetic-text'"])
        }
        #expect(fixture.executions == 0)
        app.scripting.allowsJavaScript = { true }
        #expect(try await action("CrSu", "ExJa", arguments: ["javascript": "'synthetic-text'"]) as? String == "synthetic-text")
        #expect(fixture.executions == 1)
        let space = try #require(app.scripting.windows[0].appleScriptSpaces.first?.objectSpecifier)
        _ = try await action("SpaF", "ocus", target: space)
        #expect(fixture.focused == fixture.sessions[0].id)
        _ = try await action("core", "clos")
        await app.scripting.refresh()
        #expect(!app.scripting.windows.flatMap(\.appleScriptTabs).contains { $0.id == tab.id })
        let defaultTab = try await make("tAbB", properties: ["URL": "about:blank#default"])
        #expect((defaultTab.objectsByEvaluatingSpecifier as? CircaScriptTab)?.URL == "about:blank#default")
        try countTabs(1)
        // Exercise the unmodified Cocoa command itself, not just the asynchronous adapter.
        let container = try #require(app.scripting.windows.first)
        try #require(container.responds(to: NSSelectorFromString("insertObject:inAppleScriptTabsAtIndex:")))
        let raw = NSCreateCommand(commandDescription: try commandDescription("core", "crel"))
        raw.arguments = ["ObjectClass": eventCode("tAbB"), "KeyDictionary": ["URL": "about:blank#cocoa"],
                         "Location": NSPositionalSpecifier(position: .end, objectSpecifier: tabs)]
        let rawReply = try #require(raw.performDefaultImplementation() as? NSScriptObjectSpecifier)
        let provisional = try #require(rawReply.objectsByEvaluatingSpecifier as? CircaScriptTab)
        #expect(container.appleScriptTabs.contains { $0 === provisional })
        let complete = try #require(app.scripting.creation)
        let materialized = try await complete()
        app.scripting.creation = nil
        #expect((materialized as? CircaScriptTab)?.URL == "about:blank#cocoa")
        try countTabs(2)
        #expect(try roundTrip(#require(materialized.objectSpecifier)).objectsByEvaluatingSpecifier is CircaScriptTab)
        let newWindow = try await make("WiND")
        #expect(newWindow.objectsByEvaluatingSpecifier is CircaScriptWindow)
        #expect(fixture.sessions.count == 2)
        let privateWindow = try await make("WiND", properties: ["mode": "incognito"])
        let privateTabs = NSPropertySpecifier(containerClassDescription: try #require((privateWindow.objectsByEvaluatingSpecifier as? CircaScriptWindow)?.classDescription as? NSScriptClassDescription),
                                              containerSpecifier: privateWindow, key: "appleScriptTabs")
        let privateTab = try await make("tAbB", location: NSPositionalSpecifier(position: .end, objectSpecifier: privateTabs),
                                        properties: ["URL": "about:blank#private"])
        let secret = try #require(privateTab.objectsByEvaluatingSpecifier as? CircaScriptTab)
        #expect(secret.URL.isEmpty && secret.title.isEmpty)
        let privateID = try #require(secret.window?.id)
        app.scripting.targetWindowID = privateID
        #expect(secret.URL == "about:blank#private")
        fixture.focused = nil
        #expect(secret.URL.isEmpty)
        await #expect(throws: BrowserScriptError.privateContent) {
            _ = try await action("CrSu", "ExJa", target: privateTab, arguments: ["javascript": "'synthetic-text'"])
        }
    }

    private func specifierError(_ specifier: NSScriptObjectSpecifier) -> Int { specifier.evaluationErrorNumber }

    @Test("Creation containers expose ordered Cocoa insertion and removal accessors")
    func creationAccessors() throws {
        try loadDictionary()
        _ = NSApplication.shared
        let scripting = BrowserScriptingController()
        let window = CircaScriptWindow(id: "window", mode: "normal", scripting: scripting,
                                       isFocused: { false }, title: { "Window" })
        let space = CircaScriptSpace(id: "space", title: "Space", window: window)
        for (container, key) in [(NSApp as NSObject, "AppleScriptWindows"), (NSApp as NSObject, "AppleScriptTabs"),
                                 (window, "AppleScriptTabs"), (space, "AppleScriptTabs")] {
            #expect(container.responds(to: NSSelectorFromString("insertObject:in\(key)AtIndex:")))
            #expect(container.responds(to: NSSelectorFromString("removeObjectFrom\(key)AtIndex:")))
        }
    }

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

/// Uses the production inventory/action adapter without allocating an NSWindow or sending events.
@MainActor
private final class HeadlessScriptingSession: BrowserEngineSurfaceDelegate {
    struct Entry {
        let id: String
        let mode: String
        let environment: BrowserEnvironment<SyntheticEngine>
        let session: BrowserWindowSession<SyntheticSurface>
    }
    let scripting: BrowserScriptingController
    var sessions: [Entry] = []
    var focused: String?
    var executions = 0
    init(scripting: BrowserScriptingController) { self.scripting = scripting }
    func makeWindow(_ mode: String) async throws -> CircaScriptWindow {
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        let session = BrowserWindowSession(store: environment.store, makeSurface: { profile, url in
            let surface = environment.engine.makeSurface(profileID: profile, delegate: self)
            surface.navigate(to: url)
            return surface
        })
        let id = UUID().uuidString
        sessions.insert(Entry(id: id, mode: mode, environment: environment, session: session), at: 0)
        focused = id
        await refresh()
        return scripting.windows[0]
    }
    func refresh() async {
        var windows: [CircaScriptWindow] = []
        for entry in sessions {
            let window = await scripting.capture(session: entry.session, windowID: entry.id, mode: entry.mode,
                environment: entry.environment, isFocused: { self.focused == entry.id }, title: { "Synthetic window" },
                focus: { self.focused = entry.id }, close: { entry.session.close() }, isAvailable: { !entry.session.isClosed })
            // The synthetic renderer has no JS runtime; simulate its textual result at the engine boundary.
            for tab in window.appleScriptTabs {
                let action = tab.action
                tab.action = { request in
                    if case .javascript = request { self.executions += 1; return "synthetic-text" }
                    return try await action(request)
                }
            }
            windows.append(window)
        }
        scripting.windows = windows
    }
    func surfaceDidStartNavigation(_ surface: SyntheticSurface) {}
    func surfaceDidCommitNavigation(_ surface: SyntheticSurface) {}
    func surfaceDidFinishNavigation(_ surface: SyntheticSurface) {}
    func surfaceDidFailNavigation(_ surface: SyntheticSurface) {}
    func surfaceDidRequestClose(_ surface: SyntheticSurface) {}
    func surface(_ surface: SyntheticSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.allow) }
    func surface(_ surface: SyntheticSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> SyntheticSurface) -> SyntheticSurface? { nil }
    func surface(_ surface: SyntheticSurface, didStartDownload download: any BrowserEngineDownload) {}
    func close() {
        scripting.refresh = {}; scripting.createWindow = { _ in throw BrowserScriptError.unavailable }
        scripting.windows = []
        for entry in sessions { entry.session.close(); entry.environment.autoArchive.scheduler.stop() }
    }
}
