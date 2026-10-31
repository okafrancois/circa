import AppKit

// Cocoa invokes these commands on the main thread. Suspended work stays on MainActor;
// Sendable permits retaining the command across that executor’s asynchronous suspension.
private final class MainThreadScriptCommand: @unchecked Sendable {
    let value: NSScriptCommand
    init(_ value: NSScriptCommand) { self.value = value }
}

private func scriptController() -> BrowserScriptingController? {
    MainActor.assumeIsolated { (NSApp.delegate as? OrbitApplication)?.scripting }
}

/// Reads wait for the refreshed inventory, then run Cocoa's own get, which packages every
/// property, element, record and missing value as a descriptor of its dictionary type.
@objc(CircaGetScriptCommand)
final class CircaGetScriptCommand: NSGetCommand {
    override func execute() -> Any? {
        let reference = MainThreadScriptCommand(self)
        MainActor.assumeIsolated {
            let command = reference.value as! CircaGetScriptCommand
            scriptController()?.submit(command) { try command.cocoaValue() }
        }
        return nil
    }

    /// Cocoa raises while packaging a value it cannot reference. The event handler catches that
    /// for synchronous commands, a resumed task cannot, so unpackageable values become errors.
    @MainActor
    func cocoaValue() throws -> Any? {
        guard let receivers = receiversSpecifier else { throw BrowserScriptError.unsupported }
        guard Self.canPackage(receivers.objectsByEvaluatingSpecifier) else { throw BrowserScriptError.unavailable }
        return super.execute()
    }

    @MainActor
    static func canPackage(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull, is String, is NSNumber, is NSAppleEventDescriptor, is NSScriptObjectSpecifier: return true
        case let values as [Any]: return values.allSatisfy(canPackage)
        case let record as [AnyHashable: Any]: return record.values.allSatisfy(canPackage)
        case is NSApplication: return false
        case let object as NSObject: return object.objectSpecifier != nil
        default: return false
        }
    }
}

/// Counts the evaluated references, or the elements of class "each" of one object, with KVC
/// reads only: nothing here raises inside the resumed task.
@objc(CircaCountScriptCommand)
final class CircaCountScriptCommand: NSCountCommand {
    override func execute() -> Any? {
        let reference = MainThreadScriptCommand(self)
        MainActor.assumeIsolated {
            let command = reference.value as! CircaCountScriptCommand
            scriptController()?.submit(command) { try command.countValue() }
        }
        return nil
    }

    @MainActor
    func countValue() throws -> Int {
        let target: Any? = receiversSpecifier.map { $0.objectsByEvaluatingSpecifier } ?? NSApp
        if let values = target as? [Any] { return values.count }
        guard let object = target as? NSObject else { return 0 }
        guard let code = (evaluatedArguments?["ObjectClass"] as? NSNumber)?.uint32Value else { return 1 }
        guard let description = object.classDescription as? NSScriptClassDescription,
              let key = description.key(withAppleEventCode: code), description.toManyRelationshipKeys.contains(key) else {
            throw BrowserScriptError.unsupported
        }
        return (object.value(forKey: key) as? [Any])?.count ?? 0
    }
}

/// Tab URLs are the only writable property; Cocoa splits the reference into the
/// receiving tabs and the property key before execution.
@objc(CircaSetScriptCommand)
final class CircaSetScriptCommand: NSSetCommand {
    override func execute() -> Any? {
        let reference = MainThreadScriptCommand(self)
        MainActor.assumeIsolated {
            let command = reference.value as! CircaSetScriptCommand
            scriptController()?.submit(command) { try await command.setValue() }
        }
        return nil
    }

    @MainActor
    func setValue() async throws -> Any? {
        // The key specifier is only assigned together with the receivers.
        guard let receivers = receiversSpecifier else { throw BrowserScriptError.unavailable }
        guard keySpecifier.key == "URL" else { throw BrowserScriptError.unsupported }
        let evaluated = receivers.objectsByEvaluatingSpecifier
        let tabs = (evaluated as? [Any] ?? evaluated.map { [$0] } ?? []).compactMap { $0 as? CircaScriptTab }
        guard !tabs.isEmpty else { throw BrowserScriptError.unavailable }
        guard let value = BrowserScriptingController.decodedScriptValue(evaluatedArguments?["Value"]) as? String,
              let url = URL(string: value), url.scheme != nil else { throw BrowserScriptError.invalidURL }
        for tab in tabs { _ = try await tab.action(.navigate(url)) }
        return nil
    }
}

@objc(CircaMakeScriptCommand)
final class CircaMakeScriptCommand: NSCreateCommand {
    override func execute() -> Any? {
        let reference = MainThreadScriptCommand(self)
        MainActor.assumeIsolated {
            let command = reference.value as! CircaMakeScriptCommand
            guard let scripting = scriptController() else { return }
            scripting.submit(command) { try await command.makeValue(scripting) }
        }
        return nil
    }

    @MainActor
    func makeValue(_ scripting: BrowserScriptingController) async throws -> NSScriptObjectSpecifier {
        if arguments?["Location"] == nil, scripting.windows.isEmpty,
           createClassDescription.implementationClassName == NSStringFromClass(CircaScriptTab.self) {
            _ = try await scripting.createWindow("normal")
        }
        scripting.creation = nil
        defer { scripting.creation = nil }
        // Cocoa resolves the insertion location, calls the container's factory, then its
        // ordered KVC accessor. Session creation must settle before packaging the reply.
        let result = super.performDefaultImplementation()
        let draft = (result as? NSScriptObjectSpecifier)?.objectsByEvaluatingSpecifier ?? result
        // The provisional inventory object exists only for Cocoa's synchronous insertion;
        // it must not survive a rejected session command or appear in the next inventory.
        if let tab = draft as? CircaScriptTab, let space = tab.space,
           let index = space.appleScriptTabs.firstIndex(where: { $0 === tab }) {
            space.removeTab(at: index)
        } else if let window = draft as? CircaScriptWindow,
                  let index = scripting.windows.firstIndex(where: { $0 === window }) {
            NSApp.removeScriptWindow(at: index)
        }
        guard scriptErrorNumber == 0, let create = scripting.creation else { throw BrowserScriptError.unavailable }
        let object = try await create()
        guard let specifier = object.objectSpecifier else { throw BrowserScriptError.unavailable }
        return specifier
    }
}

@objc(CircaActionScriptCommand)
final class CircaActionScriptCommand: NSScriptCommand {
    override func execute() -> Any? {
        let reference = MainThreadScriptCommand(self)
        MainActor.assumeIsolated {
            let command = reference.value as! CircaActionScriptCommand
            guard let scripting = scriptController() else { return }
            scripting.submit(command) { try await command.actionValue(scripting) }
        }
        return nil
    }

    @MainActor
    func actionValue(_ scripting: BrowserScriptingController) async throws -> Any? {
        let receiver = receiversSpecifier?.objectsByEvaluatingSpecifier
        let targets: [Any] = (receiver as? [Any]) ?? receiver.map { [$0] } ?? []
        guard !targets.isEmpty else { throw BrowserScriptError.unavailable }
        let name = commandDescription.commandName.lowercased().replacingOccurrences(of: " ", with: "")
        var result: String?
        for target in targets {
            if let space = target as? CircaScriptSpace, name == "focus" { try await space.focus(); continue }
            if let window = target as? CircaScriptWindow {
                if name == "focus" { window.focus(); continue }
                if name == "close" { window.close(); continue }
            }
            guard let tab = target as? CircaScriptTab else { throw BrowserScriptError.unsupported }
            let action: BrowserScriptTabAction
            switch name {
            case "select", "focus": action = .select
            case "close": action = .close
            case "reload": action = .reload
            case "goback": action = .back
            case "goforward": action = .forward
            case "stop": action = .stop
            case "execute":
                guard let script = BrowserScriptingController.decodedScriptValue(evaluatedArguments?["javascript"]) as? String else { throw BrowserScriptError.unsupported }
                result = try await scripting.execute(script, in: tab)
                continue
            default: throw BrowserScriptError.unsupported
            }
            _ = try await tab.action(action)
        }
        return result
    }
}
