import AppKit
import SwiftUI
import Testing
import BrowserCore
import BrowserShell
@testable import Orbit

private actor DesignProvider: BrowserAIProviderClient {
    nonisolated let id: BrowserAIProviderID = .codex
    var requests: [BrowserAITurnRequest] = []
    var streams: [AsyncStream<BrowserAITurnEvent>.Continuation] = []
    func status(refresh: Bool) async -> BrowserAIProviderStatus { .init(id: id, state: .signedOut) }
    func shutdown() async {}
    func startTurn(_ request: BrowserAITurnRequest) async -> BrowserAITurn {
        requests.append(request)
        let pair = AsyncStream<BrowserAITurnEvent>.makeStream()
        streams.append(pair.continuation)
        return BrowserAITurn(events: pair.stream, interrupt: {})
    }
    func emit(_ event: BrowserAITurnEvent) { streams.last?.yield(event) }
}

@MainActor private func designConversation(_ provider: DesignProvider, sources: [BrowserAIContextSource],
                                           pages: [UUID: String] = [:]) -> BrowserAIConversation {
    var preferences = BrowserAIPreferences()
    preferences.isEnabled = true
    let allowed = preferences
    return BrowserAIConversation(choice: .init(provider: .codex), clients: [provider], preferences: { allowed }, isPrivate: { false },
        currentSource: { id in sources.first { $0.id == id } }, reader: { pages[$0.id] ?? "PAGE" })
}

private func source(_ title: String) -> BrowserAIContextSource {
    BrowserAIContextSource(id: UUID(), revision: 1, url: URL(string: "https://example.com/" + title)!, title: title)
}

@MainActor @Suite("Assistant Space palette")
struct BrowserAssistantPaletteTests {
    @Test("The first dock paint retains its tint before a host is attached")
    func firstDockPaint() throws {
        let card = BrowserContentCardView()
        let tint = NSColor(srgbRed: 0.13, green: 0.27, blue: 0.41, alpha: 0.66)
        card.setAssistantSurface(theme: .default, tint: tint)
        let clip = try #require(card.subviews.first { $0.subviews.contains { $0 is OrbitThemeFillView } })
        let actual = try #require(clip.subviews.last?.layer?.backgroundColor)
        #expect(NSColor(cgColor: actual)?.usingColorSpace(.sRGB) == tint.usingColorSpace(.sRGB))
    }

    private static var themes: [(String, OrbitTokens.SpaceTheme)] {
        var result: [(String, OrbitTokens.SpaceTheme)] = [("default", .default)]
        for family in BrowserSpaceThemePresets.families {
            for index in family.swatches.indices {
                result.append(("\(family.id).\(index + 1)", OrbitSpaceThemes.rendered(BrowserSpaceThemePresets.theme(family: family, index: index)!)))
            }
        }
        return result
    }

    @Test("Every swatch and the default gradient stay readable in both appearances", arguments: [false, true])
    func contrast(isDark: Bool) throws {
        #expect(Self.themes.count == 37)
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        for (name, theme) in Self.themes {
            let palette = BrowserAssistantPalette(theme: theme, appearance: appearance)
            for surface in palette.surfaces {
                let opaque = try #require(surface.usingColorSpace(.sRGB))
                #expect(opaque.alphaComponent == 1, "\(name)")
                #expect(OrbitFloatingMaterial.contrast(palette.ink, surface) >= 7, "\(name) ink")
                #expect(OrbitFloatingMaterial.contrast(palette.secondary, surface) >= 4.5, "\(name) secondary")
                #expect(OrbitFloatingMaterial.contrast(palette.accentInk, surface) >= 4.5, "\(name) accent")
                #expect(OrbitFloatingMaterial.contrast(palette.strong, surface) >= 3, "\(name) send")
                let wash = OrbitThemeForeground.composite(palette.wash, on: surface)
                #expect(OrbitFloatingMaterial.contrast(palette.accentInk, wash) >= 4.5, "\(name) accent on wash")
                #expect(OrbitFloatingMaterial.contrast(palette.ink, wash) >= 4.5, "\(name) ink on wash")
                let composer = OrbitThemeForeground.composite(palette.composer, on: surface)
                #expect(OrbitFloatingMaterial.contrast(palette.ink, composer) >= 7, "\(name) composer ink")
                #expect(OrbitFloatingMaterial.contrast(palette.secondary, composer) >= 4.5, "\(name) composer secondary")
            }
            #expect(OrbitFloatingMaterial.contrast(palette.onStrong, palette.strong) >= 3, "\(name) send glyph")
            // Conservative popover check: the blur may contribute nothing over a black or white backdrop.
            for backdrop in [NSColor.black, .white] {
                let popover = OrbitThemeForeground.composite(palette.popover, on: backdrop)
                #expect(OrbitFloatingMaterial.contrast(palette.ink, popover) >= 7, "\(name) popover")
                #expect(OrbitFloatingMaterial.contrast(palette.secondary, popover) >= 4.5, "\(name) popover secondary")
            }
        }
    }

    @Test("Polarity follows the Space ink, not the window appearance", arguments: [false, true])
    func polarity(isDark: Bool) throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        for (name, theme) in Self.themes {
            let palette = BrowserAssistantPalette(theme: theme, appearance: appearance)
            let ink = OrbitSpaceThemes.accent(for: theme).foreground.resolved(for: appearance)
            #expect(palette.isDark == !OrbitThemeForeground.isLight(on: ink), "\(name)")
        }
        // The swatch with the darkest fill must produce a dark dock even in a light window.
        let black = try #require(BrowserSpaceThemePresets.theme(family: BrowserSpaceThemePresets.greyscale, index: 8))
        let light = BrowserAssistantPalette(theme: OrbitSpaceThemes.rendered(black), appearance: NSAppearance(named: .aqua)!)
        #expect(light.isDark)
    }

    @Test("The surface carries the Space instead of a system background")
    func surfaceCarriesSpace() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let surfaces = Self.themes.compactMap { _, theme -> String? in
            guard let color = BrowserAssistantPalette(theme: theme, appearance: appearance).surfaces.first?.usingColorSpace(.sRGB) else { return nil }
            return [color.redComponent, color.greenComponent, color.blueComponent].map { String(Int(($0 * 255).rounded())) }.joined(separator: ",")
        }
        #expect(Set(surfaces).count > 30)
        // Gradient Spaces differ along the dock because each point composites its own fill.
        let gradient = BrowserAssistantPalette(theme: .amberCoral, appearance: appearance)
        let top = try #require(gradient.surfaces.first), bottom = try #require(gradient.surfaces.last)
        #expect(top != bottom)
    }

    @Test("Send and accent ink keep the hue of the selected swatch")
    func accentFollowsFamily() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let coral = try #require(BrowserSpaceThemePresets.theme(family: BrowserSpaceThemePresets.brand, index: 3))
        let palette = BrowserAssistantPalette(theme: OrbitSpaceThemes.rendered(coral), appearance: appearance)
        let swatch = try #require(OrbitSpaceThemes.color(BrowserSpaceThemePresets.brand.swatches[3]).usingColorSpace(.sRGB))
        let strong = try #require(palette.strong.usingColorSpace(.sRGB))
        #expect(abs(strong.hueComponent - swatch.hueComponent) < 0.02)
        let accent = try #require(palette.accentInk.usingColorSpace(.sRGB))
        #expect(abs(accent.hueComponent - swatch.hueComponent) < 0.02)
    }
}

@MainActor @Suite("Assistant dock geometry")
struct BrowserAssistantDockGeometryTests {
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 949)

    @Test("The native context symbol has transparent counters", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func contextSymbolRaster(appearanceName: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: appearanceName))
        let renderer = ImageRenderer(content: OrbitIcon.contextSymbol.font(.system(size: 48))
            .foregroundStyle(.black).frame(width: 64, height: 64))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            context.cgContext.clear(CGRect(x: 0, y: 0, width: 64, height: 64))
            renderer.nsImage?.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let pixels = try #require(bitmap.bitmapData)
        let ink = (0..<4096).filter { pixels[$0 * 4 + 3] > 32 }.count
        #expect(ink > 200 && ink < 2500)
    }

    @Test("Selector stays inside the dock at every width", arguments: [300.0, 372.0, 480.0] as [CGFloat])
    func selectorBounds(panelWidth: CGFloat) {
        let composer = NSRect(x: 1000, y: 40, width: panelWidth - 20, height: 120)
        let frame = BrowserAssistantPopover.frame(composer: composer, size: NSSize(width: 560, height: 320),
                                                  placement: .over(bottomInset: 48), top: 900, visible: screen)
        #expect(frame.minX == composer.minX && frame.maxX == composer.maxX)
        #expect(frame.minY == composer.minY + 48)
        #expect(frame.height == 320)
    }

    @Test("Context menu opens above the composer at its own width")
    func contextBounds() {
        let wide = NSRect(x: 1000, y: 40, width: 460, height: 120)
        let menu = BrowserAssistantPopover.frame(composer: wide, size: NSSize(width: 288, height: 200),
                                                 placement: .above(maxWidth: 288), top: 900, visible: screen)
        #expect(menu.minX == wide.minX && menu.width == 288 && menu.minY == wide.maxY + 6)
        let narrow = NSRect(x: 1000, y: 40, width: 280, height: 120)
        let tight = BrowserAssistantPopover.frame(composer: narrow, size: NSSize(width: 288, height: 200),
                                                  placement: .above(maxWidth: 288), top: 900, visible: screen)
        #expect(tight.maxX <= narrow.maxX)
    }

    @Test("A short window shrinks the menu instead of moving it off the dock")
    func shortWindow() {
        let composer = NSRect(x: 1000, y: 40, width: 352, height: 120)
        let frame = BrowserAssistantPopover.frame(composer: composer, size: NSSize(width: 352, height: 500),
                                                  placement: .over(bottomInset: 48), top: 300, visible: screen)
        #expect(frame.minX == composer.minX && frame.maxX == composer.maxX && frame.maxY == 300)
        let edge = NSRect(x: 1400, y: 40, width: 352, height: 120)
        let clamped = BrowserAssistantPopover.frame(composer: edge, size: NSSize(width: 352, height: 200),
                                                    placement: .over(bottomInset: 48), top: 900, visible: screen)
        #expect(clamped.maxX <= screen.maxX - 8)
    }

    @Test("The dock is a stationary sibling of the page during its reveal")
    func siblingCard() async throws {
        let card = BrowserContentCardView()
        card.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        card.present(NSView())
        let panel = NSView()
        card.setAssistant(panel, width: 372)
        card.setAssistantSurface(theme: .amberCoral, tint: NSColor.white.withAlphaComponent(0.72))
        card.layoutSubtreeIfNeeded()
        let clip = try #require(panel.superview)
        // The content's trailing edge never moves while the clip widens.
        #expect(panel.bounds.width == 372)
        #expect(abs(card.convert(panel.bounds, from: panel).maxX - 1000) < 1)
        #expect(clip.layer?.cornerRadius == OrbitTokens.Radius.contentCard)
        let surface = try #require(clip.subviews.first { $0 is OrbitThemeFillView } as? OrbitThemeFillView)
        #expect(surface.theme.texture == .none && surface.theme.stops == OrbitTokens.SpaceTheme.amberCoral.stops)
        #expect(clip.subviews.firstIndex(of: surface)! < clip.subviews.firstIndex(of: panel)!)
        let edges = card.subviews.compactMap { $0 as? OrbitSurfaceBackgroundView }
        #expect(edges.count == 2)
        #expect(edges.allSatisfy { $0.outerShadow?.blur == OrbitTokens.Shadow.contentCard.blur && $0.outerShadow?.offsetY == OrbitTokens.Shadow.contentCard.offsetY && $0.cornerRadius == OrbitTokens.Radius.contentCard })
        try? await Task.sleep(for: .milliseconds(450))
        card.layoutSubtreeIfNeeded()
        #expect(abs(card.convert(panel.bounds, from: panel).maxX - 1000) < 1)
        #expect(edges.last?.frame == clip.frame)
        let page = try #require(edges.first)
        #expect(abs(clip.frame.minX - page.frame.maxX - 10) < 1)
        // Fullscreen and windowed restoration use the same shell radius on both cards.
        for radius: CGFloat in [0, OrbitTokens.Radius.contentCard, 0, OrbitTokens.Radius.contentCard] {
            card.cornerRadius = radius
            card.layoutSubtreeIfNeeded()
            #expect(clip.layer?.cornerRadius == radius)
            #expect(edges.allSatisfy { $0.cornerRadius == radius })
            #expect(abs(clip.frame.minX - page.frame.maxX - 10) < 1)
        }
        card.setAssistant(nil, width: 0)
    }
}

@MainActor @Suite("Assistant context revocation")
struct BrowserAssistantRevocationTests {
    private func until(_ predicate: () async -> Bool) async {
        for _ in 0..<10_000 { if await predicate() { return }; await Task.yield() }
        Issue.record("Async operation did not finish")
    }

    @Test("A source is gone at the click while its chip is still fading")
    func sendDuringFadeNeverIncludesTheSource() async throws {
        let provider = DesignProvider()
        let kept = source("Kept"), removed = source("Removed")
        let conversation = designConversation(provider, sources: [kept, removed], pages: [kept.id: "KEPT-TEXT", removed.id: "REMOVED-SECRET"])
        conversation.select(removed); conversation.select(kept)
        var chips = BrowserAssistantContextChips()

        chips.revoke(removed, from: conversation)
        #expect(conversation.selectedSources == [kept])
        // The fading chip is presented in its old slot, only as a detached snapshot.
        #expect(chips.chips(selected: conversation.selectedSources).map(\.source) == [removed, kept])
        #expect(chips.chips(selected: conversation.selectedSources).map(\.leaving) == [true, false])

        #expect(conversation.send("Question during the fade"))
        await until { await provider.requests.count == 1 }
        let prompt = await provider.requests[0].prompt
        #expect(prompt.contains("KEPT-TEXT"))
        #expect(!prompt.contains("REMOVED-SECRET") && !prompt.contains("Removed"))
        #expect(conversation.messages.flatMap(\.context).allSatisfy { $0.source == kept })

        chips.finish(removed.id)
        #expect(chips.chips(selected: conversation.selectedSources).map(\.source) == [kept])
    }

    @Test("History read from a revoked source is not sent again")
    func revokedHistory() async throws {
        let provider = DesignProvider()
        let removed = source("Removed")
        let conversation = designConversation(provider, sources: [removed], pages: [removed.id: "REMOVED-SECRET"])
        conversation.select(removed)
        conversation.send("Earlier question")
        await until { await provider.requests.count == 1 }
        await provider.emit(.text("Earlier answer"))
        await provider.emit(.completed)
        await until { !conversation.isRunning }
        var chips = BrowserAssistantContextChips()
        chips.revoke(removed, from: conversation)
        conversation.send("Next question")
        await until { await provider.requests.count == 2 }
        let prompt = await provider.requests[1].prompt
        #expect(!prompt.contains("Earlier question") && !prompt.contains("Earlier answer") && !prompt.contains("REMOVED-SECRET"))
    }

    @Test("Adding a source back during its fade restores one live chip")
    func readdedDuringFade() {
        let provider = DesignProvider()
        let item = source("Tab")
        let conversation = designConversation(provider, sources: [item])
        conversation.select(item)
        var chips = BrowserAssistantContextChips()
        chips.revoke(item, from: conversation)
        conversation.select(item)
        let shown = chips.chips(selected: conversation.selectedSources)
        #expect(shown.count == 1 && shown[0].leaving == false)
    }
}

@MainActor @Suite("Assistant answer text")
struct BrowserAssistantAnswerTextTests {
    @Test("Wheel input over answer text reaches the transcript responder")
    func transcriptScrolling() throws {
        final class Transcript: NSResponder {
            var received: NSEvent?
            override func scrollWheel(with event: NSEvent) { received = event }
        }
        let transcript = Transcript()
        let view = BrowserAssistantAnswerText.TextView(usingTextLayoutManager: false)
        view.nextResponder = transcript
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                        wheel1: 20, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: wheel))
        view.scrollWheel(with: event)
        #expect(transcript.received === event)
    }

    private func completedAnswer(_ text: [String], page: String) async throws -> BrowserAIMessage {
        let provider = DesignProvider()
        let item = source("Guide")
        let conversation = designConversation(provider, sources: [item], pages: [item.id: page])
        conversation.select(item)
        conversation.send("Question")
        for _ in 0..<10_000 { if await provider.requests.count == 1 { break }; await Task.yield() }
        for delta in text { await provider.emit(.text(delta)) }
        await provider.emit(.completed)
        for _ in 0..<10_000 { if !conversation.isRunning { break }; await Task.yield() }
        return try #require(conversation.messages.last)
    }

    @Test("Validated markers become pills, invented ones disappear and model links stay plain")
    func citationsRender() async throws {
        let passage = "Actors allow one task at a time."
        let message = try await completedAnswer([
            "In short:\n\n- **One** task `await` [1: \"\(passage)\"]\n- Invented [1: \"This is not in the page at all\"]\n1. See [site](https://evil.example)"
        ], page: passage)
        let blocks = BrowserAssistantRichText.blocks(message)
        #expect(blocks.count == 4)
        guard case .paragraph(let first) = blocks[0], case .bullet(let bullet) = blocks[1], case .bullet(let invented) = blocks[2],
              case .ordered(1, let link) = blocks[3] else { Issue.record("Unexpected structure"); return }
        #expect(first.map(\.text).joined() == "In short:")
        #expect(bullet.contains { $0.bold && $0.text == "One" } && bullet.contains { $0.code && $0.text == "await" })
        #expect(bullet.compactMap(\.citation).map(\.passage) == [passage])
        #expect(invented.allSatisfy { $0.citation == nil } && !invented.map(\.text).joined().contains("["))
        #expect(link.map(\.text).joined() == "See site")

        let palette = BrowserAssistantPalette(theme: .default, appearance: NSAppearance(named: .aqua)!)
        let attributed = BrowserAssistantRichText.attributed(blocks, palette: palette, activeCitation: nil, hoveredCitation: nil)
        #expect(!attributed.string.contains("[1:") && !attributed.string.contains("evil.example"))
        var attachments = 0, links = 0
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, _, _ in
            if attributes[.attachment] is BrowserAssistantCitationAttachment {
                attachments += 1
                #expect(attributes[BrowserAssistantRichText.citationKey] as? String == BrowserAICitation.parse(message).first?.id)
            }
            if attributes[.link] != nil { links += 1 }
        }
        #expect(attachments == 1 && links == 0)
        #expect(BrowserAICitation.displayText(message).contains("task `await`\n"))
        #expect(!BrowserAICitation.displayText(message).contains("[1:"))
    }

    @Test("Arriving text fades only the new suffix")
    func arrivingRange() {
        #expect(BrowserAssistantRichText.arrivingRange(old: "Hello", new: "Hello world") == NSRange(location: 5, length: 6))
        #expect(BrowserAssistantRichText.arrivingRange(old: "Hello", new: "Hello") == nil)
        #expect(BrowserAssistantRichText.arrivingRange(old: "**Hello", new: "Hello") == nil)
    }

    @Test("The text view measures to its width and keeps pills out of the clipboard")
    func measureAndCopy() async throws {
        let passage = "Actors allow one task at a time."
        let message = try await completedAnswer([String(repeating: "A long line of answer text. ", count: 12), "[1: \"\(passage)\"]"], page: passage)
        let answer = BrowserAssistantAnswerText(message: message, open: { _ in }, activeCitation: nil)
        let host = NSHostingView(rootView: answer.environment(\.assistantPalette, BrowserAssistantPalette(theme: .default, appearance: NSAppearance(named: .aqua)!)))
        let narrow = host.fittingSize.height
        #expect(narrow > 0)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
        host.layoutSubtreeIfNeeded()
        let view = try #require(Self.textView(in: host))
        #expect(view.textStorage?.string.contains("\u{FFFC}") == true)
        let tall = view.height(forWidth: 280), short = view.height(forWidth: 480)
        #expect(tall > short && short >= 21)
        view.selectAll(nil)
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        view.copy(nil)
        #expect(pasteboard.string(forType: .string)?.contains("\u{FFFC}") == false)
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
    }

    private static func textView(in view: NSView) -> BrowserAssistantAnswerText.TextView? {
        if let text = view as? BrowserAssistantAnswerText.TextView { return text }
        for child in view.subviews { if let found = textView(in: child) { return found } }
        return nil
    }
}

@MainActor @Suite("Assistant selector rows")
struct BrowserAssistantSelectorTests {
    private let statuses: [BrowserAIProviderID: BrowserAIProviderStatus] = [
        .codex: .init(id: .codex, state: .ready(.init(plan: nil)), models: [
            .init(provider: .codex, id: "gpt-sol", displayName: "GPT Sol", efforts: ["low", "high"], defaultEffort: "low")]),
        .claudeCode: .init(id: .claudeCode, state: .signedOut, models: [
            .init(provider: .claudeCode, id: "sonnet", displayName: "Sonnet")])
    ]
    private let choices = [BrowserAIModelChoice(provider: .codex, model: "gpt-sol"),
                           BrowserAIModelChoice(provider: .claudeCode, model: "sonnet"),
                           BrowserAIModelChoice(provider: .onDevice)]
    private let providers: [BrowserAIProviderID] = [.codex, .claudeCode, .onDevice]

    @Test func rowsShowOnlyRealChoices() {
        let codex = BrowserAssistantModels.rows(viewing: .codex, query: "", providers: providers, choices: choices, statuses: statuses)
        #expect(codex.map(\.model?.id) == ["gpt-sol"])
        let device = BrowserAssistantModels.rows(viewing: .onDevice, query: " ", providers: providers, choices: choices, statuses: statuses)
        #expect(device.count == 1 && device[0].model == nil && device[0].title == BrowserSettingsAIText.name(.onDevice))
    }

    @Test func searchSpansProviders() {
        let all = BrowserAssistantModels.rows(viewing: .codex, query: "sonnet", providers: providers, choices: choices, statuses: statuses)
        #expect(all.map(\.provider) == [.claudeCode])
        let byProvider = BrowserAssistantModels.rows(viewing: .codex, query: "claude", providers: providers, choices: choices, statuses: statuses)
        #expect(byProvider.map(\.model?.id) == ["sonnet"])
        #expect(BrowserAssistantModels.rows(viewing: .codex, query: "nothing", providers: providers, choices: choices, statuses: statuses).isEmpty)
    }

    @Test("The selector lays out at the narrow and wide dock widths", arguments: [(280.0, true), (352.0, false), (460.0, false)] as [(CGFloat, Bool)])
    func pickerFits(width: CGFloat, narrow: Bool) {
        let provider = DesignProvider()
        let conversation = designConversation(provider, sources: [])
        let picker = BrowserAssistantModelPicker(conversation: conversation, choices: choices, statuses: statuses, width: width, narrow: narrow)
        let host = NSHostingView(rootView: picker)
        #expect(abs(host.fittingSize.width - width) < 1)
        // Ideal height holds the search field, two rows and the reasoning levels of the current model.
        #expect(host.fittingSize.height >= 100 && host.fittingSize.height < 420)
    }
}
