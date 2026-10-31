import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import BrowserEngineConformance
import Carbon
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

    @Test("Enabled JavaScript reaches the engine's script evaluation service through the session adapter")
    func javaScriptEngineRoute() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); owner.window?.close() }
        let scripting = BrowserScriptingController()
        scripting.allowsJavaScript = { true }
        let window = await scripting.capture(owner, environment: environment)
        let tab = try #require(window.activeTab)
        // The engine exposes evaluation as a separate service, not through the engine object itself.
        #expect(try await tab.action(.javascript(BrowserEngineConformance.typedKeysScript)) == "")
        scripting.allowsJavaScript = { false }
        await #expect(throws: BrowserScriptError.javaScriptDisabled) {
            _ = try await tab.action(.javascript(BrowserEngineConformance.typedKeysScript))
        }
    }

    @Test("Setting a URL waits past a late commit of the previous navigation until the new document commits")
    func navigationCommit() async throws {
        let requested = URL(string: "about:blank#changed")!
        // The order a renderer reported after a new tab's first load was superseded by set URL.
        var reports: [URL?] = [URL(string: "about:blank"), URL(string: "about:blank#created"),
                               URL(string: "about:blank#created"), requested, requested]
        var reads = 0
        await BrowserScriptingController.awaitCommit(of: requested) {
            reads += 1
            return reports.isEmpty ? requested : reports.removeFirst()
        }
        #expect(reads == 4)
        let start = ContinuousClock.now
        await BrowserScriptingController.awaitCommit(of: requested, timeout: .milliseconds(60)) { URL(string: "about:blank#created") }
        #expect(ContinuousClock.now - start >= .milliseconds(60))
        for (committed, request) in [("https://example.test/", "https://EXAMPLE.test"), ("http://example.test/a", "http://example.test:80/a"),
                                     ("https://example.test/", "https://example.test:443")] {
            #expect(BrowserScriptingController.isSameDocument(URL(string: committed), URL(string: request)!))
        }
        #expect(!BrowserScriptingController.isSameDocument(URL(string: "about:blank#created"), requested))
        #expect(!BrowserScriptingController.isSameDocument(nil, requested))
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
        func command(_ key: String, of container: NSScriptObjectSpecifier?, value: Any) throws -> CircaSetScriptCommand {
            let command = CircaSetScriptCommand(commandDescription: try commandDescription("core", "setd"))
            if let container {
                command.receiversSpecifier = NSPropertySpecifier(containerClassDescription: try #require(container.keyClassDescription),
                                                                 containerSpecifier: container, key: key)
            }
            command.arguments = ["Value": value]
            return command
        }
        _ = try await command("URL", of: tab.objectSpecifier, value: "https://automation.test/changed").setValue()
        #expect(navigated == "https://automation.test/changed")
        // The sdef "any" value arrives as a raw descriptor in the shipped dictionary.
        _ = try await command("URL", of: tab.objectSpecifier, value: NSAppleEventDescriptor(string: "https://automation.test/raw")).setValue()
        #expect(navigated == "https://automation.test/raw")
        await #expect(throws: BrowserScriptError.invalidURL) { _ = try await command("URL", of: tab.objectSpecifier, value: "relative").setValue() }
        await #expect(throws: BrowserScriptError.unsupported) { _ = try await command("title", of: tab.objectSpecifier, value: "Renamed").setValue() }
        await #expect(throws: BrowserScriptError.unavailable) { _ = try await command("URL", of: window.objectSpecifier, value: "https://automation.test").setValue() }
        await #expect(throws: BrowserScriptError.unavailable) { _ = try await command("URL", of: nil, value: "https://automation.test").setValue() }
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
            command.receiversSpecifier = tab.objectSpecifier
            _ = try await command.actionValue(app.scripting)
        }
        #expect(actions == ["select", "close", "reload", "back", "forward", "stop"])
        let execute = CircaActionScriptCommand(commandDescription: try commandDescription("CrSu", "ExJa"))
        execute.receiversSpecifier = tab.objectSpecifier; execute.arguments = ["javascript": "text"]
        await #expect(throws: BrowserScriptError.javaScriptDisabled) { _ = try await execute.actionValue(app.scripting) }
        app.scripting.allowsJavaScript = { true }
        #expect(try await execute.actionValue(app.scripting) as? String == "text")
        let focus = CircaActionScriptCommand(commandDescription: try commandDescription("SpaF", "ocus"))
        var focused = false
        space.focus = { focused = true }
        focus.receiversSpecifier = space.objectSpecifier
        _ = try await focus.actionValue(app.scripting)
        #expect(focused)
        focus.receiversSpecifier = nil
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
        #expect(command.commandDescription.appleEventCodeForReturnType == typeObjectSpecifier)
        #expect(tabSpecifier.descriptor?.descriptorType == eventCode("obj "))
        app.scripting.createWindow = { mode in #expect(mode == "incognito"); return window }
        command.arguments = ["ObjectClass": eventCode("WiND"), "KeyDictionary": ["mode": "incognito"]]
        let windowSpecifier = try await command.makeValue(app.scripting)
        #expect(windowSpecifier.objectsByEvaluatingSpecifier as? CircaScriptWindow === window)
        #expect(windowSpecifier.descriptor?.descriptorType == eventCode("obj "))
        for object in [window, space, space.appleScriptTabs[0]] as [NSObject] {
            let reply = try #require(try BrowserScriptingController.replyValue(object, resultCode: typeObjectSpecifier) as? NSScriptObjectSpecifier)
            #expect(reply.descriptor?.descriptorType == eventCode("obj "))
        }
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


    @Test("Every dictionary class, property, element and command matches its Cocoa implementation")
    func dictionaryConsistency() throws {
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
        window.selectedTabID = { "tab" }; window.selectedSpaceID = { "space" }

        let dictionary = try XMLDocument(contentsOf: Self.dictionaryURL)
        let intrinsics = try ReplyContract.intrinsicValueTypes()
        let classes = try dictionary.nodes(forXPath: "//suite/class").compactMap { $0 as? XMLElement }
        var cocoaClasses: [String: AnyClass] = [:]
        for element in classes {
            let name = try #require(element.attribute(forName: "name")?.stringValue)
            #expect(name != "item", "Cocoa's intrinsic item class must stay the root of every dictionary class")
            let cocoa = try #require(Self.cocoaName(element, "class"))
            cocoaClasses[name] = cocoa == "NSApplication" ? NSApplication.self : NSClassFromString(cocoa)
            #expect(cocoaClasses[name] != nil, "Missing implementation class \(cocoa)")
        }
        let instances: [String: NSObject] = ["application": NSApp, "window": window, "space": space, "tab": tab]
        // Only these properties are writable: the URL through set, the mode through make.
        let writable: Set = ["tab.URL", "window.mode"]
        func check(_ value: Any?, isOf type: String, _ context: String) {
            switch type {
            case "text": #expect(value is String, "\(context) is not text")
            case "boolean": #expect((value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true, "\(context) is not boolean")
            case "integer": #expect(value is Int, "\(context) is not an integer")
            default:
                let expected = cocoaClasses[type]
                #expect(expected != nil, "\(context) has unknown type \(type)")
                if let value, let expected { #expect((value as AnyObject).isKind(of: expected), "\(context) is not a \(type)") }
            }
        }
        for element in classes {
            let name = try #require(element.attribute(forName: "name")?.stringValue)
            let object = try #require(instances[name], "No fixture for class \(name)")
            #expect(object.classDescription is NSScriptClassDescription, "\(name) has no class description")
            for property in element.elements(forName: "property") {
                let key = try #require(Self.cocoaName(property, "key"))
                let type = try #require(property.attribute(forName: "type")?.stringValue)
                let context = "\(name).\(key)"
                #expect(intrinsics[type] != nil || cocoaClasses[type] != nil, "\(context) uses undeclared type \(type)")
                // Cocoa reads properties through scripting KVC, which also serves NSApplication's name and version.
                let description = try #require(object.classDescription as? NSScriptClassDescription)
                let reader = NSPropertySpecifier(containerClassDescription: description, containerSpecifier: nil, key: key)
                let value = reader.objectsByEvaluating(withContainers: object)
                #expect(reader.evaluationErrorNumber == 0, "\(context) cannot be read: \(reader.evaluationErrorNumber)")
                check(value, isOf: type, context)
                if (property.attribute(forName: "access")?.stringValue ?? "rw").contains("w") {
                    #expect(writable.contains(context), "\(context) is writable but no command writes it")
                }
            }
            for relation in element.elements(forName: "element") {
                let key = try #require(Self.cocoaName(relation, "key"))
                let typeName = try #require(relation.attribute(forName: "type")?.stringValue)
                let elementClass = try #require(cocoaClasses[typeName], "\(name).\(key) has unknown element type \(typeName)")
                let suffix = key.prefix(1).uppercased() + key.dropFirst()
                guard object.responds(to: NSSelectorFromString(key)) else { Issue.record("\(name).\(key) has no to-many getter"); continue }
                let values = object.value(forKey: key) as? [NSObject]
                #expect(values?.isEmpty == false, "\(name).\(key) is not a populated list")
                for value in values ?? [] { #expect(value.isKind(of: elementClass), "\(name).\(key) contains \(type(of: value))") }
                #expect(object.responds(to: NSSelectorFromString("valueIn\(suffix)WithUniqueID:")), "\(name).\(key) cannot resolve ids")
                if (relation.attribute(forName: "access")?.stringValue ?? "rw").contains("w") {
                    #expect(object.responds(to: NSSelectorFromString("insertObject:in\(suffix)AtIndex:")), "\(name).\(key) cannot insert")
                    #expect(object.responds(to: NSSelectorFromString("removeObjectFrom\(suffix)AtIndex:")), "\(name).\(key) cannot remove")
                }
                let target = try #require(classes.first { $0.attribute(forName: "name")?.stringValue == typeName })
                #expect(target.elements(forName: "property").contains { $0.attribute(forName: "code")?.stringValue == "ID  " },
                        "\(typeName) elements need an id property for their unique-ID references")
            }
        }

        // Cocoa's own get, set, count and make classes evaluate references and package replies.
        let standard: [String: AnyClass] = ["coregetd": NSGetCommand.self, "coresetd": NSSetCommand.self,
                                            "corecnte": NSCountCommand.self, "corecrel": NSCreateCommand.self]
        // These events keep their application handlers; a dictionary command would replace them.
        let applicationEvents: Set = ["GURLGURL", "aevtodoc", "aevtoapp", "aevtrapp", "aevtquit", "aevtpdoc"]
        let parameterKeys: [String: Set<String>] = ["coresetd": ["Value"], "corecnte": ["ObjectClass"],
                                                    "corecrel": ["ObjectClass", "Location", "KeyDictionary"], "CrSuExJa": ["javascript"]]
        for command in try dictionary.nodes(forXPath: "//suite/command").compactMap({ $0 as? XMLElement }) {
            let code = try #require(command.attribute(forName: "code")?.stringValue)
            #expect(!applicationEvents.contains(code), "\(code) is owned by an application event handler")
            let implementation = try #require(Self.cocoaName(command, "class").flatMap(NSClassFromString) as? NSScriptCommand.Type,
                                              "\(code) has no command class")
            if let base = standard[code] { #expect(implementation.isSubclass(of: base), "\(code) must extend \(base)") }
            for direct in command.elements(forName: "direct-parameter") {
                // An "any" direct parameter arrives as a raw descriptor without receivers.
                #expect(direct.attribute(forName: "type")?.stringValue == "specifier", "\(code) direct parameter must be a specifier")
            }
            for result in command.elements(forName: "result") {
                let type = try #require(result.attribute(forName: "type")?.stringValue)
                #expect(intrinsics[type] != nil, "\(code) result uses undeclared type \(type)")
                #expect(type != "any" || code == "coregetd", "\(code) must declare a concrete result type")
            }
            let keys = Set(command.elements(forName: "parameter").compactMap { Self.cocoaName($0, "key") })
            #expect(keys == parameterKeys[code, default: []], "\(code) parameter keys \(keys)")
        }
    }

    @Test("Resumed results always match the class Cocoa requires for the declared result type")
    func replyGate() throws {
        try loadDictionary()
        _ = NSApplication.shared
        let contract = try ReplyContract()
        let scripting = BrowserScriptingController()
        let window = CircaScriptWindow(id: "window", mode: "normal", scripting: scripting, isFocused: { false }, title: { "Window" })
        let space = CircaScriptSpace(id: "space", title: "Space", window: window)
        let tab = CircaScriptTab(id: "tab", title: "Page", url: "about:blank", location: "unpinned", loading: false, space: space)
        window.appleScriptSpaces = [space]; space.appleScriptTabs = [tab]
        let values: [Any?] = [nil, NSNull(), "text", ["text"], [], 3, true, NSAppleEventDescriptor(string: "text"),
                              NSAppleEventDescriptor.list(), try #require(tab.objectSpecifier), tab, [tab], ["key": "value"]]
        for (code, required) in contract.results {
            for value in values {
                guard let reply = try? BrowserScriptingController.replyValue(value, resultCode: code) else { continue }
                #expect((reply as AnyObject).isKind(of: required), "\(value.map { "\(type(of: $0))" } ?? "nil") passed as \(required)")
            }
        }
        // The shapes that crashed reply conversion are refused before Cocoa sees them.
        #expect(throws: BrowserScriptError.unsupported) { try BrowserScriptingController.replyValue(["a", "b"], resultCode: typeWildCard) }
        #expect(throws: BrowserScriptError.unavailable) { try BrowserScriptingController.replyValue("tab", resultCode: typeObjectSpecifier) }
        #expect(throws: BrowserScriptError.unsupported) { try BrowserScriptingController.replyValue(true, resultCode: typeSInt32) }
        #expect(try BrowserScriptingController.replyValue(tab, resultCode: typeObjectSpecifier) is NSScriptObjectSpecifier)
        #expect(try BrowserScriptingController.replyValue("anything", resultCode: typeNull) == nil)
    }

    @Test("Every object returned by the inventory resolves back to an equal object, also after a refresh")
    func specifierRoundTrip() async throws {
        let fixture = try await ScriptingEventFixture()
        defer { fixture.close() }
        let session = fixture.headless.sessions[0].session
        session.openTab(url: URL(string: "about:blank#first")!)
        let profile = try #require(session.activeProfileID)
        let other = try await fixture.headless.sessions[0].environment.store.createSpace(name: "Second", profileID: profile)
        session.activateSpace(other)
        session.openTab(url: URL(string: "about:blank#second")!)
        await session.waitForPendingCommands()
        _ = try await fixture.headless.makeWindow("normal")
        await fixture.app.scripting.refresh()
        func inventory() -> [NSObject] {
            let windows = fixture.app.scripting.windows
            return windows + windows.flatMap(\.appleScriptSpaces) + windows.flatMap(\.appleScriptTabs)
                + windows.compactMap(\.activeTab) + windows.compactMap(\.activeSpace)
        }
        let objects = inventory()
        #expect(objects.filter { $0 is CircaScriptTab }.count >= 2 && objects.contains { $0 is CircaScriptSpace })
        let references = try objects.map { object in
            let descriptor = try #require(object.objectSpecifier?.descriptor, "\(object) has no reference")
            return (object, try #require(NSScriptObjectSpecifier(descriptor: descriptor)))
        }
        for (object, reference) in references {
            let resolved = reference.objectsByEvaluatingSpecifier as? NSObject
            #expect(resolved === object, "\(reference) resolved to \(String(describing: resolved))")
        }
        await fixture.app.scripting.refresh()
        for (object, reference) in references {
            let resolved = try #require(reference.objectsByEvaluatingSpecifier as? NSObject, "\(reference) expired after refresh")
            #expect(resolved !== object && type(of: resolved) == type(of: object))
            #expect(resolved.value(forKey: "id") as? String == object.value(forKey: "id") as? String)
        }
    }

    @Test("Raw Apple events list, create, set, select, reload, run gated JavaScript and close through Cocoa")
    func appleEventPipeline() async throws {
        let fixture = try await ScriptingEventFixture()
        defer { fixture.close() }
        let session = fixture.headless.sessions[0].session
        session.openTab(url: URL(string: "about:blank#existing")!)
        await session.waitForPendingCommands()
        let window1 = ScriptEvent.index("WiND", 1)
        let tabs = ScriptEvent.every("tAbB", of: window1)

        #expect(try await fixture.result("core", "cnte", direct: .null(), ["kocl": ScriptEvent.type("WiND")]).int32Value == 1)
        let windowIDs = try await fixture.strings("core", "getd", direct: ScriptEvent.property("ID  ", of: ScriptEvent.every("WiND")))
        #expect(windowIDs == [fixture.headless.sessions[0].id])
        #expect(try await fixture.strings("core", "getd", direct: ScriptEvent.property("pnam", of: ScriptEvent.every("WiND"))) == ["Synthetic window"])
        let spaceIDs = try await fixture.strings("core", "getd", direct: ScriptEvent.property("ID  ", of: ScriptEvent.every("sPaC", of: window1)))
        let spaceTitles = try await fixture.strings("core", "getd", direct: ScriptEvent.property("pnam", of: ScriptEvent.every("sPaC", of: window1)))
        #expect(!spaceIDs.isEmpty && spaceIDs.count == spaceTitles.count)
        #expect(try await fixture.strings("core", "getd", direct: ScriptEvent.property("URL ", of: tabs)) == ["about:blank#existing"])
        #expect(try await fixture.strings("core", "getd", direct: ScriptEvent.property("pnam", of: tabs)).count == 1)
        let initial = try await fixture.result("core", "cnte", direct: window1, ["kocl": ScriptEvent.type("tAbB")]).int32Value

        let properties = NSAppleEventDescriptor.record()
        properties.setDescriptor(NSAppleEventDescriptor(string: "about:blank#created"), forKeyword: ScriptEvent.code("URL "))
        let created = try await fixture.result("core", "crel", direct: nil, ["kocl": ScriptEvent.type("tAbB"),
                                                                            "insh": ScriptEvent.end(of: tabs), "prdt": properties])
        #expect(created.descriptorType == typeObjectSpecifier)
        let createdTab = try #require(NSScriptObjectSpecifier(descriptor: created)?.objectsByEvaluatingSpecifier as? CircaScriptTab)
        #expect(try await fixture.result("core", "cnte", direct: window1, ["kocl": ScriptEvent.type("tAbB")]).int32Value == initial + 1)
        #expect(try await fixture.result("core", "getd", direct: ScriptEvent.property("ID  ", of: created)).stringValue == createdTab.id)
        let active = try await fixture.result("core", "getd", direct: ScriptEvent.property("acTa", of: window1))
        #expect((NSScriptObjectSpecifier(descriptor: active)?.objectsByEvaluatingSpecifier as? CircaScriptTab)?.id == createdTab.id)
        #expect(try await fixture.result("core", "getd", direct: ScriptEvent.property("pcls", of: created)).typeCodeValue == ScriptEvent.code("tAbB"))
        let record = try await fixture.result("core", "getd", direct: ScriptEvent.property("pALL", of: created))
        #expect(record.forKeyword(ScriptEvent.code("URL "))?.stringValue == "about:blank#created")

        _ = try await fixture.result("core", "setd", direct: ScriptEvent.property("URL ", of: created),
                                     ["data": NSAppleEventDescriptor(string: "about:blank#changed")], expectsResult: false)
        #expect(try await fixture.result("core", "getd", direct: ScriptEvent.property("URL ", of: created)).stringValue == "about:blank#changed")
        _ = try await fixture.result("CrSe", "lect", direct: created, expectsResult: false)
        #expect(session.organization?.selectedTab?.id.rawValue.uuidString == createdTab.id)
        _ = try await fixture.result("CrSu", "Rlod", direct: created, expectsResult: false)

        let script = ["JvSc": NSAppleEventDescriptor(string: BrowserEngineConformance.typedKeysScript)]
        let refused = try await fixture.reply("CrSu", "ExJa", direct: created, script)
        #expect(refused.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value == -1743)
        #expect(refused.paramDescriptor(forKeyword: keyErrorString)?.stringValue?.contains("Allow JavaScript") == true)
        #expect(fixture.headless.executions == 0)
        fixture.app.scripting.allowsJavaScript = { true }
        #expect(try await fixture.result("CrSu", "ExJa", direct: created, script).stringValue == "")
        #expect(fixture.headless.executions == 1)

        let missing = try await fixture.reply("core", "getd", direct: ScriptEvent.property("URL ", of: ScriptEvent.uniqueID("tAbB", "missing", of: window1)))
        #expect(missing.paramDescriptor(forKeyword: keyErrorNumber) != nil || missing.paramDescriptor(forKeyword: keyDirectObject)?.typeCodeValue == ScriptEvent.code("msng"))
        _ = try await fixture.result("core", "clos", direct: created, expectsResult: false)
        #expect(try await fixture.result("core", "cnte", direct: window1, ["kocl": ScriptEvent.type("tAbB")]).int32Value == initial)

        // Creation without a location targets the front window and returns a resolvable reference.
        let defaultTab = try await fixture.result("core", "crel", direct: nil, ["kocl": ScriptEvent.type("tAbB"), "prdt": properties])
        #expect(NSScriptObjectSpecifier(descriptor: defaultTab)?.objectsByEvaluatingSpecifier is CircaScriptTab)
        let newWindow = try await fixture.result("core", "crel", direct: nil, ["kocl": ScriptEvent.type("WiND")])
        #expect(NSScriptObjectSpecifier(descriptor: newWindow)?.objectsByEvaluatingSpecifier is CircaScriptWindow)
        #expect(fixture.headless.sessions.count == 2)
        #expect(fixture.violations.isEmpty, "Reply contract violations: \(fixture.violations)")
    }

    @Test("Private window content stays redacted through Apple events until it is targeted and focused")
    func privateAppleEvents() async throws {
        let fixture = try await ScriptingEventFixture(mode: "incognito")
        defer { fixture.close() }
        let session = fixture.headless.sessions[0].session
        session.openTab(url: URL(string: "about:blank#private")!)
        await session.waitForPendingCommands()
        fixture.app.scripting.allowsJavaScript = { true }
        let global = ScriptEvent.property("URL ", of: ScriptEvent.every("tAbB"))
        let byIndex = ScriptEvent.property("URL ", of: ScriptEvent.every("tAbB", of: ScriptEvent.index("WiND", 1)))
        fixture.headless.focused = nil
        #expect(try await fixture.strings("core", "getd", direct: byIndex) == [""])
        fixture.headless.focused = fixture.headless.sessions[0].id
        #expect(try await fixture.strings("core", "getd", direct: global) == [""])
        #expect(try await fixture.strings("core", "getd", direct: byIndex) == ["about:blank#private"])
        fixture.headless.focused = nil
        let tab = ScriptEvent.index("tAbB", 1, of: ScriptEvent.index("WiND", 1))
        let refused = try await fixture.reply("CrSu", "ExJa", direct: tab, ["JvSc": NSAppleEventDescriptor(string: "1")])
        #expect(refused.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value == -1743)
        #expect(fixture.headless.executions == 0)
        #expect(fixture.violations.isEmpty, "Reply contract violations: \(fixture.violations)")
    }


    @Test("Unsupported and unresolvable requests reply with errors instead of raising in a resumed command")
    func hostileAppleEvents() async throws {
        let fixture = try await ScriptingEventFixture()
        defer { fixture.close() }
        let session = fixture.headless.sessions[0].session
        session.openTab(url: URL(string: "about:blank#existing")!)
        await session.waitForPendingCommands()
        let window1 = ScriptEvent.index("WiND", 1)
        let tab1 = ScriptEvent.index("tAbB", 1, of: window1)
        let text = NSAppleEventDescriptor(string: "about:blank#hostile")
        let requests: [(String, String, NSAppleEventDescriptor?, [String: NSAppleEventDescriptor], Bool)] = [
            ("core", "getd", .null(), [:], false),
            ("core", "getd", ScriptEvent.property("pALL", of: .null()), [:], true),
            ("core", "getd", ScriptEvent.property("pALL", of: window1), [:], true),
            ("core", "getd", ScriptEvent.every("WiND"), [:], true),
            ("core", "getd", ScriptEvent.property("URL ", of: ScriptEvent.index("tAbB", 99, of: window1)), [:], false),
            ("core", "getd", ScriptEvent.property("ID  ", of: ScriptEvent.index("WiND", 9)), [:], false),
            ("core", "cnte", tab1, ["kocl": ScriptEvent.type("tAbB")], false),
            ("core", "cnte", .null(), ["kocl": ScriptEvent.type("tAbB")], true),
            ("core", "crel", nil, ["kocl": ScriptEvent.type("sPaC")], false),
            ("core", "crel", nil, ["kocl": ScriptEvent.type("tAbB"), "insh": ScriptEvent.end(of: ScriptEvent.every("tAbB", of: tab1))], false),
            ("core", "setd", ScriptEvent.property("pnam", of: window1), ["data": text], false),
            ("core", "setd", ScriptEvent.property("URL ", of: tab1), ["data": NSAppleEventDescriptor(string: "relative")], false),
            ("core", "setd", ScriptEvent.property("URL ", of: tab1), ["data": NSAppleEventDescriptor(int32: 3)], false),
            ("CrSu", "Rlod", window1, [:], false),
            ("core", "clos", .null(), [:], false),
            ("CrSu", "ExJa", window1, ["JvSc": NSAppleEventDescriptor(string: "1")], false)
        ]
        for (eventClass, eventID, direct, parameters, succeeds) in requests {
            let reply = try await fixture.reply(eventClass, eventID, direct: direct, parameters)
            let failed = reply.paramDescriptor(forKeyword: keyErrorNumber) != nil
                || reply.paramDescriptor(forKeyword: keyDirectObject)?.typeCodeValue == ScriptEvent.code("msng")
            #expect(failed != succeeds, "\(eventClass)\(eventID) \(String(describing: direct)) replied \(reply)")
        }
        #expect(try await fixture.result("core", "cnte", direct: window1, ["kocl": ScriptEvent.type("tAbB")]).int32Value == 1)
        #expect(fixture.violations.isEmpty, "Reply contract violations: \(fixture.violations)")
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


    nonisolated static let dictionaryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Scripting/Circa.sdef")

    private static func cocoaName(_ element: XMLElement, _ attribute: String) -> String? {
        element.elements(forName: "cocoa").first?.attribute(forName: attribute)?.stringValue
    }

    private static var dictionaryLoaded = false

    func loadDictionary() throws { try Self.loadDictionary() }

    static func loadDictionary() throws {
        guard !Self.dictionaryLoaded else { return }
        // A test process has no main-bundle dictionary, so Cocoa starts its legacy script-suite
        // registry, where "any" accepts every object and "text" is unknown. Load the shipped sdef
        // as an application bundle does instead: sdef mode, Cocoa's intrinsic suite, then the file.
        let registry = NSScriptSuiteRegistry.shared()
        let intrinsics = NSSelectorFromString("_loadIntrinsicScriptingDefinitions")
        let loader = NSSelectorFromString("_loadSuitesFromSDEFData:bundle:")
        try #require(registry.responds(to: intrinsics) && registry.responds(to: loader))
        registry.setValue(true, forKey: "_isLoadingSDEFFiles")
        _ = registry.perform(intrinsics)
        typealias Load = @convention(c) (NSScriptSuiteRegistry, Selector, NSData, Bundle?) -> Void
        unsafeBitCast(registry.method(for: loader), to: Load.self)(registry, loader, try Data(contentsOf: dictionaryURL) as NSData, nil)
        try #require(registry.commandDescription(withAppleEventClass: ScriptEvent.code("core"), andAppleEventCode: ScriptEvent.code("getd"))?
            .returnType == "any")
        Self.dictionaryLoaded = true
    }
}
}

private final class ScriptHostFixtureApplication: NSApplication {}

/// The class Cocoa's reply conversion requires for each declared result type, read from the
/// framework's intrinsic value types: a resumed value of any other class raises outside a handler.
private struct ReplyContract {
    /// Result Apple event code, as `NSScriptCommandDescription` reports it, to the required class.
    let results: [FourCharCode: AnyClass]

    init() throws {
        let types = try Self.intrinsicValueTypes()
        let dictionary = try XMLDocument(contentsOf: NativeWebKitTests.BrowserScriptingTests.dictionaryURL)
        var results: [FourCharCode: AnyClass] = [:]
        for result in try dictionary.nodes(forXPath: "//suite/command/result").compactMap({ $0 as? XMLElement }) {
            let name = try #require(result.attribute(forName: "type")?.stringValue)
            let type = try #require(types[name], "Undeclared result type \(name)")
            results[type.code] = type.cocoa
        }
        self.results = results
    }

    static func intrinsicValueTypes() throws -> [String: (code: FourCharCode, cocoa: AnyClass)] {
        let url = try #require(Bundle(for: NSScriptCommand.self).url(forResource: "Intrinsics", withExtension: "sdef"))
        var types: [String: (code: FourCharCode, cocoa: AnyClass)] = [:]
        for element in try XMLDocument(contentsOf: url).nodes(forXPath: "//value-type").compactMap({ $0 as? XMLElement }) {
            guard let name = element.attribute(forName: "name")?.stringValue,
                  let code = element.attribute(forName: "code")?.stringValue,
                  let cocoa = element.elements(forName: "cocoa").first?.attribute(forName: "class")?.stringValue,
                  let cocoaClass = NSClassFromString(cocoa) else { continue }
            types[name] = (ScriptEvent.code(code), cocoaClass)
        }
        return types
    }

    func requiredClass(for description: NSScriptCommandDescription) -> AnyClass? {
        results[description.appleEventCodeForReturnType]
    }
}

/// Builds the descriptors AppleScript sends: object specifiers, insertion locations and types.
private enum ScriptEvent {
    static func code(_ text: String) -> FourCharCode { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    static func type(_ value: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(typeCode: code(value)) }

    static func object(_ want: String, _ form: String, _ data: NSAppleEventDescriptor,
                       of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let descriptor = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeObjectSpecifier)!
        descriptor.setDescriptor(type(want), forKeyword: code("want"))
        descriptor.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        descriptor.setDescriptor(data, forKeyword: code("seld"))
        descriptor.setDescriptor(container, forKeyword: code("from"))
        return descriptor
    }

    static func property(_ value: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        object("prop", "prop", type(value), of: container)
    }

    static func every(_ want: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        var all = code("all ")
        return object(want, "indx", NSAppleEventDescriptor(descriptorType: typeAbsoluteOrdinal, bytes: &all, length: 4)!, of: container)
    }

    static func index(_ want: String, _ index: Int32, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        object(want, "indx", NSAppleEventDescriptor(int32: index), of: container)
    }

    static func uniqueID(_ want: String, _ id: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        object(want, "ID  ", NSAppleEventDescriptor(string: id), of: container)
    }

    static func end(of collection: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let location = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeInsertionLoc)!
        location.setDescriptor(NSAppleEventDescriptor(enumCode: code("end ")), forKeyword: code("kpos"))
        location.setDescriptor(collection, forKeyword: code("kobj"))
        return location
    }
}

/// Dispatches raw Apple events through Cocoa's own handler into the production commands,
/// suspension and reply packaging included, over headless synthetic sessions.
@MainActor
private final class ScriptingEventFixture {
    let app = OrbitApplication()
    let headless: HeadlessScriptingSession
    private let contract: ReplyContract
    private(set) var violations: [String] = []
    private var resumed = false
    private let previousDelegate: NSApplicationDelegate?
    private let previousTopLevel: Any?

    init(mode: String = "normal") async throws {
        try NativeWebKitTests.BrowserScriptingTests.loadDictionary()
        _ = NSApplication.shared
        contract = try ReplyContract()
        previousDelegate = NSApp.delegate
        let context = NSScriptExecutionContext.shared()
        previousTopLevel = context.topLevelObject
        NSApp.delegate = app
        context.topLevelObject = NSApp
        headless = HeadlessScriptingSession(scripting: app.scripting)
        app.scripting.refresh = { [headless] in await headless.refresh() }
        app.scripting.createWindow = { [headless] in try await headless.makeWindow($0) }
        let resume = app.scripting.resume
        app.scripting.resume = { [weak self] command, value in
            self?.observe(command, value)
            resume(command, value)
        }
        _ = try await headless.makeWindow(mode)
    }

    private func observe(_ command: NSScriptCommand, _ value: Any?) {
        resumed = true
        guard let value else { return }
        let name = command.commandDescription.commandName
        guard let required = contract.requiredClass(for: command.commandDescription) else {
            violations.append("\(name) resumed with \(type(of: value)) without a declared result")
            return
        }
        if !(value as AnyObject).isKind(of: required) { violations.append("\(name) resumed with \(type(of: value)), not \(required)") }
    }

    func reply(_ eventClass: String, _ eventID: String, direct: NSAppleEventDescriptor?,
               _ parameters: [String: NSAppleEventDescriptor] = [:]) async throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: ScriptEvent.code(eventClass), eventID: ScriptEvent.code(eventID),
                                           targetDescriptor: NSAppleEventDescriptor(processIdentifier: getpid()),
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let direct { event.setParam(direct, forKeyword: keyDirectObject) }
        for (key, value) in parameters { event.setParam(value, forKeyword: ScriptEvent.code(key)) }
        let reply = NSAppleEventDescriptor(eventClass: ScriptEvent.code("aevt"), eventID: ScriptEvent.code("ansr"), targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        resumed = false
        let status = NSAppleEventManager.shared().dispatchRawAppleEvent(try #require(event.aeDesc),
            withRawReply: UnsafeMutablePointer(mutating: try #require(reply.aeDesc)), handlerRefCon: UnsafeMutableRawPointer(bitPattern: 1)!)
        #expect(status == noErr)
        // Suspended commands resume from a later main-actor task; rejected ones reply at once.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !resumed, reply.paramDescriptor(forKeyword: keyErrorNumber) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(resumed || reply.paramDescriptor(forKeyword: keyErrorNumber) != nil, "\(eventClass)\(eventID) never replied")
        return reply
    }

    func result(_ eventClass: String, _ eventID: String, direct: NSAppleEventDescriptor?,
                _ parameters: [String: NSAppleEventDescriptor] = [:], expectsResult: Bool = true) async throws -> NSAppleEventDescriptor {
        let reply = try await reply(eventClass, eventID, direct: direct, parameters)
        #expect(reply.paramDescriptor(forKeyword: keyErrorNumber) == nil, "\(eventClass)\(eventID) failed: \(reply)")
        guard expectsResult else { return reply }
        return try #require(reply.paramDescriptor(forKeyword: keyDirectObject), "\(eventClass)\(eventID) has no result: \(reply)")
    }

    func strings(_ eventClass: String, _ eventID: String, direct: NSAppleEventDescriptor?) async throws -> [String] {
        let list = try await result(eventClass, eventID, direct: direct)
        #expect(list.descriptorType == typeAEList, "Not a list: \(list)")
        return (0..<list.numberOfItems).compactMap { list.atIndex($0 + 1)?.stringValue }
    }

    func close() {
        headless.close()
        NSApp.delegate = previousDelegate
        NSScriptExecutionContext.shared().topLevelObject = previousTopLevel
    }
}

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
            // Count scripts that pass the gates; evaluation itself goes through the engine's service.
            for tab in window.appleScriptTabs {
                let action = tab.action
                tab.action = { request in
                    if case .javascript = request { self.executions += 1 }
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
