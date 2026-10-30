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
            ("private window", .newIncognitoWindow), ("nouveau little circa", .newQuickWindowWindow),
            ("nouvel espace", .newSpace), ("vue scindee", .addSplitView),
            ("extensions", .manageExtensions), ("ajouter une extension", .addExtension),
            ("reglages", .preferences), ("settings", .preferences), ("historique", .viewHistory),
            ("telechargements", .viewDownloads), ("bibliotheque", .viewLibrary),
            ("copier le lien", .copyURL), ("reload", .refreshThePage), ("fermer l'onglet", .archiveTab),
            ("desepingler", .pinUnpinTab), ("masquer la barre laterale", .showHideSidebar),
            ("importer depuis circa", .importFromArc)
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

    @Test("Title and host deduplication is restricted to supported hosts and keeps ranking authority")
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

    @Test("History and bookmarks lead text search; no match falls back to search in both modes")
    func textMatchOrderAndDisplay() throws {
        let url = URL(string: "https://www.example.org/welcome-to-orbit")!
        let bookmark = BrowserPaletteResult(id: "bookmark", title: "Getting Started", detail: "example.org/welcome-to-orbit",
            section: .pinned, action: .navigate(url))
        let history = BrowserHistorySuggestion(profileID: ProfileID(), url: url, title: "Getting Started", faviconReference: nil,
            visitCount: 10, typedCount: 1, lastVisitedAt: Date(), score: 20)
        for mode in [BrowserPaletteMode.newTab, .currentTab] {
            let saved = BrowserPaletteRanking.results(query: "get", mode: mode, resolver: .init(), candidates: [bookmark], history: [], actions: [command(.manageExtensions)])
            #expect(saved.map(\.id) == ["bookmark", "search"])
            let recent = BrowserPaletteRanking.results(query: "get", mode: mode, resolver: .init(), candidates: [], history: [history], actions: [])
            #expect(recent.first?.section == .history && recent.last?.id == "search")
            let absent = BrowserPaletteRanking.results(query: "unmatched synthetic query", mode: mode, resolver: .init(), candidates: [bookmark], history: [], actions: [])
            #expect(absent.count == 1 && absent.first?.id == "search")
        }
        #expect(BrowserPaletteRanking.displayURL(url) == "example.org/welcome-to-orbit")
        #expect(BrowserPaletteRanking.displayURL(URL(string: "http://127.0.0.1:46081/")!) == "127.0.0.1:46081")
        #expect(BrowserPaletteRanking.displayURL(URL(string: "https://user:password@example.org/%E2%80%AEabc%0A?q=%26#end")!) == "example.org/\\u{202E}abc\\u{000A}?q=&#end")
    }

    @Test("Site keywords are exact, URL aliases are bounded and queries cannot inject URL components")
    func siteSearchDestinations() throws {
        for keyword in ["youtube", "YouTube", "www.youtube.com", "https://www.youtube.com/"] {
            #expect(BrowserPaletteSiteSearch.matching(keyword)?.name == "YouTube")
        }
        for keyword in ["", "you", "youtube.com.evil.test", "youtube.com/path", "youtube cats", "https://youtube.com/?q=x"] {
            #expect(BrowserPaletteSiteSearch.matching(keyword) == nil)
        }
        let query = "café /?q=a&b=+%#猫"
        for site in BrowserPaletteSiteSearch.sites {
            let result = try #require(site.results(query: query).first)
            #expect(result.section == .search && !BrowserPaletteRanking.recordsTypedVisit(result))
            let url = try #require(result.url)
            #expect(url.scheme == "https" && url.user == nil && url.password == nil)
            #expect(url.absoluteString.contains("%2B") && url.absoluteString.contains("%26"))
            #expect(url.absoluteString.contains("%23") && url.absoluteString.contains("%2F"))
            #expect(site.results(query: " ").isEmpty)
        }
        let youtube = try #require(BrowserPaletteSiteSearch.matching("youtube")?.url(for: query))
        #expect(URLComponents(url: youtube, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "search_query", value: query)])
        let gmail = try #require(BrowserPaletteSiteSearch.matching("gmail")?.url(for: query))
        #expect(gmail.fragment?.removingPercentEncoding == "apps/" + query)
        let spotify = try #require(BrowserPaletteSiteSearch.matching("spotify")?.url(for: query))
        #expect(spotify.path == "/search/" + query)
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
