import AppKit
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
            targetWindowID = explicitWindow(in: command.receiversSpecifier ?? command.directParameter as? NSScriptObjectSpecifier)
            do { command.resumeExecution(withResult: Self.replyValue(try await action())) }
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

    init(id: String, mode: String, scripting: BrowserScriptingController, isFocused: @escaping () -> Bool,
         title: @escaping () -> String) {
        self.id = id; self.mode = mode; self.scripting = scripting; self.isFocused = isFocused; titleValue = title
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
    init(id: String, title: String, window: CircaScriptWindow) { self.id = id; self.title = title; self.window = window }
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
}

// Cocoa's NSObject override is nonisolated, but its scripting entry point runs on the main thread.
private final class MainThreadScriptSpecifier: @unchecked Sendable {
    let value: NSScriptObjectSpecifier?
    init(_ value: NSScriptObjectSpecifier?) { self.value = value }
}

private func mainThreadSpecifier(_ body: @MainActor () -> NSScriptObjectSpecifier?) -> NSScriptObjectSpecifier? {
    MainActor.assumeIsolated { MainThreadScriptSpecifier(body()) }.value
}
