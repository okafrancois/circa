import AppKit
import Testing
@testable import Orbit

/// Uses only baseline APIs so the same assertion can run against the old source unchanged.
extension NativeWebKitTests {
@Suite("Space symbol control availability", .serialized)
@MainActor
struct SpaceSymbolControlAvailabilityTests {
    @Test("Icons is a searchable native grid rather than a disabled placeholder")
    func availableControl() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let picker = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
        picker.loadViewIfNeeded()
        picker.modes.selectedSegment = SpaceIconPicker.Mode.icons.rawValue
        _ = picker.modes.sendAction(picker.modes.action, to: picker.modes.target)
        #expect(picker.search.isEnabled)
        #expect(!picker.visibleItems.isEmpty && picker.visibleItems.allSatisfy { $0.emoji.isEmpty })
    }
}
}
