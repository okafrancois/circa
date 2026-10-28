@testable import BrowserCore
import Darwin
import Foundation
import Testing

// Space themes: per-Space theme model, session version 4, undo replays and the import bridge.

private func close(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }

/// Components of two colours agree within `tolerance` in 0…255 units (sRGB).
private func near(_ a: BrowserThemeColor, _ hex: UInt32, _ tolerance: Double = 2.5) -> Bool {
    let c = a.sRGB, e = BrowserThemeColor(hex: hex)
    return close(c.red * 255, e.red * 255, tolerance) && close(c.green * 255, e.green * 255, tolerance)
        && close(c.blue * 255, e.blue * 255, tolerance)
}

private struct ThemeFixture {
    let store = BrowserStore()
    var profile = ProfileID()
    var other = ProfileID()
    var home = SpaceID()
    var work = SpaceID()

    static func make() async throws -> ThemeFixture {
        var fixture = ThemeFixture()
        fixture.profile = await fixture.store.createProfile(name: "Synthetic")
        fixture.other = await fixture.store.createProfile(name: "Other")
        fixture.home = try await fixture.store.createSpace(name: "Home", profileID: fixture.profile)
        fixture.work = try await fixture.store.createSpace(name: "Work", profileID: fixture.profile)
        _ = try await fixture.store.createSpace(name: "Elsewhere", profileID: fixture.other)
        return fixture
    }
}

private let mauve = BrowserThemeColor(hex: 0xA88EAC)
private let coral = BrowserThemeColor(hex: 0xF25E6B)

/// Rewrites encoded session JSON (sorted keys) with `change`.
private func rewriting(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    change(&object)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

@Suite("Space themes — model and session version 4")
struct BrowserSpaceThemeModelTests {
    @Test("Version 4 round-trips Space themes and the import record; renames and reassignment keep them")
    func roundTrip() async throws {
        let fixture = try await ThemeFixture.make()
        let theme = BrowserSpaceTheme.composed(colors: [mauve, coral], intensity: 0.6, noise: 0.25, mode: .dark)
        try await fixture.store.setSpaceTheme(theme, for: fixture.home)
        try await fixture.store.renameSpace(fixture.home, name: "Renamed")
        #expect(try await fixture.store.spaceTheme(fixture.home) == theme)
        let encoded = try await fixture.store.sessionDocument().encoded()
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"version\":4"))
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"themeImports\":[]"))
        let decoded = try BrowserSessionDocument.decode(encoded)
        #expect(decoded.spaces.first { $0.id == fixture.home }?.theme == theme)
        #expect(decoded.spaces.first { $0.id == fixture.work }?.theme == nil)
        let restored = try BrowserStore(restoring: decoded)
        #expect(await restored.catalogSnapshot().spaces.first { $0.id == fixture.home }?.theme == theme)
        #expect(try await restored.sessionDocument().encoded() == encoded)
        // A Space reassigned to another profile keeps its appearance (it belongs to the Space).
        try await fixture.store.assignSettingsSpace(fixture.home, to: fixture.other)
        #expect(try await fixture.store.spaceTheme(fixture.home) == theme)
    }

    @Test("A version 3 document migrates losslessly; stray v3 theme fields are not part of its schema")
    func versionThreeMigration() async throws {
        let fixture = try await ThemeFixture.make()
        let window = try await fixture.store.createWindow(activeSpaceID: fixture.home)
        _ = try await fixture.store.openTab(url: URL(string: "https://themes.test/a")!,
                                           from: fixture.store.captureContext(in: window), activate: true)
        let current = try await fixture.store.sessionDocument().encoded()
        let versionThree = try rewriting(current) { object in
            object["version"] = 3
            object["themeImports"] = nil
        }
        #expect(!String(decoding: versionThree, as: UTF8.self).contains("themeImports"))
        let migrated = try BrowserSessionDocument.decode(versionThree)
        #expect(migrated.version == 4 && migrated.themeImports.isEmpty)
        #expect(migrated.spaces.allSatisfy { $0.theme == nil })
        #expect(try migrated.encoded() == current, "every version 3 field survives unchanged")
        // A theme key in a version 3 document is dropped, not trusted.
        let theme = BrowserSpaceTheme.composed(colors: [coral])
        let themedSpace = try JSONSerialization.jsonObject(with: JSONEncoder().encode(theme))
        let stray = try rewriting(versionThree) { object in
            var spaces = object["spaces"] as! [[String: Any]]
            spaces[0]["theme"] = themedSpace
            object["spaces"] = spaces
        }
        #expect(try BrowserSessionDocument.decode(stray).spaces.allSatisfy { $0.theme == nil })
    }

    @Test("Version 4 must declare its import record; later versions are refused by decode and file store")
    func versionGuards() async throws {
        let fixture = try await ThemeFixture.make()
        let current = try await fixture.store.sessionDocument().encoded()
        let missing = try rewriting(current) { $0["themeImports"] = nil }
        #expect(throws: DecodingError.self) { try BrowserSessionDocument.decode(missing) }
        let future = try rewriting(current) { $0["version"] = 5 }
        #expect(throws: BrowserSessionError.unsupportedVersion) { try BrowserSessionDocument.decode(future) }
        // Canonical synthetic root: the system temporary alias is itself a symlink.
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("ThemesV5-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        try future.write(to: file)
        #expect(throws: BrowserSessionError.unsupportedVersion) { try BrowserSessionFileStore().load(from: file) }
        #expect(try Data(contentsOf: file) == future, "a future file is never rewritten")
    }

    @Test("Out-of-bounds themes and import records are rejected before any mutation")
    func validation() async throws {
        let fixture = try await ThemeFixture.make()
        var tooMany = BrowserSpaceTheme.composed(colors: [mauve])
        tooMany.light.stops = Array(repeating: mauve, count: 4)
        var notFinite = BrowserSpaceTheme.composed(colors: [mauve])
        notFinite.intensity = .nan
        var badRange = BrowserSpaceTheme.composed(colors: [mauve])
        badRange.dark.start = 0.8
        badRange.dark.end = 0.2
        var badAngle = BrowserSpaceTheme.composed(colors: [mauve])
        badAngle.light.angleDegrees = 360
        var badPreset = BrowserSpaceTheme.composed(colors: [mauve])
        badPreset.presetID = "Brand 1"
        var badColor = BrowserSpaceTheme.composed(colors: [mauve])
        badColor.colors = [BrowserThemeColor(red: 1.5, green: 0, blue: 0)]
        for invalid in [tooMany, notFinite, badRange, badAngle, badPreset, badColor] {
            #expect(!invalid.isValid)
            await #expect(throws: BrowserSessionError.invalidSpaceTheme) {
                try await fixture.store.setSpaceTheme(invalid, for: fixture.home)
            }
        }
        #expect(try await fixture.store.spaceTheme(fixture.home) == nil)
        let document = await fixture.store.sessionDocument()
        var spaces = document.spaces
        spaces[0].theme = tooMany
        let invalidTheme = BrowserSessionDocument(profiles: document.profiles, spaces: spaces, windows: document.windows,
                                                  tabs: document.tabs, organization: document.organization)
        #expect(throws: BrowserSessionError.invalidSpaceTheme) { try invalidTheme.encoded() }
        let unknown = BrowserSessionDocument(profiles: document.profiles, spaces: document.spaces, windows: document.windows,
                                             tabs: document.tabs, organization: document.organization, themeImports: [SpaceID()])
        #expect(throws: BrowserSessionError.spaceMissing) { try unknown.encoded() }
        let duplicate = BrowserSessionDocument(profiles: document.profiles, spaces: document.spaces, windows: document.windows,
                                               tabs: document.tabs, organization: document.organization,
                                               themeImports: [fixture.home, fixture.home])
        #expect(throws: BrowserSessionError.duplicateIdentity) { try duplicate.encoded() }
    }

    @Test("Theme changes replay as undo and redo only while unchanged and within the recorded profile")
    func undoReplays() async throws {
        let fixture = try await ThemeFixture.make()
        let first = BrowserSpaceTheme.composed(colors: [mauve])
        let second = BrowserSpaceTheme.composed(colors: [coral], mode: .light)
        let initial = try await fixture.store.setSpaceTheme(first, for: fixture.home, profileID: fixture.profile)
        #expect(initial.before == nil && initial.after == first && initial.profileID == fixture.profile)
        let change = try await fixture.store.setSpaceTheme(second, for: fixture.home)
        try await fixture.store.applySpaceThemeChange(change.inverse)
        #expect(try await fixture.store.spaceTheme(fixture.home) == first)
        await #expect(throws: BrowserSpaceThemeError.conflict) { try await fixture.store.applySpaceThemeChange(change.inverse) }
        try await fixture.store.applySpaceThemeChange(change)
        #expect(try await fixture.store.spaceTheme(fixture.home) == second)
        // The theme moved on since `initial`: its undo would overwrite a newer choice.
        await #expect(throws: BrowserSpaceThemeError.conflict) { try await fixture.store.applySpaceThemeChange(initial.inverse) }
        #expect(try await fixture.store.spaceTheme(fixture.home) == second)
        // An editor opened under another profile cannot write; a stale profile cannot replay.
        await #expect(throws: BrowserSpaceThemeError.conflict) {
            try await fixture.store.setSpaceTheme(first, for: fixture.home, profileID: fixture.other)
        }
        let workChange = try await fixture.store.setSpaceTheme(first, for: fixture.work)
        try await fixture.store.assignSettingsSpace(fixture.work, to: fixture.other)
        await #expect(throws: BrowserSpaceThemeError.conflict) { try await fixture.store.applySpaceThemeChange(workChange.inverse) }
        #expect(try await fixture.store.spaceTheme(fixture.work) == first)
        await #expect(throws: BrowserStoreError.spaceMissing) { try await fixture.store.setSpaceTheme(first, for: SpaceID()) }
        // Clearing returns the Space to "never themed".
        let cleared = try await fixture.store.setSpaceTheme(nil, for: fixture.home)
        #expect(cleared.before == second && cleared.after == nil)
        #expect(try await fixture.store.spaceTheme(fixture.home) == nil)
    }

    @Test("A theme edit publishes one organization change so every window re-captures its catalog")
    func publication() async throws {
        let fixture = try await ThemeFixture.make()
        let before = await fixture.store.organizationRevision
        let theme = BrowserSpaceTheme.composed(colors: [mauve])
        try await fixture.store.setSpaceTheme(theme, for: fixture.home)
        #expect(await fixture.store.organizationRevision == before &+ 1)
        try await fixture.store.setSpaceTheme(theme, for: fixture.home)
        #expect(await fixture.store.organizationRevision == before &+ 1, "an unchanged theme publishes nothing")
    }

    @Test("Recovered profile removals reject theme writes without recreating their Spaces")
    func profileQuarantine() async throws {
        let fixture = try await ThemeFixture.make()
        let space = try #require(await fixture.store.catalogSnapshot().spaces.first { $0.profileID == fixture.other }?.id)
        await fixture.store.recoverSettingsProfileRemoval(fixture.other)
        await #expect(throws: BrowserStoreError.spaceMissing) {
            try await fixture.store.setSpaceTheme(.composed(colors: [mauve]), for: space)
        }
    }
}

@Suite("Space themes — composition, presets and accent rule")
struct BrowserSpaceThemeCompositionTests {
    @Test("The theme rule preserves the default Space frame and first dark stop")
    func calibration() {
        #expect(near(BrowserSpaceTheme.lightStop(for: mauve, intensity: BrowserSpaceTheme.defaultIntensity), 0xAA99AC, 3))
        // : the default Space's #D9DBF5 has the dark stop #252538.
        #expect(near(BrowserSpaceTheme.darkStop(for: BrowserThemeColor(hex: 0xD9DBF5), intensity: 1), 0x252538, 4))
        let one = BrowserSpaceTheme.composed(colors: [mauve])
        #expect(one.light.stops.count == 1 && one.dark.stops.count == 1 && one.isValid)
        #expect(one.light.angleDegrees == 43 && one.light.start == 0 && one.light.end == 1)
        let three = BrowserSpaceTheme.composed(colors: [mauve, coral, mauve, coral], intensity: 4, noise: -1)
        #expect(three.colors.count == 3 && three.intensity == 1 && three.noise == 0 && three.isValid)
        // Intensity scales only the saturation in light; brightness is kept.
        let pale = BrowserSpaceTheme.lightStop(for: coral, intensity: 0)
        #expect(close(pale.hsb.saturation, 0, 1e-9) && close(pale.hsb.brightness, coral.hsb.brightness, 1e-9))
    }

    @Test("No picked colour gives the default Space theme; mode changes keep designed variants")
    func defaultTheme() {
        let none = BrowserSpaceTheme.composed(colors: [], mode: .dark)
        var expected = BrowserSpaceThemePresets.default
        expected.mode = .dark
        #expect(none == expected)
        let preset = BrowserSpaceThemePresets.default
        #expect(preset.light.stops == [BrowserThemeColor(hex: 0xD9DBF5), BrowserThemeColor(hex: 0xF3E5E5)])
        #expect(preset.dark.stops == [BrowserThemeColor(hex: 0x252538), BrowserThemeColor(hex: 0x352337)])
        #expect(close(preset.light.start, 20 / 1753.02, 1e-4) && close(preset.dark.end, 1380 / 1753.02, 1e-4))
        #expect(preset.recomposed(mode: .light).light == preset.light)
        #expect(preset.recomposed(colors: [mauve]).colors == [mauve])
    }

    @Test("Display P3 swatches convert through linear light (Brand 9 is #666789)")
    func displayP3() {
        let brand = BrowserSpaceThemePresets.brand.swatches
        #expect(near(brand[8], 0x666789, 2))
        #expect(brand[8].hexString == brand[8].sRGB.hexString)
        // Out-of-gamut P3 green is clamped into sRGB.
        let green = brand[6].sRGB
        #expect([green.red, green.green, green.blue].allSatisfy { (0...1).contains($0) })
        #expect(BrowserThemeColor(hexString: "#a88eac") == mauve && BrowserThemeColor(hexString: "a88eac") == nil)
        let roundTrip = BrowserThemeColor(hue: 292.0 / 360, saturation: 0.174, brightness: 0.675)
        #expect(close(roundTrip.hsb.hue, 292.0 / 360, 1e-9) && close(roundTrip.hsb.saturation, 0.174, 1e-9))
    }

    @Test("Four swatch families of nine match the declared swatches")
    func presetsMatchTokens() throws {
        let tokens = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/space-theme-swatches.txt")
        let text = try String(contentsOf: tokens, encoding: .utf8)
        for family in BrowserSpaceThemePresets.families {
            #expect(family.swatches.count == 9)
            let line = try #require(text.components(separatedBy: .newlines).first { $0.contains("\"\(family.id)\":") && $0.contains("#") })
            let values = line.matches(of: /(srgb|displayP3|extendedLinearSRGB) #([0-9A-F]{6})/).map { (String($0.1), String($0.2)) }
            #expect(values.count == 9)
            for (index, (space, hex)) in values.enumerated() where space != "extendedLinearSRGB" {
                let swatch = family.swatches[index]
                #expect(swatch.space == (space == "displayP3" ? .displayP3 : .sRGB))
                #expect(swatch == BrowserThemeColor(hex: UInt32(hex, radix: 16)!, space: swatch.space), "\(family.id) \(index + 1)")
            }
        }
        // Brand 5 is stored as extended linear sRGB (1, 0.235, 0.098): encoded ≈ #FF8558.
        #expect(near(BrowserSpaceThemePresets.brand.swatches[4], 0xFF8558, 1))
        let swatch = try #require(BrowserSpaceThemePresets.theme(family: BrowserSpaceThemePresets.drab, index: 2))
        #expect(swatch.presetID == "drab.3" && swatch.colors == [BrowserSpaceThemePresets.drab.swatches[2]])
        #expect(BrowserSpaceThemePresets.swatch(for: "drab.3")?.index == 2)
        #expect(BrowserSpaceThemePresets.swatch(for: "drab.10") == nil && BrowserSpaceThemePresets.swatch(for: "x") == nil)
    }

    @Test("Accent family: default preset, greyish, saturated and neutral themes")
    func accentFamilies() throws {
        #expect(BrowserSpaceThemePresets.default.accentFamily == .defaultSpace)
        guard case let .derived(hue, saturation, strong) = BrowserSpaceTheme.composed(colors: [mauve]).accentFamily else {
            Issue.record("mauve must derive"); return
        }
        #expect(close(hue, mauve.hsb.hue, 0.01) && saturation < BrowserSpaceTheme.greyishSaturation && strong == mauve)
        guard case let .derived(_, vivid, vividStrong) = BrowserSpaceTheme.composed(colors: [mauve, coral]).accentFamily else {
            Issue.record("coral must derive"); return
        }
        #expect(vivid >= BrowserSpaceTheme.greyishSaturation && vividStrong == coral)
        let grey = try #require(BrowserSpaceThemePresets.theme(family: BrowserSpaceThemePresets.greyscale, index: 4))
        guard case let .derived(_, neutral, _) = grey.accentFamily else { Issue.record("grey must derive"); return }
        #expect(neutral < BrowserSpaceTheme.neutralSaturation)
    }
}

@Suite("Space themes — import bridge", .serialized)
struct BrowserSpaceThemeImportTests {
    private func appearance(_ theme: String?, hex: String? = nil) -> ArcSpaceAppearance {
        ArcSpaceAppearance(colorHex: hex, icon: nil, theme: theme)
    }

    @Test("Orbit windowTheme variants map to themes; nothing is invented without a colour")
    func mapping() throws {
        let gradient = """
        {"background":{"single":{"_0":{"style":{"color":{"_0":{"blendedGradient":{"_0":{"baseColors":[\
        {"color":{"red":0.95,"green":0.37,"blue":0.42,"alpha":1,"colorSpace":"extendedSRGB"}},\
        {"_0":{"red":0.4,"green":0.4,"blue":0.53,"colorSpace":"displayP3"}}],"intensityFactor":0.5,"noiseFactor":0.2}}}}}}}},\
        "windowAppearance":{"dark":{}},"futureField":[1,2,3]}
        """
        let mapped = try #require(ArcSpaceThemeImport.theme(for: appearance(gradient, hex: "#123456")))
        #expect(mapped.colors.count == 2 && mapped.intensity == 0.5 && mapped.noise == 0.2 && mapped.mode == .dark)
        #expect(mapped.colors[1].space == .displayP3 && near(mapped.colors[0], 0xF25E6B, 1))
        let flat = """
        {"style":{"basicColor":{"_0":{"r":1.4,"g":0.5,"b":0,"alpha":1}}},"windowAppearance":"light"}
        """
        let basic = try #require(ArcSpaceThemeImport.theme(for: appearance(flat)))
        #expect(basic.colors == [BrowserThemeColor(red: 1, green: 0.5, blue: 0)] && basic.mode == .light)
        let palette = try #require(ArcSpaceThemeImport.theme(for: appearance(#"{"primaryColorPalette":{}}"#, hex: "#336699")))
        #expect(palette.colors == [BrowserThemeColor(hex: 0x336699)] && palette.mode == .automatic)
        #expect(palette.intensity == BrowserSpaceTheme.defaultIntensity && palette.noise == 0)
        #expect(ArcSpaceThemeImport.theme(for: appearance("{not json", hex: "#336699"))?.colors == [BrowserThemeColor(hex: 0x336699)])
        #expect(ArcSpaceThemeImport.theme(for: appearance(#"{"futureField":1}"#)) == nil)
        #expect(ArcSpaceThemeImport.theme(for: appearance(nil, hex: "#33669")) == nil)
        let four = """
        {"blendedGradient":{"baseColors":["#111111","#222222","#333333","#444444"]}}
        """
        #expect(ArcSpaceThemeImport.theme(for: appearance(four))?.colors.count == 3)
    }

    @Test("Imported appearances become themes once and never override a user choice")
    func oneTimeMigration() async throws {
        let fixture = try await ThemeFixture.make()
        let userTheme = BrowserSpaceTheme.composed(colors: [mauve])
        let third = try await fixture.store.createSpace(name: "Third", profileID: fixture.profile)
        try await fixture.store.setSpaceTheme(userTheme, for: third)
        var document = BrowserSpaceAppearanceDocument()
        document.addMissing([
            .init(spaceID: fixture.home, appearance: appearance(nil, hex: "#336699")),
            .init(spaceID: fixture.work, appearance: appearance(#"{"futureField":1}"#)),
            .init(spaceID: third, appearance: appearance(nil, hex: "#ff0000")),
            .init(spaceID: SpaceID(), appearance: appearance(nil, hex: "#00ff00")),
        ])
        #expect(await fixture.store.migrateImportedSpaceThemes(document) == [fixture.home])
        #expect(try await fixture.store.spaceTheme(fixture.home)?.colors == [BrowserThemeColor(hex: 0x336699)])
        #expect(try await fixture.store.spaceTheme(fixture.work) == nil)
        #expect(try await fixture.store.spaceTheme(third) == userTheme)
        #expect(await fixture.store.importedThemeSpaces() == [fixture.home, fixture.work, third])
        // The user resets the imported theme: a later launch does not bring it back.
        try await fixture.store.setSpaceTheme(nil, for: fixture.home)
        #expect(await fixture.store.migrateImportedSpaceThemes(document).isEmpty)
        #expect(try await fixture.store.spaceTheme(fixture.home) == nil)
        // The record survives the session file and forgets removed Spaces.
        let encoded = try await fixture.store.sessionDocument().encoded()
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(encoded))
        #expect(await restored.migrateImportedSpaceThemes(document).isEmpty)
        #expect(Set(try BrowserSessionDocument.decode(encoded).themeImports) == [fixture.home, fixture.work, third])
    }

    @Test("End to end: a synthetic Orbit import's sidecar themes its Spaces at the next launch")
    func endToEnd() async throws {
        let fixture = try OrbitImportTestFixture(); defer { fixture.remove() }
        let target = try fixture.target()
        _ = try await fixture.importer().apply(try await fixture.importer().prepare(for: target), to: target)
        await target.close()
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        let sidecar = try #require(BrowserSpaceAppearanceDocument.load(at: location))
        let store = try BrowserStore(restoring: BrowserSessionFileStore().load(from: fixture.sessionFile))
        let themed = await store.migrateImportedSpaceThemes(sidecar)
        #expect(themed.count == 3 && Set(themed) == Set(sidecar.entries.map(\.spaceID)))
        for spaceID in themed {
            let theme = try #require(try await store.spaceTheme(spaceID))
            #expect(theme.colors == [BrowserThemeColor(hex: 0x336699)] && theme.isValid)
        }
        #expect(try BrowserSessionDocument.decode(await store.sessionDocument().encoded()).themeImports.count == 3)
    }
}
