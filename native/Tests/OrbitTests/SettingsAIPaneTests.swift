import AppKit
import BrowserCore
import BrowserShell
import SwiftUI
import Testing
import BrowserEngineConformance
@testable import Orbit

@MainActor
struct SettingsAIPaneTests {
    private func model() -> BrowserSettingsModel<SyntheticEngine> {
        BrowserSettingsModel(environment: BrowserEnvironment(engine: SyntheticEngine()), profileID: nil, shortcuts: [],
            defaultBrowser: .init(status: { .init(http: "synthetic", https: "synthetic", html: "synthetic") },
                canRequest: { false }, request: { Issue.record("Unexpected system request") }))
    }

    private static let reset = Date(timeIntervalSince1970: 1_796_053_740)
    private static var statuses: [BrowserAIProviderID: BrowserAIProviderStatus] {
        let codex = [BrowserAIModel(provider: .codex, id: "gpt-6-luna", displayName: "GPT-6-Luna", efforts: ["low", "high"], isDefault: true)]
        return [
            .codex: BrowserAIProviderStatus(id: .codex, state: .ready(.init(plan: "free", usage: BrowserAIUsage(windows: [
                BrowserAIUsageWindow(span: .minutes(43_200), usedPercent: 100, resetsAt: reset)]))), models: codex,
                programURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex"), version: "0.165.0"),
            .claudeCode: BrowserAIProviderStatus(id: .claudeCode, state: .signedOut, models: BrowserAIClaudeLaunch.models),
            .onDevice: BrowserAIProviderStatus(id: .onDevice, state: .unavailable(.appleIntelligenceOff)),
        ]
    }

    @Test("AI is ⌘5, Advanced ⌘6 and About ⌘7, in the toolbar and its menu equivalents")
    func shortcuts() throws {
        #expect(BrowserSettingsSection.allCases.firstIndex(of: .ai) == 4)
        #expect(BrowserSettingsSection.allCases.firstIndex(of: .advanced) == 5)
        #expect(BrowserSettingsSection.allCases.firstIndex(of: .about) == 6)
        #expect(BrowserSettingsSection.ai.title == "AI" && BrowserSettingsSection.ai.symbol == "sparkles")
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = model()
        let controller = BrowserSettingsWindowController(model: model)
        let window = try #require(controller.window)
        defer { window.close() }
        let items = try #require(window.toolbar?.items)
        for (key, code, section) in [("5", UInt16(23), BrowserSettingsSection.ai), ("6", 22, .advanced), ("7", 26, .about)] {
            let item = try #require(items.first { $0.itemIdentifier == section.toolbarIdentifier })
            #expect(item.menuFormRepresentation?.keyEquivalent == key)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: code))
            #expect(window.performKeyEquivalent(with: event))
            #expect(model.settingsSection == section)
        }
    }

    @Test("The pane renders every program state in light and dark without starting a program")
    func rendersWithoutPrograms() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = model()
        let ai = model.environment.ai
        #expect(model.environment.startsAIPrograms == false)
        ai.refresh(keepRunning: false)
        for _ in 0..<200 where ai.isChecking { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(ai.statuses[.codex]?.state == .notInstalled && ai.statuses[.claudeCode]?.state == .notInstalled)
        #expect(BrowserAIProcess.runningCount == 0)
        try await model.runtime.updateAI { $0.isEnabled = true }
        ai.statuses = Self.statuses
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: ScrollView {
                BrowserSettingsAIPane(model: model, runtime: model.runtime, ai: ai).padding(28)
            }.frame(width: 684, height: 900))
            host.appearance = NSAppearance(named: appearance)
            host.setFrameSize(NSSize(width: 684, height: 900))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0)
        }
        // Rendering on appear re-checks with the inert providers only.
        for _ in 0..<200 where ai.isChecking { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(BrowserAIProcess.runningCount == 0)
        #expect(BrowserSettingsAIPane<SyntheticEngine>.shippedHelpers.isEmpty)
    }

    @Test("Usage meters, reset times, plans and model labels")
    func texts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let locale = Locale(identifier: "en_GB")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 10)))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 14, minute: 20)))
        let monday = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 18)))
        let later = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 15, minute: 49)))
        #expect(BrowserSettingsAIText.resetTime(today, now: now, calendar: calendar, locale: locale) == "14:20")
        #expect(BrowserSettingsAIText.resetTime(monday, now: now, calendar: calendar, locale: locale) == "Monday")
        #expect(BrowserSettingsAIText.resetTime(later, now: now, calendar: calendar, locale: locale) == "30 Nov")
        #expect(BrowserSettingsAIText.span(.fiveHours) == "5 hours" && BrowserSettingsAIText.span(.week) == "Week")
        #expect(BrowserSettingsAIText.span(.minutes(43_200)) == "Month")
        #expect(BrowserSettingsAIText.meter(BrowserAIUsageWindow(span: .week, usedPercent: 18, resetsAt: nil), limitReached: false) == "18%")
        #expect(BrowserSettingsAIText.meter(BrowserAIUsageWindow(span: .week, usedPercent: 100, resetsAt: nil), limitReached: true) == "Limit reached")
        #expect(BrowserSettingsAIText.plan(.codex, "pro") == "ChatGPT Pro" && BrowserSettingsAIText.plan(.claudeCode, "max") == "Claude Max")
        #expect(BrowserSettingsAIText.plan(.codex, "apiKey") == "API key" && BrowserSettingsAIText.plan(.codex, "unknown-tier") == "ChatGPT")
        let statuses = Self.statuses
        #expect(BrowserSettingsAIText.choice(BrowserAIModelChoice(provider: .codex, model: "gpt-6-luna", effort: "high"), statuses: statuses)
            == "Codex · GPT-6-Luna · High")
        #expect(BrowserSettingsAIText.choice(BrowserAIModelChoice(provider: .claudeCode, model: "sonnet"), statuses: statuses) == "Claude Code · Sonnet")
        #expect(BrowserSettingsAIText.choice(BrowserAIModelChoice(provider: .onDevice), statuses: statuses) == "On This Mac")
        #expect(BrowserSettingsAIText.reason(statuses[.claudeCode]?.state) == "Signed out")
        #expect(BrowserSettingsAIText.reason(statuses[.codex]?.state) == nil)
        #expect(BrowserSettingsAIMark.image(.codex) != nil && BrowserSettingsAIMark.image(.claudeCode) != nil)
    }

    @Test("Program monograms contain visible ink in both appearances")
    func monogramInk() throws {
        for provider in [BrowserAIProviderID.codex, .claudeCode] {
            for isDark in [false, true] {
                let image = try #require(BrowserSettingsAIMark.image(provider, isDark: isDark))
                let data = try #require(image.tiffRepresentation)
                let bitmap = try #require(NSBitmapImageRep(data: data))
                var inkPixels = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                        if isDark ? color.redComponent > 0.8 : color.redComponent < 0.2 { inkPixels += 1 }
                    }
                }
                #expect(inkPixels > 5)
            }
        }
    }

    @Test("The master switch is off by default and its change persists")
    func masterSwitch() async throws {
        let model = model()
        #expect(!model.runtime.document.ai.isEnabled)
        try await model.runtime.updateAI { $0.isEnabled = true }
        #expect(model.runtime.document.ai.isEnabled)
        #expect(OrbitOnDeviceAIClient.availability().state != .notInstalled)
    }
}

/// Opt-in check of the on-device model on this Mac: `CIRCA_AI_LIVE=1`. Never in CI.
@MainActor
struct SettingsAIOnDeviceLiveTests {
    @Test("On-device model streams a synthetic answer when Apple Intelligence is available",
          .enabled(if: ProcessInfo.processInfo.environment["CIRCA_AI_LIVE"] == "1"))
    func onDeviceLive() async throws {
        let client = OrbitOnDeviceAIClient()
        let status = await client.status(refresh: true)
        print("AI-LIVE on-device state: \(status.state)")
        guard status.state.isReady else { return }
        var text = ""
        var terminal: BrowserAITurnEvent?
        for await event in await client.startTurn(BrowserAITurnRequest(prompt: "Reply with one short sentence about the colour blue.")).events {
            if case .text(let delta) = event { text += delta } else if event.isTerminal { terminal = event }
        }
        print("AI-LIVE on-device answer: \(text)")
        #expect(terminal == .completed && !text.isEmpty)
    }
}
