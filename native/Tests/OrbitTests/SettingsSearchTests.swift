import Foundation
import Testing
@testable import Orbit
@testable import BrowserShell

@MainActor
struct SettingsSearchTests {
    private let rows: [BrowserSettingsSearchEntry] = [
        .init(id: "download", section: .general, title: "Save downloads to", help: "Choose a folder"),
        .init(id: "nightly", section: .advanced, title: "Receive nightly builds", help: "New features first"),
        .init(id: "memory", section: .advanced, title: "Memory Saver", help: "Put inactive tabs to sleep"),
        .init(id: "help", section: .profiles, title: "Other", help: "Memory Saver")
    ]
    @Test func exactPrefixAndRanking() {
        #expect(BrowserSettingsSearchIndex.search("memory", entries: rows).entries.map(\.id) == ["memory", "help"])
        #expect(BrowserSettingsSearchIndex.search("mem sav", entries: rows).entries.map(\.id) == ["memory", "help"])
        #expect(!BrowserSettingsSearchIndex.search("nightly", entries: rows).approximate)
        #expect(BrowserSettingsSearchIndex.search("   ", entries: rows).entries.isEmpty)
        #expect(BrowserSettingsSearchIndex.search("unicorn", entries: rows).entries.isEmpty)
    }
    @Test func typoFallbackIsExplicitAndConservative() {
        let result = BrowserSettingsSearchIndex.search("nighlty", entries: rows)
        // An adjacent transposition counts as one small spelling error.
        #expect(result.entries.map(\.id) == ["nightly"])
        #expect(result.approximate)
        let typo = BrowserSettingsSearchIndex.search("nighly", entries: rows)
        #expect(typo.approximate)
        #expect(typo.entries.map(\.id) == ["nightly"])
        #expect(BrowserSettingsSearchIndex.search("mem", entries: rows).approximate == false)
        #expect(BrowserSettingsSearchIndex.search("memy", entries: rows).entries.isEmpty)
        #expect(BrowserSettingsSearchIndex.oneEdit("downlods", "downloads"))
    }
    @Test func localizedTokensAndCatalog() throws {
        let bundle = try #require(BrowserText.resourceBundle)
        for (language, query) in [("fr", "telechargements"), ("en", "downloads")] {
            let path = try #require(bundle.path(forResource: language, ofType: "lproj"))
            let local = try #require(Bundle(path: path))
            let title = local.localizedString(forKey: "Save downloads to", value: nil, table: nil)
            let result = BrowserSettingsSearchIndex.search(query, entries: [.init(id: "folder", section: .general, title: title)])
            #expect(result.entries.map(\.id) == ["folder"])
        }
    }
    @Test func generatedCatalogCoversPaneDefinitions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/settings-search-index.py").path, "--check"]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let catalog = BrowserSettingsSearchCatalog.entries
        #expect(Set(catalog.map(\.section)) == Set(BrowserSettingsSection.navigationSections))
        #expect(Set(catalog.map(\.identity)).count == catalog.count)
        #expect(catalog.count >= 65)
    }
    @Test func visibleControlLabelsAreIndexed() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Orbit/Settings")
        let catalog = BrowserSettingsSearchCatalog.entries
        let labels = Set(catalog.map(\.title))
        let pattern = #"(?:Toggle|SettingsRowLabel|SettingsDetailRow)\((?:title: )?uiText\("([^"]+)"\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        for file in ["BrowserSettingsOrbitPanes.swift", "BrowserSettingsAIPane.swift", "BrowserShortcutRecorder.swift", "BrowserSettingsWindowController.swift", "BrowserSafeBrowsingSettingsRow.swift"] {
            var source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            if file == "BrowserSettingsAIPane.swift" { source = String(source.components(separatedBy: "struct BrowserSettingsAISitesSheet")[0]) }
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let title = String(source[try #require(Range(match.range(at: 1), in: source))])
                #expect(labels.contains(where: { $0 == uiText(title) || $0.hasPrefix(uiText(title) + " ") }), "Visible row is not indexed: \(file): \(title)")
            }
        }
    }
    @Test func jumpResolutionAndReturnPath() {
        let search = BrowserSettingsSearch()
        search.entries = { self.rows }
        search.query = "nighly"; search.refresh()
        var destination: BrowserSettingsSearchEntry?
        search.navigate = { destination = $0; return true }
        search.accept()
        #expect(destination?.section == .advanced)
        #expect(search.targetID == "nightly")
        #expect(search.query == "nighly")
        #expect(search.jumped && !search.showsResults)
        search.back()
        #expect(search.showsResults && search.targetID == nil)
        search.move(1); search.accept()
        search.clear()
        #expect(search.query.isEmpty && search.targetID == nil && !search.jumped)
        var unavailable = rows[0]; unavailable.unavailableReason = "Disabled"
        destination = nil; search.jump(unavailable)
        #expect(destination == nil)
    }
    @Test func locatorClockAndReducedMotion() {
        #expect(BrowserSettingsLocator.opacity(elapsed: 0, reducedMotion: false) == 1)
        #expect(BrowserSettingsLocator.opacity(elapsed: 1.2, reducedMotion: false) == 1)
        #expect(BrowserSettingsLocator.opacity(elapsed: 1.5, reducedMotion: false) < 0.5)
        #expect(BrowserSettingsLocator.opacity(elapsed: 1.85, reducedMotion: false) == 0)
        #expect(BrowserSettingsLocator.opacity(elapsed: 100, reducedMotion: true) == 1)
        #expect(BrowserSettingsLocator.controlPoints == [0, 0, 0.2, 1])
    }
}
