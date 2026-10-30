import Foundation
import Testing
@testable import BrowserCore

struct ThemeFrostModelTests {
    @Test("Missing Frost decodes off and old schemas ignore the new field")
    func backwardRoundTrip() throws {
        let original = BrowserSpaceThemePresets.default
        #expect(!original.frost)
        struct LegacyTheme: Codable, Equatable {
            let presetID: String?
            let mode: BrowserSpaceTheme.Mode
            let colors: [BrowserThemeColor]
            let intensity: Double
            let noise: Double
            let light: BrowserSpaceTheme.Gradient
            let dark: BrowserSpaceTheme.Gradient
        }
        let old = try JSONDecoder().decode(LegacyTheme.self, from: JSONEncoder().encode(original))
        let restored = try JSONDecoder().decode(BrowserSpaceTheme.self, from: JSONEncoder().encode(old))
        #expect(restored == original)
        var enabled = restored
        enabled.frost = true
        let legacy = try JSONDecoder().decode(LegacyTheme.self, from: JSONEncoder().encode(enabled))
        #expect(legacy == old)
        #expect(try JSONDecoder().decode(BrowserSpaceTheme.self, from: JSONEncoder().encode(enabled)) == enabled)
        #expect(try JSONDecoder().decode(BrowserSpaceTheme.self, from: JSONEncoder().encode(legacy)).frost == false)
    }

    @Test("Theme sync keeps Frost on and off through the existing projection and wire rules")
    func sync() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        var replica = BrowserSyncReplica()
        for enabled in [true, false] {
            var theme = BrowserSpaceThemePresets.default
            theme.frost = enabled
            try await store.setSpaceTheme(theme, for: space)
            let session = await store.sessionDocument()
            try replica.capture(BrowserSyncMapping.project(session: session, settings: .init()))
            let decoded = try JSONDecoder().decode(BrowserSyncReplica.self, from: BrowserSyncReplica.encodeValue(replica))
            let result = try BrowserSyncMapping.materialize(decoded.visible, local: session, settings: .init())
            #expect(result.spaces.first?.theme == theme)
            #expect(try BrowserSessionDocument.decode(session.encoded()).spaces.first?.theme == theme)
        }
    }

    @Test("Color recomposition retains the independent Frost flag")
    func recomposition() {
        var theme = BrowserSpaceTheme.radial(colors: [.init(hex: 0xFF5A5F)])
        theme.frost = true
        #expect(theme.recomposed(intensity: 0.2).frost)
        #expect(theme.recomposed(mode: .dark).frost)
        #expect(theme.recomposed(colors: []).frost)
        #expect(BrowserSpaceThemePresets.families.flatMap(\.swatches).allSatisfy { !BrowserSpaceTheme.composed(colors: [$0]).frost })
    }
}
