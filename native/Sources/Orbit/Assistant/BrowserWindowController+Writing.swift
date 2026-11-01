import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

extension BrowserWindowController {
    var writingChoice: BrowserAIModelChoice? {
        guard let preferences = settingsPreferences?.runtime.document.ai,
              preferences.helpers.writingHelp, let service = aiService,
              let owner = pageCommandSurface(), owner.profileID == session.activeProfileID,
              owner.hostView.window === window, let url = owner.navigationState.committedURL,
              ["http", "https"].contains(url.scheme ?? ""),
              BrowserAIPolicy.allowsPageAccess(preferences, isPrivate: isPrivateWindow, host: url.host) else { return nil }
        let choice = preferences.defaultModels[.quick] ?? BrowserAIPolicy.automaticChoice(for: .quick, statuses: service.statuses)
        guard let choice, BrowserAIPolicy.choices(for: .quick, statuses: service.statuses).contains(choice),
              let status = service.statuses[choice.provider], status.state.isReady,
              status.state.usage?.limitReached != true else { return nil }
        return choice
    }

    func installWritingHelp() {
        guard writingHelp == nil, let window else { return }
        let help = BrowserWritingHelp()
        writingHelp = help
        help.palette = { [weak self] in
            let appearance = self?.window?.effectiveAppearance ?? NSAppearance(named: .aqua)!
            return BrowserAssistantPalette(theme: self?.windowShell.theme ?? .default, appearance: appearance)
        }
        help.acceptsInput = { [weak self] event in
            guard let self, writingChoice != nil, let owner = pageCommandSurface(), let window = self.window else { return false }
            if event.type == .leftMouseUp || event.type == .leftMouseDown || event.type == .scrollWheel {
                return owner.hostView.bounds.contains(owner.hostView.convert(event.locationInWindow, from: nil))
            }
            guard let responder = window.firstResponder as? NSView else { return false }
            return responder === owner.hostView || responder.isDescendant(of: owner.hostView)
        }
        help.capture = { [weak self] in await self?.captureWritingContext() }
        help.ask = { [weak self] text in
            guard let self else { return }
            palette.present(.newTab)
            palette.query(text, userInitiated: true)
            palette.renderContext()
        }
        help.install(in: window)
    }

    private func captureWritingContext() async -> BrowserWritingHelp.Context? {
        guard let choice = writingChoice, let service = aiService, let owner = pageCommandSurface(),
              let writer = owner as? any BrowserAIWriting, let window,
              let preferences = settingsPreferences?.runtime.document.ai else { return nil }
        let revision = owner.documentGeneration
        let valid: @MainActor () -> Bool = { [weak self, weak owner] in
            guard let self, let owner else { return false }
            return pageCommandSurface() === owner && owner.documentGeneration == revision
                && writingChoice == choice && settingsPreferences?.runtime.document.ai == preferences
                && self.window?.isVisible == true
        }
        guard valid(), let selection = try? await writer.writingSelection(revision: revision, isCurrent: valid), valid() else { return nil }
        let view = owner.hostView
        let box = selection.bounds
        let local = NSRect(x: box.minX, y: view.isFlipped ? box.minY : view.bounds.height - box.maxY,
                           width: box.width, height: box.height)
        let anchor = window.convertToScreen(view.convert(local, to: nil))
        return .init(selection: selection, anchor: anchor, preferences: preferences, choice: choice,
                     client: service.client(choice.provider), isCurrent: valid,
                     read: { try await writer.writingSelection(revision: revision, isCurrent: valid) },
                     apply: { text, below in
                         try await writer.applyWriting(text, selection: selection, insertBelow: below,
                                                       revision: revision, isCurrent: valid)
                     })
    }
}
