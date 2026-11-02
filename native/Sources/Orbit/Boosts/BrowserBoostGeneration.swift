import AppKit
import BrowserCore
import BrowserEngine

@MainActor
final class BrowserBoostGeneration {
    struct Context {
        let choice: BrowserAIModelChoice
        let client: any BrowserAIProviderClient
        let preferences: @MainActor () -> BrowserAIPreferences
        let isCurrent: @MainActor () -> Bool
        let read: @MainActor () async throws -> String
        let preview: @MainActor (String, UUID) async throws -> Bool
        let clear: @MainActor (UUID) async -> Void
    }
    let session: BrowserBoostEditorSession
    var capture: (() -> Context?)?
    var unavailableText: (() -> String)?
    var onChange: (() -> Void)?
    private let request = BrowserAIHelperRequest()
    private var task: Task<Void, Never>?
    private var validation: Task<Void, Never>?
    private var clearing: Task<Void, Never>?
    private var needsValidation = false
    private var hasDraft = false
    private var epoch = UUID()
    private var context: Context?
    private var expected: BrowserBoostDocument?
    private(set) var output = ""
    private(set) var error = ""
    private(set) var running = false
    private(set) var ready = false
    private(set) var applying = false
    var isDraftVisible: Bool { hasDraft }

    init(session: BrowserBoostEditorSession) {
        self.session = session
        session.onInvalidateDraft = { [weak self] in self?.cancel() }
    }
    func cancel() {
        let old = epoch, context = context
        epoch = UUID(); request.cancel(); task?.cancel(); validation?.cancel()
        self.context = nil; expected = nil; output = ""; error = ""; running = false; ready = false; applying = false; needsValidation = false; hasDraft = false
        let previousClear = clearing
        if let context { clearing = Task { await previousClear?.value; await context.clear(old) } }
        onChange?()
    }
    func stop() { cancel(); error = uiText("Stopped"); onChange?() }

    func run(_ prompt: String) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancel()
        guard !session.isClosed, !session.isDeleting, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.count <= 2000, prompt.utf8.count <= 4000, let next = capture?(), next.isCurrent() else {
            error = unavailableText?() ?? uiText("AI is unavailable"); onChange?(); return
        }
        context = next; hasDraft = true; running = true; onChange?()
        let token = epoch
        task = Task { [weak self] in
            guard let self else { return }
            do {
                await session.pending?.value
                let snapshot = await session.store.snapshot()
                guard valid(token), snapshot.boosts.contains(session.boost) else { throw CancellationError() }
                expected = snapshot
                let result = try await request.run(client: next.client, choice: next.choice,
                    instructions: "Generate only plain CSS for the user's requested page change. No markdown, HTML, JavaScript, tools, imports, URLs, functions, escapes, resources or at-rules. Use visible tag, id and class selectors. Use only simple CSS display, visibility, opacity, color, background-color, dimensions, margin, padding, typography, border-radius, gap, grid-template-columns and flex alignment declarations. User request: " + prompt,
                    preferences: next.preferences, isCurrent: { self.valid(token) }, extract: next.read,
                    outputLimit: 12000, onText: { text in
                        guard self.valid(token) else { return }; self.output = text; self.onChange?()
                    })
                guard valid(token), await session.store.snapshot() == snapshot else { throw CancellationError() }
                guard try await next.preview(result, token) else { throw BrowserAIError.failed }
                guard valid(token), await session.store.snapshot() == snapshot else {
                    await next.clear(token); throw CancellationError()
                }
                running = false; ready = true; onChange?()
                validation = Task { [weak self] in
                    while let self, !Task.isCancelled, epoch == token {
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled else { return }
                        let current = await session.store.snapshot()
                        guard !Task.isCancelled, epoch == token else { return }
                        if !valid(token) || current != snapshot { cancel(); return }
                    }
                }
            } catch {
                guard epoch == token else { return }
                await next.clear(token)
                guard epoch == token else { return }
                if error is CancellationError { cancel(); self.error = uiText("Stopped"); onChange?(); return }
                running = false; ready = false
                self.error = browserAssistantErrorText(error as? BrowserAIError ?? .failed)
                onChange?()
            }
        }
    }
    func editDraft(_ source: String) {
        guard isDraftVisible, !running, !applying, let context else { return }
        output = source; ready = true; error = ""; needsValidation = true
        let token = epoch, previousClear = clearing
        clearing = Task { await previousClear?.value; await context.clear(token) }
        onChange?()
    }

    private func valid(_ token: UUID) -> Bool {
        epoch == token && !session.isClosed && !session.isDeleting && context?.isCurrent() == true
    }
    func apply() {
        guard ready, !running, !applying, let expected, let context, valid(epoch) else { return }
        let token = epoch, css = output
        validation?.cancel()
        applying = true; onChange?()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                await clearing?.value
                guard valid(token) else { throw CancellationError() }
                if needsValidation {
                    guard try await context.preview(css, token), valid(token) else { throw BrowserAIError.failed }
                }
                try await session.applyGeneratedCSS(css, expected: expected, isCurrent: { self.valid(token) })
                await context.clear(token)
                guard epoch == token else { return }
                ready = false; output = ""; hasDraft = false
            } catch {
                await context.clear(token)
                guard epoch == token else { return }
                if error is CancellationError { cancel(); self.error = uiText("Stopped"); onChange?(); return }
                self.error = browserAssistantErrorText(error as? BrowserAIError ?? .failed); ready = false
            }
            applying = false; onChange?()
        }
    }
}

extension BrowserWindowController {
    var boostGenerationUnavailableText: String {
        guard let preferences = settingsPreferences?.runtime.document.ai,
              let surface = pageCommandSurface(),
              BrowserAIPolicy.allowsPageAccess(preferences, isPrivate: isPrivateWindow, host: surface.navigationState.committedURL?.host),
              let choice = preferences.defaultModels[.chat], let status = aiService?.statuses[choice.provider] else { return uiText("AI is unavailable") }
        switch status.state {
        case .signedOut: return browserAssistantErrorText(.signedOut)
        case .notInstalled: return browserAssistantErrorText(.notInstalled)
        case .unavailable(let reason): return browserAssistantErrorText(.unavailable(reason))
        case .ready(let account):
            return account.usage?.limitReached == true ? browserAssistantErrorText(.limitReached(resetsAt: account.usage?.limitResetsAt)) : uiText("AI is unavailable")
        }
    }

    var boostChatChoice: BrowserAIModelChoice? {
        guard let preferences = settingsPreferences?.runtime.document.ai, let service = aiService,
              let surface = pageCommandSurface(), surface.profileID == session.activeProfileID,
              let url = surface.navigationState.committedURL,
              ["http", "https"].contains(url.scheme ?? ""),
              BrowserAIPolicy.allowsPageAccess(preferences, isPrivate: isPrivateWindow, host: url.host) else { return nil }
        let choice = preferences.defaultModels[.chat] ?? BrowserAIPolicy.automaticChoice(for: .chat, statuses: service.statuses)
        guard let choice, choice.provider != .onDevice,
              BrowserAIPolicy.choices(for: .chat, statuses: service.statuses).contains(choice),
              let status = service.statuses[choice.provider], status.state.isReady,
              status.state.usage?.limitReached != true else { return nil }
        return choice
    }
    func boostGenerationContext(_ editor: BrowserBoostEditorController) -> BrowserBoostGeneration.Context? {
        guard let choice = boostChatChoice, let service = aiService, let surface = pageCommandSurface(),
              editor.pageHost === surface.hostView, let preview = surface as? any BrowserAIBoostPreview,
              surface.profileID == editor.session.store.profileID,
              settingsPreferences?.runtime.document.enablesBoostsOnWebsites != false,
              let url = surface.navigationState.committedURL,
              let match = try? BrowserBoostMatchTable(profileID: surface.profileID, boosts: [editor.session.boost]),
              !match.matching(url, in: surface.profileID).isEmpty,
              let preferences = settingsPreferences?.runtime.document.ai else { return nil }
        let revision = surface.documentGeneration, space = session.snapshot?.activeSpaceID
        let occurrence = session.snapshot?.selectedOccurrenceID
        let valid: @MainActor () -> Bool = { [weak self, weak surface, weak editor] in
            guard let self, let surface, let editor else { return false }
            return !editor.session.isClosed && isBoostPageTarget(surface) && surface.documentGeneration == revision && surface.navigationState.committedURL == url
                && session.snapshot?.activeSpaceID == space && session.snapshot?.selectedOccurrenceID == occurrence
                && session.activeProfileID == surface.profileID && acceptsCommands
                && settingsPreferences?.runtime.document.enablesBoostsOnWebsites != false
                && boostChatChoice == choice && settingsPreferences?.runtime.document.ai == preferences
        }
        return .init(choice: choice, client: service.client(choice.provider),
                     preferences: { [weak self] in self?.settingsPreferences?.runtime.document.ai ?? .init() },
                     isCurrent: valid, read: { try await preview.readBoostStructure(revision: revision, isCurrent: valid) },
                     preview: { try await preview.previewBoostCSS($0, lease: $1, revision: revision, isCurrent: valid) },
                     clear: { await preview.clearBoostPreview(lease: $0, revision: revision) })
    }
}
