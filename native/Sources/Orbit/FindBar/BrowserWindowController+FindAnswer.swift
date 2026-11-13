import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import SwiftUI

extension BrowserWindowController {
    var findAskChoice: BrowserAIModelChoice? {
        guard let preferences = settingsPreferences?.runtime.document.ai,
              preferences.helpers.askInFind, let service = aiService,
              let surface = findOwner, pageCommandSurface() === surface,
              surface.profileID == session.activeProfileID,
              let url = surface.navigationState.committedURL,
              ["http", "https"].contains(url.scheme ?? ""),
              BrowserAIPolicy.allowsPageAccess(preferences, isPrivate: isPrivateWindow, host: url.host) else { return nil }
        let choice = preferences.defaultModels[.chat]
            ?? BrowserAIPolicy.automaticChoice(for: .chat, statuses: service.statuses)
        guard let choice, BrowserAIPolicy.choices(for: .chat, statuses: service.statuses).contains(choice),
              let status = service.statuses[choice.provider], status.state.isReady,
              status.state.usage?.limitReached != true else { return nil }
        return choice
    }

    func cancelFindAnswer() {
        findAnswer?.close()
        findAnswer = nil
        findAnswerIsCurrent = nil
        findBarStorage?.setAnswer(nil)
    }

    func reconcileFindAnswer() {
        if findAnswerIsCurrent?() == false { cancelFindAnswer() }
        if let query = findSession.state?.query {
            findBarStorage?.offerAsk(findAskChoice != nil && BrowserFindQuestion.isQuestion(query))
        }
    }

    func askInFind() {
        guard let choice = findAskChoice, let service = aiService, let owner = findOwner,
              let reader = owner as? any BrowserAIPageReading,
              let state = findSession.state, state.isVisible, BrowserFindQuestion.isQuestion(state.query),
              let url = owner.navigationState.committedURL,
              let preferences = settingsPreferences?.runtime.document.ai else { return }
        cancelFindAnswer()
        let query = state.query
        let revision = owner.documentGeneration
        let source = BrowserAIContextSource(id: UUID(), revision: revision, url: url, title: url.host ?? "")
        let valid: @MainActor () -> Bool = { [weak self, weak owner] in
            guard let self, let owner else { return false }
            return self.findOwner === owner && self.pageCommandSurface() === owner
                && owner.documentGeneration == revision && self.findSession.state?.isVisible == true
                && self.findSession.state?.query == query && self.findAskChoice == choice
                && self.settingsPreferences?.runtime.document.ai == preferences
        }
        let conversation = BrowserAIConversation(choice: choice, clients: [service.client(choice.provider)],
            budgets: .init(prompt: 2_000, history: 0, pages: 16_000, sources: 1, output: 4_096), requiresContext: true,
            preferences: { valid() ? preferences : .init() },
            isPrivate: { !valid() }, currentSource: { id in valid() && id == source.id ? source : nil },
            reader: { _ in
                guard valid() else { throw CancellationError() }
                let text = try await reader.readAIPage(revision: revision, isCurrent: valid)
                guard valid() else { throw CancellationError() }
                return text
            })
        conversation.select(source)
        findAnswer = conversation
        findAnswerIsCurrent = valid
        let view = BrowserFindAnswerView(conversation: conversation, theme: windowShell.theme, height: { [weak self] in self?.findBarStorage?.resizeAnswer($0) }, jump: { citation in
            guard valid(), citation.snapshot.source == source else { return false }
            let highlighted = (try? await reader.highlightAIPassage(citation.passage, revision: revision, isCurrent: valid)) ?? false
            return valid() && highlighted
        })
        findBar.setAnswer(NSHostingView(rootView: view))
        conversation.send(query + "\nAnswer briefly, in at most 120 words, with a citation to the supplied page.")
    }
}

private struct BrowserFindAnswerView: View {
    let conversation: BrowserAIConversation
    let theme: OrbitTokens.SpaceTheme
    let height: (CGFloat) -> Void
    let jump: (BrowserAICitation) async -> Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var unavailable = false
    private var palette: BrowserAssistantPalette {
        let dark = colorScheme == .dark
        return BrowserAssistantPalette(theme: theme, appearance: NSAppearance(named: dark ? .darkAqua : .aqua)!, polarity: dark)
    }
    private func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).boundingRect(with: NSSize(width: max(80, width), height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)]).height) + 4
    }
    var body: some View {
        GeometryReader { proxy in
            let message = conversation.messages.last
            let text = message.map(BrowserAICitation.displayText) ?? ""
            let citation = message.flatMap { BrowserAICitation.parse($0).first }
            let error: String = {
                guard let message else { return "" }
                if case .failed(let failure) = message.state { return browserAssistantErrorText(failure) }
                return message.state == .stopped ? uiText("Stopped") : ""
            }()
            let width = proxy.size.width - 44
            let content = max(24, textHeight(text, width: width)
                + (citation == nil ? 0 : 30) + textHeight(error, width: width)
                + (unavailable ? textHeight(uiText("This passage is no longer available."), width: width) + 6 : 0))
            let visible = min(220, content)
            let total = visible + 19 + (conversation.isRunning ? 28 : 0)
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if text.isEmpty && conversation.isRunning { BrowserAssistantThinkingView() }
                        if !text.isEmpty { Text(text).textSelection(.enabled) }
                        if !error.isEmpty { Text(error) }
                        if let citation {
                            Button { Task { unavailable = !(await jump(citation)) } } label: {
                                HStack(spacing: 4) {
                                    OrbitIcon.view(sfName: "arrow.down", pointSize: 12)
                                    Text(uiText("Jump to passage"))
                                }
                            }.buttonStyle(.plain).foregroundStyle(palette.accentInk.swiftUI)
                                .accessibilityIdentifier("find-answer-jump")
                        }
                        if unavailable { Text(uiText("This passage is no longer available.")) }
                    }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }.frame(height: visible)
                if conversation.isRunning { Button(uiText("Stop")) { conversation.stop() }.buttonStyle(.plain) }
            }.font(.system(size: 13)).foregroundStyle(palette.ink.swiftUI)
                .padding(.leading, 30).padding(.trailing, 14).padding(.bottom, 10)
                .environment(\.assistantPalette, palette)
                .onAppear { height(total) }.onChange(of: total) { height($0) }
        }
    }
}
