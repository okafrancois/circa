import Testing
import AppKit
import BrowserCore
@preconcurrency import Translation
@testable import Orbit

@MainActor
private final class AvailabilityLog {
    var created: [Bool] = []
    var statusQueries: [String] = []
    var languageQueries = 0
    var inFlight = 0
    var maxInFlight = 0

    func enter() async {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        // Suspend like the system service so overlapping callers would be observable.
        try? await Task.sleep(for: .milliseconds(2))
        inFlight -= 1
    }
}

@MainActor
private final class FakeLanguageAvailability: BrowserLanguageAvailabilityBackend {
    let highFidelity: Bool
    let log: AvailabilityLog

    init(highFidelity: Bool, log: AvailabilityLog) {
        self.highFidelity = highFidelity; self.log = log
        log.created.append(highFidelity)
    }

    func supportedLanguages() async -> [Locale.Language] {
        await log.enter()
        log.languageQueries += 1
        // Both strategies list overlapping languages, as the system service does.
        let identifiers = highFidelity ? ["en", "es", "fr-FR"] : ["en", "fr", "de", "it"]
        return identifiers.map(Locale.Language.init(identifier:))
    }

    func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        await log.enter()
        let pair = "\(source.minimalIdentifier)>\(target.minimalIdentifier)"
        log.statusQueries.append("\(pair)|\(highFidelity)")
        switch (pair, highFidelity) {
        case ("de>en", false): return .installed
        case ("de>fr", false): return .supported
        case ("de>es", true): return .supported
        default: return .unsupported
        }
    }
}

struct BrowserTranslationAvailabilityTests {
    private static let german = "Dieser Artikel beschreibt die Geschichte der Stadt Berlin und ihre wichtigsten Sehenswürdigkeiten im Zentrum."

    @MainActor private static func gateway(_ log: AvailabilityLog, lifetime: Duration = .seconds(60)) -> BrowserTranslationAvailability {
        BrowserTranslationAvailability(highFidelityAvailable: true, statusLifetime: lifetime) {
            FakeLanguageAvailability(highFidelity: $0, log: log)
        }
    }

    @MainActor private static func surfaces(_ count: Int) async throws -> (BrowserWindowController<PeekSyntheticEngine>, [PeekSyntheticSurface]) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let window = try await environment.makeWindow()
        var surfaces: [PeekSyntheticSurface] = []
        for index in 0..<count {
            window.openTab(url: URL(string: "https://translation.test/\(index)")!)
            await window.session.waitForPendingCommands()
            let surface = try #require(window.session.selectedSurface)
            surface.translationSampleText = german
            surfaces.append(surface)
        }
        return (window, surfaces)
    }

    @Test("Documents share one long-lived availability client per strategy and never overlap queries")
    @MainActor func sharedClients() async throws {
        let log = AvailabilityLog()
        let availability = Self.gateway(log)
        let (window, surfaces) = try await Self.surfaces(3)
        defer { window.session.close(); window.window?.close() }
        let pages = surfaces.map { BrowserPageTranslation(surface: $0, availability: availability) }
        for page in pages { page.detect(privateWindow: false, preferred: ["en"]) }
        for page in pages { await page.detection?.value }

        // Released system clients tear down status streams; none may be created per query.
        #expect(log.created.sorted { !$0 && $1 } == [false, true])
        #expect(log.maxInFlight == 1)
        #expect(log.languageQueries == 2)
        #expect(Set(log.statusQueries).count == log.statusQueries.count)
        for page in pages {
            #expect(page.state.phase == .available)
            #expect(page.state.target == "en")
            #expect(Set(page.targets) == ["en", "es", "fr"])
        }
    }

    @Test("Private documents list installed pairs only, through the same clients")
    @MainActor func privateTargets() async throws {
        let log = AvailabilityLog()
        let (window, surfaces) = try await Self.surfaces(1)
        defer { window.session.close(); window.window?.close() }
        let page = BrowserPageTranslation(surface: surfaces[0], availability: Self.gateway(log))
        page.detect(privateWindow: true, preferred: ["en"])
        await page.detection?.value
        #expect(page.targets == ["en"])
        #expect(log.created.count == 2)
    }

    @Test("A document whose language is not offered does not enumerate target languages")
    @MainActor func unofferedDocumentSkipsTargets() async throws {
        let log = AvailabilityLog()
        let (window, surfaces) = try await Self.surfaces(1)
        defer { window.session.close(); window.window?.close() }
        let page = BrowserPageTranslation(surface: surfaces[0], availability: Self.gateway(log))
        page.detect(privateWindow: false, preferred: ["de", "en"])
        await page.detection?.value
        #expect(page.state.phase == .unavailable)
        #expect(page.targets.isEmpty)
        #expect(log.languageQueries == 0)
        #expect(log.statusQueries.count <= 2)
    }

    @Test("Expired, refreshed or invalidated statuses query the same client again")
    @MainActor func statusFreshness() async {
        let log = AvailabilityLog()
        let expiring = Self.gateway(log, lifetime: .zero)
        _ = await expiring.status(from: "de", to: "en", highFidelity: false)
        _ = await expiring.status(from: "de", to: "en", highFidelity: false)
        #expect(log.statusQueries.count == 2)

        let lasting = Self.gateway(log)
        #expect(await lasting.status(from: "de", to: "en", highFidelity: false) == .installed)
        #expect(await lasting.status(from: "de-DE", to: "en", highFidelity: false) == .installed)
        #expect(log.statusQueries.count == 3)
        _ = await lasting.status(from: "de", to: "en", highFidelity: false, refresh: true)
        #expect(log.statusQueries.count == 4)
        lasting.invalidateStatuses()
        _ = await lasting.status(from: "de", to: "en", highFidelity: false)
        #expect(log.statusQueries.count == 5)
        #expect(log.created == [false, false])
    }

    @Test("Without high-fidelity models only the default client is created")
    @MainActor func noHighFidelity() async {
        let log = AvailabilityLog()
        let availability = BrowserTranslationAvailability(highFidelityAvailable: false) {
            FakeLanguageAvailability(highFidelity: $0, log: log)
        }
        _ = await availability.status(from: "de", to: "es", highFidelity: true)
        _ = await availability.supportedLanguages(highFidelity: true)
        #expect(log.created == [false])
    }
}
