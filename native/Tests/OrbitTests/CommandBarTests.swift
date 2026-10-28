import AppKit
@testable import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Command bar product routes and icons", .serialized)
@MainActor
struct CommandBarTests {
    private func command(_ id: BrowserCommandID) -> BrowserPaletteResult {
        .init(id: "command:\(id)", title: OrbitCommandCatalog.definitions.first { $0.id == id }?.title ?? id.rawValue,
              detail: "", section: .commands, action: .command(id), searchAliases: BrowserDailyCommands.aliases(id))
    }

    @Test("French, English and abbreviated commands rank before web search; explicit URLs stay authoritative")
    func commandRanking() {
        let cases: [(String, BrowserCommandID)] = [
            ("nouvelle fenêtre", .newWindow), ("new wndw", .newWindow), ("nouv fen", .newWindow),
            ("private window", .newIncognitoWindow), ("nouveau little orbit", .newQuickWindowWindow),
            ("nouvel espace", .newSpace), ("vue scindee", .addSplitView),
            ("extensions", .manageExtensions), ("ajouter une extension", .addExtension),
            ("reglages", .preferences), ("settings", .preferences), ("historique", .viewHistory),
            ("telechargements", .viewDownloads), ("bibliotheque", .viewLibrary),
            ("copier le lien", .copyURL), ("reload", .refreshThePage), ("fermer l'onglet", .archiveTab),
            ("desepingler", .pinUnpinTab), ("masquer la barre laterale", .showHideSidebar),
            ("importer depuis orbit", .importFromArc)
        ]
        let actions = Array(Set(cases.map(\.1))).sorted { $0.rawValue < $1.rawValue }.map(command)
        for (query, id) in cases {
            for mode in [BrowserPaletteMode.newTab, .currentTab] {
                let results = BrowserPaletteRanking.results(query: query, mode: mode, resolver: .init(), candidates: [], history: [], actions: actions)
                #expect(results.first?.action == .command(id), "Query: \(query)")
                #expect(results.contains { $0.id == "search" })
            }
        }
        let address = BrowserPaletteRanking.results(query: "https://extensions.example.org/", mode: .newTab,
            resolver: .init(), candidates: [], history: [], actions: actions)
        #expect(address.first?.id == "address")
        #expect(BrowserPaletteRanking.commandScore("delete everything", result: command(.newWindow)) == nil)
    }

    @Test("Title and host deduplication is restricted to configured hosts and keeps ranking authority")
    func titleAndHostDeduplication() {
        func page(_ id: String, _ host: String, _ path: String, title: String = "Design", section: BrowserPaletteSection = .tabs) -> BrowserPaletteResult {
            let url = URL(string: "https://\(host)/\(path)")!
            return .init(id: id, title: title, detail: host, section: section, action: .navigate(url), sourceURL: url)
        }
        for host in BrowserPaletteRanking.titleAndHostDeduplicationHosts {
            let first = page("first", host, "a")
            let duplicate = page("duplicate", host, "b", section: .history)
            let otherTitle = page("other-title", host, "c", title: "Other design")
            #expect(BrowserPaletteRanking.deduplicatingTitlesAndHosts([first, duplicate, otherTitle]).map(\.id) == ["first", "other-title"])
            let ranked = BrowserPaletteRanking.results(query: "Design", mode: .newTab, resolver: .init(),
                candidates: [first, otherTitle], history: [
                    .init(profileID: ProfileID(), url: duplicate.url!, title: duplicate.title, faviconReference: nil,
                          visitCount: 5, typedCount: 2, lastVisitedAt: Date(), score: 10)
                ], actions: [], limit: 40)
            #expect(ranked.first?.id == "first")
            #expect(ranked.contains { $0.id == "search" })
            #expect(!ranked.contains { $0.section == .history })
        }
        let rows = [page("a", "github.com", "a"), page("b", "github.com", "b"),
            page("subdomain", "gist.github.com", "b"), page("lookalike", "github.com.example.org", "b"),
            page("other-host", "figma.com", "b"), page("case", "github.com", "c", title: "design"),
            page("outside-a", "example.org", "a"), page("outside-b", "example.org", "b"),
            page("typed", "github.com", "c", section: .address)]
        #expect(BrowserPaletteRanking.deduplicatingTitlesAndHosts(rows).map(\.id) == rows.filter { $0.id != "b" }.map(\.id))
        #expect(BrowserPaletteRanking.deduplicatingTitlesAndHosts(Array(rows.reversed())).contains { $0.id == "b" })
    }

    @Test("Only installed actions are offered, with catalog shortcuts and distinct command icons")
    func installedCommands() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        var keyWindow: NSWindow?
        let app = OrbitApplication(environment: environment, commandKeyWindow: { keyWindow }, windowPresenter: { _, _ in })
        defer { environment.autoArchive.scheduler.stop(); app.windows.shutdown() }
        let id = try #require(app.windows.newWindow())
        await app.windows.waitForPendingCommands()
        let window = try #require(app.windows.windows[id])
        keyWindow = window.window
        window.palette.registry = app.commands.registry
        window.palette.present(.newTab)
        await window.palette.waitForResults()
        for id in [BrowserCommandID.newWindow, .newIncognitoWindow, .newQuickWindowWindow, .newSpace, .addSplitView, .manageExtensions,
                   .addExtension, .preferences, .viewHistory, .viewDownloads, .viewLibrary, .copyURL,
                   .refreshThePage, .archiveTab, .pinUnpinTab, .showHideSidebar, .importFromArc] {
            window.palette.query(BrowserDailyCommands.aliases(id).components(separatedBy: "|")[0])
            let row = try #require(window.palette.results.first { $0.action == .command(id) })
            #expect(row.symbol == BrowserDailyCommands.symbol(id))
            #expect(row.shortcut == app.commands.registry.definition(id)?.shortcuts.first?.displayLabel ?? "")
        }
        #expect(app.commands.registry.isImplemented(.newIncognitoWindow))
    }

    @Test("Engine-owned icons survive history recording, reload and palette decoding without a URL loader")
    func persistedFavicons() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/orbit-command-bar-icons-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = SiteSyntheticEngine()
        let environment = BrowserEnvironment(engine: engine)
        let window = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); window.session.close(); window.window?.close() }
        let surface = try #require(window.session.selectedSurface)
        let page = URL(string: "https://icons.example.org/guide")!
        let icon = URL(string: "https://icons.example.org/brand.png")!
        let png = NativeFaviconReceiptTests.png()
        surface.navigate(to: page)
        surface.faviconURL = icon
        surface.faviconImage = BrowserFaviconImage(sourceURL: icon, png: png)
        let recorder = BrowserHistoryRecorder(directory: root, resolveProfile: { .init(profileID: $0, persistence: .persistent) })
        recorder.committed(surface, profile: .init(profileID: surface.profileID, persistence: .persistent))
        recorder.metadataChanged(surface)
        await recorder.flush()
        let recorded = try #require(try await recorder.suggestions(for: surface.profileID, query: "guide").first)
        try await recorder.close()
        let store = try BrowserHistoryStore(profileID: surface.profileID, policy: .persistent, directory: root)
        let suggestion = try #require(try await store.suggestions("guide").first)
        #expect(suggestion.faviconReference == recorded.faviconReference)
        let rows = BrowserPaletteRanking.results(query: "guide", mode: .newTab, resolver: .init(), candidates: [], history: [suggestion], actions: [])
        let row = try #require(rows.first { $0.section == .history })
        let reference = try #require(row.faviconReference)
        #expect(reference.scheme == "data")
        let cache = BrowserPaletteFaviconCache()
        #expect(cache.image(for: reference) == nil)
        await cache.waitForPendingImages()
        #expect(cache.image(for: reference) != nil)
        #expect(cache.image(for: icon) == nil)
        #expect(!BrowserHistoryFavicon.accepts(URL(string: "data:text/html;base64,PHNjcmlwdD4=")!))
        #expect(!BrowserHistoryFavicon.accepts(URL(string: "file:///tmp/icon.png")!))
        #expect(BrowserHistoryFavicon.reference(png: Data(repeating: 0, count: 131_073)) == nil)
        cache.clear()
        try await store.close()
    }

    @Test("Palette routes history and downloads to the actual library and sidebar toggle to the shell")
    func actionRouting() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let window = try await environment.makeWindow()
        let router = BrowserWindowRouter<BrowserWindowController<SiteSyntheticEngine>>(
            create: { _ in window }, present: { _, _ in }, dispose: { _ in })
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        _ = router.newWindow(id: window.id)
        await router.waitForPendingCommands()
        window.palette.registry = registry
        defer { environment.autoArchive.scheduler.stop(); router.shutdown(); window.window?.close() }
        for (query, section) in [("historique", BrowserLibraryCategory.history), ("downloads", .downloads)] {
            window.palette.present(.newTab)
            await window.palette.waitForResults()
            window.palette.query(query)
            window.palette.accept()
            await window.palette.waitForAcceptance()
            await window.session.waitForPendingCommands()
            #expect(window.library.isPresented && window.library.category == section)
            #expect(!window.palette.isPresented)
        }
        let wasShown = window.isSidebarShown
        window.palette.present(.newTab)
        await window.palette.waitForResults()
        window.palette.query("toggle sidebar")
        window.palette.accept()
        await window.palette.waitForAcceptance()
        await window.session.waitForPendingCommands()
        #expect(window.isSidebarShown != wasShown)
    }
}
}
