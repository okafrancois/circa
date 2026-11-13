import Foundation
import Testing
@testable import BrowserCore

struct BrowserSpacePlanetTests {
    @Test("New defaults use dots while saved icons stay unchanged")
    func legacyChoices() throws {
        #expect(BrowserSpaceSettings().iconSelection == .none)
        for (icon, expected) in [("", BrowserSpaceIcon.none), ("🏡", .grapheme("🏡")), ("📚", .grapheme("📚"))] {
            let data = try JSONSerialization.data(withJSONObject: ["icon": icon, "palette": "automatic"])
            let settings = try JSONDecoder().decode(BrowserSpaceSettings.self, from: data)
            #expect(settings.iconSelection == expected)
            #expect(try JSONDecoder().decode(BrowserSpaceSettings.self, from: JSONEncoder().encode(settings)).iconSelection == expected)
        }
    }
    @Test("Valid legacy symbols retain their identity through save and reload")
    func symbols() throws {
        for (symbol, _) in [("briefcase.fill", BrowserSpacePlanet.work), ("house.fill", .home), ("book.closed", .reading), ("paintbrush.fill", .sideProject)] {
            let data = try JSONSerialization.data(withJSONObject: ["icon": "", "palette": "automatic", "systemSymbol": symbol])
            let settings = try JSONDecoder().decode(BrowserSpaceSettings.self, from: data)
            #expect(settings.iconSelection == .systemSymbol(symbol))
            let saved = try JSONEncoder().encode(settings)
            #expect(try JSONDecoder().decode(BrowserSpaceSettings.self, from: saved).iconSelection == .systemSymbol(symbol))
        }
        let malformed = Data(#"{"icon":"🌻","palette":"automatic","systemSymbol":"../../invalid"}"#.utf8)
        #expect(try JSONDecoder().decode(BrowserSpaceSettings.self, from: malformed).iconSelection == .grapheme("🌻"))
    }
    @Test("Selecting dots clears a planet without discarding the dot choice on reload")
    func dots() throws {
        var settings = BrowserSpaceSettings()
        for planet in BrowserSpacePlanet.allCases {
            settings.iconSelection = .planet(planet)
            #expect(try JSONDecoder().decode(BrowserSpaceSettings.self, from: JSONEncoder().encode(settings)).iconSelection == .planet(planet))
        }
        settings.iconSelection = .none
        #expect(try JSONDecoder().decode(BrowserSpaceSettings.self, from: JSONEncoder().encode(settings)).iconSelection == .none)
    }
}
