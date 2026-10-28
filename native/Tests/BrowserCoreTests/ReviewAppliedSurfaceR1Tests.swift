import Foundation
import Testing
@testable import BrowserCore

@Suite("Independent applied surface R1 boundaries")
struct ReviewAppliedSurfaceR1Tests {
    @Test("Version four absent and null surfaces stay nil; unknown keys do not erase existing theme fields")
    func oldAndUnknownFields() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Mint", profileID: profile)
        let theme = BrowserSpaceTheme.composed(colors: [.init(hex: 0x219978)], intensity: 0.37, noise: 0.19)
        try await store.setSpaceTheme(theme, for: space)
        let document = await store.sessionDocument()
        var json = try #require(JSONSerialization.jsonObject(with: document.encoded()) as? [String: Any])
        #expect(json["version"] as? Int == 4)
        var spaces = try #require(json["spaces"] as? [[String: Any]])
        var fields = try #require(spaces[0]["theme"] as? [String: Any])
        #expect(fields["surface"] == nil)
        fields["surface"] = NSNull()
        fields["futureThemeField"] = ["invented": true]
        spaces[0]["theme"] = fields
        json["spaces"] = spaces
        let restored = try BrowserSessionDocument.decode(JSONSerialization.data(withJSONObject: json))
        #expect(restored == document)
        let encoded = try #require(JSONSerialization.jsonObject(with: restored.encoded()) as? [String: Any])
        let encodedSpaces = try #require(encoded["spaces"] as? [[String: Any]])
        #expect((encodedSpaces[0]["theme"] as? [String: Any])?["surface"] == nil)
    }

    @Test("Unknown material and malformed fields refuse the session rather than silently dropping themes")
    func corruptSurfaceBoundary() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Mint", profileID: profile)
        try await store.setSpaceTheme(BrowserSpaceThemePresets.default, for: space)
        let before = await store.sessionDocument()
        for surface: Any in [
            ["material": "futureMaterial", "transparency": 0.5],
            ["material": "frosted", "transparency": "0.5"],
            ["material": "frosted", "transparency": -Double.leastNonzeroMagnitude],
            ["material": "frosted", "transparency": 1.0.nextUp],
            ["material": "solid"], ["transparency": 0.5], "frosted"
        ] {
            var json = try #require(JSONSerialization.jsonObject(with: before.encoded()) as? [String: Any])
            var spaces = try #require(json["spaces"] as? [[String: Any]])
            var theme = try #require(spaces[0]["theme"] as? [String: Any])
            theme["surface"] = surface
            spaces[0]["theme"] = theme
            json["spaces"] = spaces
            let data = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: (any Error).self) { try BrowserSessionDocument.decode(data) }
            #expect(await store.sessionDocument() == before)
        }
    }

    @Test("Independent actor field writes preserve new colors and concurrent material fields; undo conflicts atomically")
    func atomicFieldEdits() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Mint", profileID: profile)
        let stale = BrowserSpaceThemePresets.default
        let fresh = BrowserSpaceTheme.composed(colors: [.init(hex: 0x981177)], intensity: 0.13, noise: 0.3)
        try await store.setSpaceTheme(fresh, for: space)
        let first = try await store.setSpaceThemeSurface(for: space, profileID: profile, material: .liquidGlass, fallback: stale)
        try await store.setSpaceThemeSurface(for: space, profileID: profile, transparency: 0.91, fallback: stale)
        var result = try #require(try await store.spaceTheme(space))
        #expect(result.surface == .init(material: .liquidGlass, transparency: 0.91))
        result.surface = nil
        #expect(result == fresh)
        let before = await store.sessionDocument()
        await #expect(throws: BrowserSpaceThemeError.conflict) { try await store.applySpaceThemeChange(first.inverse) }
        #expect(await store.sessionDocument() == before)
    }
}
