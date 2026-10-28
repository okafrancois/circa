import AppKit

/// Event-level trace of the shortcut path (monitor, page/menu fallback, registry dispatch) for
/// hidden routing tests and `--key-diagnostics` physical-keyboard validation. It records event
/// types, key codes, modifier masks, responder classes and command IDs only: never characters,
/// field contents or page data. Ordinary typing (including Shift/Option characters) is never
/// recorded, since a key-code sequence would reveal the typed text.
/// One trace per command system (owned by its registry), so concurrent hidden tests never share it.
@MainActor
final class BrowserKeyRoutingTrace {
    var sink: ((String) -> Void)?

    init(sink: ((String) -> Void)? = ProcessInfo.processInfo.arguments.contains("--key-diagnostics")
            ? { line in print(line); fflush(stdout) } : nil) {
        self.sink = sink
    }

    func record(_ stage: String, _ event: NSEvent?, responder: NSResponder? = nil, _ detail: @autoclosure () -> String = "") {
        guard let sink, event.map(Self.isTraceable) ?? true else { return }
        var line = "orbit-key stage=\(stage)"
        if let event {
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            line += " type=\(event.type.rawValue) code=\(event.keyCode) mods=\(flags.rawValue >> 17)"
            if event.type == .keyDown { line += " repeat=\(event.isARepeat)" }
        }
        if let responder { line += " responder=\(String(describing: type(of: responder)))" }
        let detail = detail()
        if !detail.isEmpty { line += " \(detail)" }
        sink(line)
    }

    /// Command/Control chords, Escape, Tab and function/arrow keys: shortcut candidates only.
    static func isTraceable(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp else { return false }
        if !event.modifierFlags.intersection([.command, .control]).isEmpty { return true }
        if event.keyCode == 53 || event.keyCode == 48 { return true }
        return event.specialKey != nil && event.charactersIgnoringModifiers?.unicodeScalars.first
            .map { (0xF700...0xF8FF).contains($0.value) } == true
    }
}
