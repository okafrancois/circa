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

@objc(CircaGetScriptCommand)
final class CircaGetScriptCommand: NSScriptCommand {
    override func execute() -> Any? {
        let reference = MainThreadScriptCommand(self)
        MainActor.assumeIsolated {
            let command = reference.value as! CircaGetScriptCommand
            scriptController()?.submit(command) { command.readValue() }
        }
        return nil
    }
    // NSGetCommand.execute packages a reply using the current event context. That context
    // has ended after suspension; evaluate the raw value and let resumeExecution package it.
    @MainActor
    func readValue() -> Any? {
        func evaluate(_ value: Any?) -> Any? {
            if let specifier = value as? NSScriptObjectSpecifier { return specifier.objectsByEvaluatingSpecifier }
            if let values = value as? [Any] { return values.map { evaluate($0) ?? NSNull() } }
            return value
        }
        return evaluate(directParameter)
    }
}

@objc(CircaCountScriptCommand)
final class CircaCountScriptCommand: NSCountCommand {
    override func execute() -> Any? {
        let reference = MainThreadScriptCommand(self)
        MainActor.assumeIsolated {
            let command = reference.value as! CircaCountScriptCommand
            scriptController()?.submit(command) { command.countValue() }
        }
        return nil
    }
    @MainActor
    func countValue() -> Any? {
        var value: Any?
        if let specifier = directParameter as? NSScriptObjectSpecifier { value = specifier.objectsByEvaluatingSpecifier }
        else { value = directParameter }
        if let code = evaluatedArguments?["ObjectClass"] as? NSNumber,
           let object = value as? NSObject,
           let description = object.classDescription as? NSScriptClassDescription,
           let key = description.key(withAppleEventCode: code.uint32Value) {
            value = object.value(forKey: key)
        }
        if let values = value as? [Any] { return values.count }
        return value == nil ? 0 : 1
    }
}

@objc(CircaSetScriptCommand)
final class CircaSetScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let reference = MainThreadScriptCommand(self)
        MainActor.assumeIsolated {
            let command = reference.value as! CircaSetScriptCommand
            scriptController()?.submit(command) { try await command.setValue() }
        }
        return nil
    }

    @MainActor
    func setValue() async throws -> Any? {
        guard let property = directParameter as? NSPropertySpecifier, property.key == "URL",
              let tab = property.container?.objectsByEvaluatingSpecifier as? CircaScriptTab,
              let value = evaluatedArguments?["Value"] as? String,
              let url = URL(string: value), url.scheme != nil else { throw BrowserScriptError.invalidURL }
        _ = try await tab.action(.navigate(url))
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
        let properties = resolvedKeyDictionary
        if createClassDescription.implementationClassName == NSStringFromClass(CircaScriptWindow.self) {
            let window = try await scripting.createWindow(properties["mode"] as? String ?? "normal")
            guard let specifier = window.objectSpecifier else { throw BrowserScriptError.unavailable }
            return specifier
        }
        guard createClassDescription.implementationClassName == NSStringFromClass(CircaScriptTab.self) else { throw BrowserScriptError.unsupported }
        var destination: Any? = (receiversSpecifier ?? directParameter as? NSScriptObjectSpecifier)?.objectsByEvaluatingSpecifier
        if let position = arguments?["Location"] as? NSPositionalSpecifier {
            position.setInsertionClassDescription(createClassDescription)
            position.evaluate()
            destination = position.insertionContainer
        } else if let location = evaluatedArguments?["Location"] { destination = location }
        let space = destination as? CircaScriptSpace
        let window = space?.window ?? destination as? CircaScriptWindow ?? scripting.windows.first
        let target: CircaScriptWindow
        if let window { target = window } else { target = try await scripting.createWindow("normal") }
        let value = properties["URL"] as? String ?? "about:blank"
        guard let url = URL(string: value), url.scheme != nil else { throw BrowserScriptError.invalidURL }
        let id = try await target.makeTab(url, space?.id)
        await scripting.refresh()
        guard let tab = scripting.windows.first(where: { $0.id == target.id })?.appleScriptTabs.first(where: { $0.id == id }) else {
            throw BrowserScriptError.unavailable
        }
        guard let specifier = tab.objectSpecifier else { throw BrowserScriptError.unavailable }
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
        let receiver = (receiversSpecifier ?? directParameter as? NSScriptObjectSpecifier)?.objectsByEvaluatingSpecifier
        let targets: [Any] = (receiver as? [Any]) ?? receiver.map { [$0] } ?? []
        let name = commandDescription.commandName.lowercased().replacingOccurrences(of: " ", with: "")
        if name == "openlocation" {
            guard let value = directParameter as? String, let url = URL(string: value), url.scheme != nil else { throw BrowserScriptError.invalidURL }
            let window: CircaScriptWindow
            if let existing = scripting.windows.first(where: { !$0.incognito }) { window = existing }
            else { window = try await scripting.createWindow("normal") }
            _ = try await window.makeTab(url, nil)
            return nil
        }
        guard !targets.isEmpty else { throw BrowserScriptError.unavailable }
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
                guard let script = evaluatedArguments?["javascript"] as? String else { throw BrowserScriptError.unsupported }
                result = try await scripting.execute(script, in: tab)
                continue
            default: throw BrowserScriptError.unsupported
            }
            _ = try await tab.action(action)
        }
        return result
    }
}
