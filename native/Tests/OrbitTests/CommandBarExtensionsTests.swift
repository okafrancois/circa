import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

struct CommandBarExtensionsTests {
    private func item(_ name: String = "Palette Fixture", enabled: Bool = true,
                      action: Bool = true, options: Bool? = true) -> BrowserExtensionSummary {
        var item = BrowserExtensionSummary(id: name, name: name, version: "1", isEnabled: enabled, hasAction: action,
                                           iconPNGBase64: "fixture pixels")
        item.hasOptionsPage = options
        return item
    }

    private func rows(_ items: [BrowserExtensionSummary], isPrivate: Bool = false) -> [BrowserPaletteResult] {
        BrowserPaletteExtensions.rows(items, isPrivate: isPrivate, supportsActions: true)
    }

    @Test("Enabled extension actions have one chip row with their identity and icon")
    func inventory() {
        let available = rows([item(), item("Disabled", enabled: false), item("No Options", options: false),
                              item("Unknown Options", options: nil), item("Options Only", action: false)])
        #expect(available.map(\.action) == [.extensionAction("Palette Fixture"), .extensionAction("No Options"), .extensionAction("Unknown Options")])
        #expect(available[0].title == uiFormat("Extension · %@", "Palette Fixture"))
        #expect(available[0].extensionName == "Palette Fixture")
        #expect(available.allSatisfy { $0.iconPNGBase64 == "fixture pixels" && $0.section == .commands })
        #expect(rows([item()], isPrivate: true).isEmpty)
        var allowed = item()
        allowed.isAllowedInIncognito = true
        #expect(rows([allowed], isPrivate: true).isEmpty)
        #expect(BrowserPaletteExtensions.rows([item()], isPrivate: false,
            supportsActions: false).isEmpty)
    }

    @Test("Extension matching uses the command's folding, word prefixes and subsequences")
    func matching() {
        let result = rows([item("Éclair Palette")])[0]
        for query in ["eclair palette", "écl pal", "eclr pltt"] {
            #expect(BrowserPaletteRanking.commandScore(query, result: result) != nil)
        }
        #expect(BrowserPaletteRanking.commandScore("unrelated", result: result) == nil)
    }

    @Test("Exact commands stay above same-name extension actions")
    func ranking() {
        let command = BrowserPaletteResult(id: "command", title: "New Window", detail: "", section: .commands,
                                            action: .command(.newWindow))
        let ranked = BrowserPaletteRanking.results(query: "New Window", mode: .newTab, resolver: AddressResolver(),
            candidates: [], history: [], actions: [command] + rows([item("New Window")]))
        #expect(ranked.prefix(2).map(\.action) == [.command(.newWindow), .extensionAction("New Window")])
        #expect(ranked.last?.section == .search)
    }
}
