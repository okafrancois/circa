import AppKit
import Carbon
import BrowserCore
import BrowserEngine
import BrowserShell

/// Cocoa Scripting objects carry stable model identities, never native window numbers.
@MainActor
final class BrowserScriptingController {
    var windows: [CircaScriptWindow] = []
    var refresh: () async -> Void = {}
    var createWindow: (String) async throws -> CircaScriptWindow = { _ in throw BrowserScriptError.unavailable }
    var allowsJavaScript: () -> Bool = { false }
    var targetWindowID: String?
    // NSCreateCommand's synchronous factory/insertion phase is followed by the ordered
    // asynchronous session mutation before the command resumes with the canonical object.
    var creation: (() async throws -> NSObject)?
    private var pending: Task<Void, Never>?

    func submit(_ command: NSScriptCommand, action: @escaping @MainActor () async throws -> Any?) {
        command.suspendExecution()
        let previous = pending
        pending = Task { @MainActor in
            await previous?.value
            await refresh()
            // Suspended commands no longer have the event's implicit top-level container.
            let context = NSScriptExecutionContext.shared()
            let previousTopLevel = context.topLevelObject
            context.topLevelObject = NSApp
            defer { context.topLevelObject = previousTopLevel }
            targetWindowID = explicitWindow(in: command.receiversSpecifier ?? Self.decodedScriptValue(command.directParameter) as? NSScriptObjectSpecifier)
            do { command.resumeExecution(withResult: try Self.replyValue(try await action(), returnType: command.commandDescription.returnType)) }
            catch {
                command.scriptErrorNumber = (error as? BrowserScriptError)?.code ?? -10000
                command.scriptErrorString = (error as? BrowserScriptError)?.message ?? uiText("The scripting operation could not be completed.")
                command.resumeExecution(withResult: nil)
            }
            targetWindowID = nil
        }
    }

    static func applicationClassDescription(for hostClass: AnyClass) -> NSScriptClassDescription? {
        // Native engine hosts may subclass NSApplication without registering another dictionary class.
        (NSClassDescription(for: hostClass) as? NSScriptClassDescription)
            ?? NSScriptSuiteRegistry.shared().classDescription(withAppleEventCode: "capp".utf8.reduce(0) { ($0 << 8) | UInt32($1) })
    }

    /// Sdef "any" parameters preserve raw descriptors, unlike script-suite declarations.
    /// Decode references before evaluating them so scalar counts and privacy scope use the model.
    static func decodedScriptValue(_ value: Any?) -> Any? {
        if let descriptor = value as? NSAppleEventDescriptor {
            switch descriptor.descriptorType {
            case typeObjectSpecifier: return NSScriptObjectSpecifier(descriptor: descriptor)
            case typeAEList:
                return (0..<descriptor.numberOfItems).map { decodedScriptValue(descriptor.atIndex($0 + 1)) ?? NSNull() }
            case typeUnicodeText, typeUTF8Text, typeChar: return descriptor.stringValue
            case typeType: return NSNumber(value: descriptor.typeCodeValue)
            default: return descriptor
            }
        }
        if let values = value as? [Any] { return values.map { decodedScriptValue($0) ?? NSNull() } }
        return value
    }

    /// Reply conversion accepts references, not model wrappers, for declared specifier results.
    static func replyValue(_ value: Any?) -> Any? {
        switch value {
        case let window as CircaScriptWindow: return window.objectSpecifier
        case let space as CircaScriptSpace: return space.objectSpecifier
        case let tab as CircaScriptTab: return tab.objectSpecifier
        case let values as [Any]: return values.map { replyValue($0) ?? NSNull() }
        default: return value
        }
    }

    static func replyValue(_ value: Any?, returnType: String?) throws -> Any? {
        let result = replyValue(value)
        // Native sdef "any" results require an already encoded descriptor. Script-suite
        // dictionaries instead declare "id", which Cocoa converts from ordinary objects.
        guard returnType == "any" || returnType == "NSAppleEventDescriptor" else { return result }
        return try replyDescriptor(result)
    }

    private static func replyDescriptor(_ value: Any?) throws -> NSAppleEventDescriptor {
        switch value {
        case nil, is NSNull: return .null()
        case let descriptor as NSAppleEventDescriptor: return descriptor
        case let specifier as NSScriptObjectSpecifier:
            guard let descriptor = specifier.descriptor else { throw BrowserScriptError.unavailable }
            return descriptor
        case let string as String: return NSAppleEventDescriptor(string: string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return NSAppleEventDescriptor(boolean: number.boolValue) }
            if String(cString: number.objCType) == "d" || String(cString: number.objCType) == "f" {
                return NSAppleEventDescriptor(double: number.doubleValue)
            }
            var integer = number.int64Value
            guard let descriptor = withUnsafeBytes(of: &integer, { NSAppleEventDescriptor(descriptorType: typeSInt64, data: Data($0)) }) else {
                throw BrowserScriptError.unsupported
            }
            return descriptor
        case let values as [Any]:
            let list = NSAppleEventDescriptor.list()
            for (index, value) in values.enumerated() { list.insert(try replyDescriptor(value), at: index + 1) }
            return list
        default: throw BrowserScriptError.unsupported
        }
    }

    private func explicitWindow(in specifier: NSScriptObjectSpecifier?) -> String? {
        guard let specifier else { return nil }
        if specifier.key == "appleScriptWindows",
           specifier is NSIndexSpecifier || specifier is NSNameSpecifier || specifier is NSUniqueIDSpecifier {
            return (specifier.objectsByEvaluatingSpecifier as? CircaScriptWindow)?.id
        }
        return explicitWindow(in: specifier.container)
    }

    func validateNavigation(_ url: Foundation.URL) throws {
        guard url.scheme != nil else { throw BrowserScriptError.invalidURL }
        if url.scheme?.lowercased() == "javascript", !allowsJavaScript() { throw BrowserScriptError.javaScriptDisabled }
    }

    func execute(_ script: String, in tab: CircaScriptTab) async throws -> String? {
        guard allowsJavaScript() else { throw BrowserScriptError.javaScriptDisabled }
        guard tab.window?.canReadPrivateContent == true else { throw BrowserScriptError.privateContent }
        let result = try await tab.action(.javascript(script))
        guard tab.window?.canReadPrivateContent == true else { throw BrowserScriptError.privateContent }
        return result
    }
}

enum BrowserScriptError: Error, Equatable {
    case unavailable, invalidURL, javaScriptDisabled, privateContent, unsupported
    var code: Int { switch self { case .javaScriptDisabled, .privateContent: -1743; case .unavailable: -1728; case .invalidURL: -1700; case .unsupported: -1708 } }
    @MainActor var message: String {
        switch self {
        case .javaScriptDisabled: uiText("Enable “Allow JavaScript from Apple Events” in Settings to run JavaScript.")
        case .privateContent: uiText("Target and focus the private window before accessing its content.")
        case .unavailable: uiText("The scripting object is no longer available.")
        case .invalidURL: uiText("The URL is invalid.")
        case .unsupported: uiText("This scripting operation is not supported.")
        }
    }
}

enum BrowserScriptTabAction { case select, close, reload, back, forward, stop, navigate(URL), javascript(String) }

@MainActor
@objc(CircaScriptWindow)
final class CircaScriptWindow: NSObject {
    @objc let id: String
    @objc let mode: String
    @objc var incognito: Bool { mode == "incognito" }
    weak var scripting: BrowserScriptingController?
    var isFocused: () -> Bool
    var titleValue: () -> String
    var focus: () -> Void = {}
    var close: () -> Void = {}
    var makeTab: (URL, String?) async throws -> String = { _, _ in throw BrowserScriptError.unavailable }
    @objc var appleScriptSpaces: [CircaScriptSpace] = []
    @objc var appleScriptTabs: [CircaScriptTab] { appleScriptSpaces.flatMap(\.appleScriptTabs).uniquedByID() }
    @objc var activeTab: CircaScriptTab? { appleScriptTabs.first { $0.id == selectedTabID() } }
    @objc var activeSpace: CircaScriptSpace? { appleScriptSpaces.first { $0.id == selectedSpaceID() } }
    var selectedTabID: () -> String? = { nil }
    var selectedSpaceID: () -> String? = { nil }
    var canReadPrivateContent: Bool { !incognito || (scripting?.targetWindowID == id && isFocused()) }
    @objc var title: String { canReadPrivateContent ? titleValue() : "" }
    @objc var name: String { title }

    @objc(valueInAppleScriptTabsWithUniqueID:)
    func scriptTab(withID id: String) -> CircaScriptTab? { appleScriptTabs.first { $0.id == id } }
    @objc(valueInAppleScriptSpacesWithUniqueID:)
    func scriptSpace(withID id: String) -> CircaScriptSpace? { appleScriptSpaces.first { $0.id == id } }

    init(id: String, mode: String, scripting: BrowserScriptingController, isFocused: @escaping () -> Bool,
         title: @escaping () -> String) {
        self.id = id; self.mode = mode; self.scripting = scripting; self.isFocused = isFocused; titleValue = title
    }
    @objc(insertObject:inAppleScriptTabsAtIndex:)
    func insertTab(_ tab: CircaScriptTab, at index: Int) {
        guard let space = tab.space ?? activeSpace ?? appleScriptSpaces.first else { return }
        space.insertTab(tab, at: min(index, space.appleScriptTabs.count))
    }
    @objc(removeObjectFromAppleScriptTabsAtIndex:)
    func removeTab(at index: Int) {
        guard appleScriptTabs.indices.contains(index), let space = appleScriptTabs[index].space,
              let local = space.appleScriptTabs.firstIndex(where: { $0.id == appleScriptTabs[index].id }) else { return }
        space.removeTab(at: local)
    }
    override func newScriptingObject(of objectClass: AnyClass, forValueForKey key: String,
                                     withContentsValue contents: Any?, properties: [String: Any]) -> Any? {
        let arguments = MainThreadScriptingProperties(contents: contents, properties: properties)
        return mainThreadScriptingObject {
            guard objectClass == CircaScriptTab.self, key == "appleScriptTabs",
                  let space = activeSpace ?? appleScriptSpaces.first else { return nil }
            return space.newScriptingObject(of: objectClass, forValueForKey: key,
                                            withContentsValue: arguments.contents, properties: arguments.properties)
        }
    }
    override var objectSpecifier: NSScriptObjectSpecifier? {
        mainThreadSpecifier {
            guard let app = NSApp,
                  let description = BrowserScriptingController.applicationClassDescription(for: type(of: app)) else { return nil }
            return NSUniqueIDSpecifier(containerClassDescription: description,
                                      containerSpecifier: nil, key: "appleScriptWindows", uniqueID: id)
        }
    }
}

@MainActor
@objc(CircaScriptSpace)
final class CircaScriptSpace: NSObject {
    @objc let id: String
    @objc let title: String
    @objc var name: String { title }
    weak var window: CircaScriptWindow?
    var focus: () async throws -> Void = {}
    @objc var appleScriptTabs: [CircaScriptTab] = []
    @objc(valueInAppleScriptTabsWithUniqueID:)
    func scriptTab(withID id: String) -> CircaScriptTab? { appleScriptTabs.first { $0.id == id } }
    init(id: String, title: String, window: CircaScriptWindow) { self.id = id; self.title = title; self.window = window }
    @objc(insertObject:inAppleScriptTabsAtIndex:)
    func insertTab(_ tab: CircaScriptTab, at index: Int) {
        guard !appleScriptTabs.contains(where: { $0.id == tab.id }) else { return }
        tab.space = self
        appleScriptTabs.insert(tab, at: max(0, min(index, appleScriptTabs.count)))
    }
    @objc(removeObjectFromAppleScriptTabsAtIndex:)
    func removeTab(at index: Int) {
        guard appleScriptTabs.indices.contains(index) else { return }
        appleScriptTabs.remove(at: index)
    }
    override func newScriptingObject(of objectClass: AnyClass, forValueForKey key: String,
                                     withContentsValue contents: Any?, properties: [String: Any]) -> Any? {
        let arguments = MainThreadScriptingProperties(contents: contents, properties: properties)
        return mainThreadScriptingObject {
            guard objectClass == CircaScriptTab.self, key == "appleScriptTabs",
                  let window, let scripting = window.scripting else { return nil }
            let value = BrowserScriptingController.decodedScriptValue(arguments.properties["URL"]) as? String ?? "about:blank"
            let draft = CircaScriptTab(id: UUID().uuidString, title: "", url: value,
                                       location: "unpinned", loading: false, space: self)
            scripting.creation = {
                guard let url = Foundation.URL(string: value) else { throw BrowserScriptError.invalidURL }
                try scripting.validateNavigation(url)
                let createdID = try await window.makeTab(url, self.id)
                await scripting.refresh()
                guard let tab = scripting.windows.first(where: { $0.id == window.id })?.appleScriptTabs.first(where: { $0.id == createdID }) else {
                    throw BrowserScriptError.unavailable
                }
                return tab
            }
            return draft
        }
    }
    override var objectSpecifier: NSScriptObjectSpecifier? {
        mainThreadSpecifier {
            guard let window, let parent = window.objectSpecifier,
                  let description = window.classDescription as? NSScriptClassDescription else { return nil }
            return NSUniqueIDSpecifier(containerClassDescription: description,
                                      containerSpecifier: parent, key: "appleScriptSpaces", uniqueID: id)
        }
    }
}

@MainActor
@objc(CircaScriptTab)
final class CircaScriptTab: NSObject {
    @objc let id: String
    weak var space: CircaScriptSpace?
    var window: CircaScriptWindow? { space?.window }
    let titleValue: String
    let urlValue: String
    @objc let location: String
    @objc let loading: Bool
    @objc var title: String { window?.canReadPrivateContent == true ? titleValue : "" }
    @objc var name: String { title }
    @objc var URL: String { window?.canReadPrivateContent == true ? urlValue : "" }
    var action: (BrowserScriptTabAction) async throws -> String? = { _ in throw BrowserScriptError.unavailable }
    init(id: String, title: String, url: String, location: String, loading: Bool, space: CircaScriptSpace) {
        self.id = id; titleValue = title; urlValue = url; self.location = location; self.loading = loading; self.space = space
    }
    override var objectSpecifier: NSScriptObjectSpecifier? {
        mainThreadSpecifier {
            guard let space, let parent = space.objectSpecifier,
                  let description = space.classDescription as? NSScriptClassDescription else { return nil }
            return NSUniqueIDSpecifier(containerClassDescription: description,
                                      containerSpecifier: parent, key: "appleScriptTabs", uniqueID: id)
        }
    }
}

private extension Array where Element == CircaScriptTab {
    func uniquedByID() -> Self { var seen: Set<String> = []; return filter { seen.insert($0.id).inserted } }
}

extension NSApplication {
    @objc var appleScriptWindows: [CircaScriptWindow] { (delegate as? OrbitApplication)?.scripting.windows ?? [] }
    @objc var appleScriptSpaces: [CircaScriptSpace] { appleScriptWindows.filter { !$0.incognito }.first?.appleScriptSpaces ?? [] }
    @objc var appleScriptTabs: [CircaScriptTab] { appleScriptWindows.flatMap(\.appleScriptTabs) }
    @objc(valueInAppleScriptWindowsWithUniqueID:)
    func scriptWindow(withID id: String) -> CircaScriptWindow? { appleScriptWindows.first { $0.id == id } }
    @objc(valueInAppleScriptSpacesWithUniqueID:)
    func scriptSpace(withID id: String) -> CircaScriptSpace? { appleScriptSpaces.first { $0.id == id } }
    @objc(valueInAppleScriptTabsWithUniqueID:)
    func scriptTab(withID id: String) -> CircaScriptTab? { appleScriptTabs.first { $0.id == id } }
    @objc(insertObject:inAppleScriptWindowsAtIndex:)
    func insertScriptWindow(_ window: CircaScriptWindow, at index: Int) {
        guard let scripting = (delegate as? OrbitApplication)?.scripting,
              !scripting.windows.contains(where: { $0.id == window.id }) else { return }
        scripting.windows.insert(window, at: max(0, min(index, scripting.windows.count)))
    }
    // NSApplication's scripting category uses these legacy default-location selectors.
    @objc(insertInAppleScriptWindows:)
    func insertScriptWindow(_ window: CircaScriptWindow) { insertScriptWindow(window, at: appleScriptWindows.count) }
    @objc(removeObjectFromAppleScriptWindowsAtIndex:)
    func removeScriptWindow(at index: Int) {
        guard let scripting = (delegate as? OrbitApplication)?.scripting, scripting.windows.indices.contains(index) else { return }
        scripting.windows.remove(at: index)
    }
    @objc(insertObject:inAppleScriptTabsAtIndex:)
    func insertScriptTab(_ tab: CircaScriptTab, at index: Int) {
        (tab.window ?? appleScriptWindows.first)?.insertTab(tab, at: index)
    }
    @objc(insertInAppleScriptTabs:)
    func insertScriptTab(_ tab: CircaScriptTab) { insertScriptTab(tab, at: appleScriptTabs.count) }
    @objc(removeObjectFromAppleScriptTabsAtIndex:)
    func removeScriptTab(at index: Int) {
        guard appleScriptTabs.indices.contains(index), let space = appleScriptTabs[index].space,
              let local = space.appleScriptTabs.firstIndex(where: { $0.id == appleScriptTabs[index].id }) else { return }
        space.removeTab(at: local)
    }
    override open func newScriptingObject(of objectClass: AnyClass, forValueForKey key: String,
                                          withContentsValue contents: Any?, properties: [String: Any]) -> Any? {
        let arguments = MainThreadScriptingProperties(contents: contents, properties: properties)
        return mainThreadScriptingObject {
            guard let scripting = (delegate as? OrbitApplication)?.scripting else { return nil }
            if objectClass == CircaScriptWindow.self, key == "appleScriptWindows" {
                let mode = BrowserScriptingController.decodedScriptValue(arguments.properties["mode"]) as? String ?? "normal"
                scripting.creation = { try await scripting.createWindow(mode) }
                return CircaScriptWindow(id: UUID().uuidString, mode: mode, scripting: scripting,
                                         isFocused: { false }, title: { "" })
            }
            guard objectClass == CircaScriptTab.self, key == "appleScriptTabs",
                  let window = scripting.windows.first else { return nil }
            return window.newScriptingObject(of: objectClass, forValueForKey: key,
                                             withContentsValue: arguments.contents, properties: arguments.properties)
        }
    }
}

// Cocoa's NSObject override is nonisolated, but its scripting entry point runs on the main thread.
private final class MainThreadScriptSpecifier: @unchecked Sendable {
    let value: NSScriptObjectSpecifier?
    init(_ value: NSScriptObjectSpecifier?) { self.value = value }
}

private func mainThreadSpecifier(_ body: @MainActor () -> NSScriptObjectSpecifier?) -> NSScriptObjectSpecifier? {
    MainActor.assumeIsolated { MainThreadScriptSpecifier(body()) }.value
}

private final class MainThreadScriptingObject: @unchecked Sendable {
    let value: Any?
    init(_ value: Any?) { self.value = value }
}

private func mainThreadScriptingObject(_ body: @MainActor () -> Any?) -> Any? {
    MainActor.assumeIsolated { MainThreadScriptingObject(body()) }.value
}

private final class MainThreadScriptingProperties: @unchecked Sendable {
    let contents: Any?
    let properties: [String: Any]
    init(contents: Any?, properties: [String: Any]) { self.contents = contents; self.properties = properties }
}
