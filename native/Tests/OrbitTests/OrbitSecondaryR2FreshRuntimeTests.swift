import AppKit
import Darwin
import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Fresh R2 runtime rejection review", .serialized)
@MainActor
struct OrbitSecondaryR2FreshRuntimeTests {
    @Test("Invalid drafts never publish callbacks, motion or runtime state")
    func invalidDraftsAreAtomic() async throws {
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("OrbitR2Runtime-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let store = try BrowserSettingsStore(destination: file)
        try await store.setReducedMotion(.reduce)
        let previousMotion = OrbitMotionPreferences.overrideReducedMotion
        defer { OrbitMotionPreferences.overrideReducedMotion = previousMotion }
        let runtime = BrowserSettingsRuntime(store: store)
        await runtime.refresh()
        let before = runtime.document
        let bytes = try Data(contentsOf: file)
        let motion = OrbitMotionPreferences.overrideReducedMotion
        var callbacks = 0
        runtime.onChange = { callbacks += 1 }
        for value in [Double.nan, .infinity, -.infinity, -0.001, 1.001] {
            var invalid = BrowserSecondaryAppearanceDraft()
            invalid.material = .liquidGlass
            invalid.transparency = value
            await #expect(throws: BrowserSettingsError.invalidSecondaryAppearanceDraft) {
                try await runtime.setSecondaryAppearanceDraft(invalid)
            }
            #expect(runtime.document == before)
            #expect(await store.snapshot() == before)
            #expect(try Data(contentsOf: file) == bytes)
            #expect(callbacks == 0)
            #expect(OrbitMotionPreferences.overrideReducedMotion == motion)
        }
    }
}
}
