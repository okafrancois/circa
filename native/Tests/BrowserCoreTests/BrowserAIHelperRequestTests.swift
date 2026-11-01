import Foundation
import Testing
@testable import BrowserCore

private actor HelperProvider: BrowserAIProviderClient {
    nonisolated let id: BrowserAIProviderID = .codex
    var requests = 0
    func status(refresh: Bool) async -> BrowserAIProviderStatus { .init(id: id, state: .signedOut) }
    func shutdown() async {}
    func startTurn(_ request: BrowserAITurnRequest) async -> BrowserAITurn {
        requests += 1
        return BrowserAITurn(events: AsyncStream { continuation in
            continuation.yield(.text("Result")); continuation.yield(.completed); continuation.finish()
        }, interrupt: {})
    }
}

@Suite @MainActor struct BrowserAIHelperRequestTests {
    @Test func staleExtractionNeverStartsProvider() async {
        let provider = HelperProvider(), request = BrowserAIHelperRequest()
        var current = true
        var preferences = BrowserAIPreferences(); preferences.isEnabled = true
        do {
            _ = try await request.run(client: provider, choice: .init(provider: .codex), instructions: "Summarize",
                preferences: { preferences }, isCurrent: { current }, extract: { current = false; return "Old page" })
            Issue.record("Stale page was accepted")
        } catch {}
        #expect(await provider.requests == 0)
    }

    @Test func changedPreferencesDuringExtractionNeverStartsProvider() async {
        let provider = HelperProvider(), request = BrowserAIHelperRequest()
        var preferences = BrowserAIPreferences(); preferences.isEnabled = true
        do {
            _ = try await request.run(client: provider, choice: .init(provider: .codex), instructions: "Summarize",
                preferences: { preferences }, isCurrent: { true }, extract: {
                    preferences.helpers.linkPreviewSummaries = false
                    return "Page"
                })
            Issue.record("Changed permission was accepted")
        } catch {}
        #expect(await provider.requests == 0)
    }

    @Test func boundedOutputAndExplicitProvider() async throws {
        let provider = HelperProvider(), request = BrowserAIHelperRequest()
        var preferences = BrowserAIPreferences(); preferences.isEnabled = true
        let output = try await request.run(client: provider, choice: .init(provider: .codex), instructions: "Summarize",
            preferences: { preferences }, isCurrent: { true }, extract: { "Page" })
        #expect(output == "Result")
        do {
            _ = try await request.run(client: provider, choice: .init(provider: .claudeCode), instructions: "Summarize",
                preferences: { preferences }, isCurrent: { true }, extract: { "Page" })
            Issue.record("Provider mismatch was accepted")
        } catch {}
        #expect(await provider.requests == 1)
    }

    @Test func cancellationDuringExtractionNeverStartsProvider() async {
        let provider = HelperProvider(), request = BrowserAIHelperRequest()
        var preferences = BrowserAIPreferences(); preferences.isEnabled = true
        do {
            _ = try await request.run(client: provider, choice: .init(provider: .codex), instructions: "Summarize",
                preferences: { preferences }, isCurrent: { true }, extract: {
                    request.cancel()
                    return "Page"
                })
            Issue.record("Cancelled extraction was accepted")
        } catch {}
        #expect(await provider.requests == 0)
    }

    @Test func oversizedOutputIsRejected() async {
        let provider = HelperProvider(), request = BrowserAIHelperRequest()
        var preferences = BrowserAIPreferences(); preferences.isEnabled = true
        do {
            _ = try await request.run(client: provider, choice: .init(provider: .codex), instructions: "Summarize",
                preferences: { preferences }, isCurrent: { true }, extract: { "Page" }, outputLimit: 3)
            Issue.record("Oversized output was accepted")
        } catch let error as BrowserAIError {
            #expect(error == .failed)
        } catch { Issue.record("Unexpected error") }
    }

    @Test func namesCannotBecomePathsOrChangeExtension() {
        #expect(BrowserAIHelperName.download("Invoice", original: "source.pdf") == "Invoice.pdf")
        #expect(BrowserAIHelperName.download("Invoice.PDF", original: "source.pdf") == "Invoice.pdf")
        #expect(BrowserAIHelperName.download("Invoice.exe", original: "source.pdf") == "Invoice.exe.pdf")
        for value in ["../invoice", "/tmp/invoice", "a:b", "a\\b", ".hidden", "a\nb", ""] {
            #expect(BrowserAIHelperName.download(value, original: "source.pdf") == nil)
        }
    }
}
