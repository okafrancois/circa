import AppKit
import Testing
@testable import Orbit

@MainActor
private final class AdaptationOracleTarget: NSObject {
    var calls = 0
    @objc func performSyntheticAction(_ sender: Any?) { calls += 1 }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeCommandAdaptationTests {
    @Test("Disabled matching agrees with an enabled AppKit menu and never dispatches its synthetic action")
    func nativeAdaptationOracle() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let bindings: [BrowserShortcut] = [
            .init(key: "q", modifiers: .command), .init(key: "t", modifiers: .command),
            .init(key: "T", modifiers: .command), .init(key: "z", modifiers: .command), .init(key: "Z", modifiers: .command),
            .init(key: "[", modifiers: .command), .init(key: "]", modifiers: .command),
            .init(key: "\u{F702}", modifiers: [.command, .option]),
            .init(key: "\u{F703}", modifiers: [.command, .option]), .init(key: "\u{F70F}", modifiers: [])
        ]
        let matcher = BrowserKeyEquivalentMatcher(bindings: bindings)
        let samples: [(String, UInt16, NSEvent.ModifierFlags)] = [
            ("q", 12, .command), ("t", 17, .command), ("T", 17, [.command, .shift]),
            ("Z", 6, [.command, .capsLock]), ("x", 7, .command),
            ("\u{F702}", 123, [.command, .option]), ("\u{F703}", 124, [.command, .option]),
            ("\u{F70F}", 111, []), ("\u{F70F}", 111, .shift)
        ]
        for (characters, code, flags) in samples {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 1, windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            let input = try #require(BrowserShortcutEvent(event))
            for binding in bindings {
                let oracle = NSMenu()
                let target = AdaptationOracleTarget()
                let shifted = binding.modifiers.contains(.shift) && binding.key.count == 1
                    && binding.key.utf8.first.map { (97...122).contains($0) } == true
                let item = NSMenuItem(title: "Synthetic oracle", action: #selector(AdaptationOracleTarget.performSyntheticAction(_:)),
                                      keyEquivalent: shifted ? binding.key.uppercased() : binding.key)
                item.keyEquivalentModifierMask = shifted ? binding.modifiers.subtracting(.shift) : binding.modifiers
                item.allowsAutomaticKeyEquivalentLocalization = OrbitMenuTree.allowsKeyEquivalentLocalization
                item.allowsAutomaticKeyEquivalentMirroring = OrbitMenuTree.allowsKeyEquivalentMirroring
                item.target = target
                oracle.addItem(item)
                let expected = oracle.performKeyEquivalent(with: event)
                #expect(matcher.matches(binding, input: input, strictShift: false) == expected)
                #expect(target.calls == (expected ? 1 : 0))
            }
            #expect(input.nativeMatches.bindings != nil)
        }
        #expect(matcher.unexpectedActionCount == 0)
        let caps = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .capsLock],
            timestamp: 1, windowNumber: 0, context: nil, characters: "Z", charactersIgnoringModifiers: "Z", isARepeat: false, keyCode: 6))
        let input = try #require(BrowserShortcutEvent(caps))
        #expect(matcher.matches(.init(key: "z", modifiers: .command), input: input))
        #expect(!matcher.matches(.init(key: "Z", modifiers: .command), input: input))
        withExtendedLifetime(caps) { }
    }
    @Test("A failed native lookup self-check falls back to semantic matching without disabling shortcuts")
    func unsupportedNativeLookupFallback() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var validations = 0
        let binding = BrowserShortcut(key: "t", modifiers: .command)
        let matcher = BrowserKeyEquivalentMatcher(bindings: [binding], lookupValidation: {
            validations += 1
            return false
        })
        #expect(matcher.nativeLookupSupported == false)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 1, windowNumber: 0, context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        let input = try #require(BrowserShortcutEvent(event))
        #expect(matcher.matches(binding, input: input))
        #expect(!matcher.matches(.init(key: "q", modifiers: .command), input: input))
        #expect(matcher.matches(binding, input: input))
        #expect(validations == 1)
        #expect(input.nativeMatches.bindings == nil)
        #expect(matcher.unexpectedActionCount == 0)
    }

    @Test("A layout without Latin q safely selects semantic fallback and skips modifier events")
    func nonLatinLayoutFallback() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var visited: [UInt16] = []
        let binding = BrowserShortcut(key: "t", modifiers: .command)
        let matcher = BrowserKeyEquivalentMatcher(bindings: [binding], validationLayoutEvent: {
            BrowserKeyEquivalentMatcher.layoutEvent(producing: "q", flags: .maskCommand) { code in
                visited.append(code)
                // Inject a non-Latin layout without changing the user's input source. Also
                // return a non-key event outside the known modifier range to test the type guard.
                return NSEvent.keyEvent(with: code == 10 ? .flagsChanged : .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: "я", charactersIgnoringModifiers: "я", isARepeat: false, keyCode: code)
            }
        })
        #expect(matcher.nativeLookupSupported == false)
        #expect(visited.count == 118)
        #expect(!visited.contains { (54...63).contains($0) })
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 1, windowNumber: 0, context: nil, characters: "t", charactersIgnoringModifiers: "t",
            isARepeat: false, keyCode: 17))
        #expect(matcher.matches(binding, input: try #require(BrowserShortcutEvent(event))))
        #expect(matcher.unexpectedActionCount == 0)
    }

    @Test("Searching for an absent hardware character skips modifier events past keycode 54")
    func absentHardwareCharacterSearch() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        // No layout types this scalar: this exercises the actual CGEvent conversion at code 54.
        #expect(BrowserKeyEquivalentMatcher.layoutEvent(producing: "\u{10FFFF}", flags: .maskCommand) == nil)
    }

}
}
