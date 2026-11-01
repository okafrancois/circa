import AppKit
import BrowserCore
import BrowserShell
import SwiftUI

/// The bar keeps its question and presents only the current answer and its actions.
struct BrowserAssistantAnswerView: View {
    let conversation: BrowserAIConversation
    let choices: [BrowserAIModelChoice]
    var theme: OrbitTokens.SpaceTheme = .default
    var citation: (BrowserAICitation) async -> Bool
    var openSource: (BrowserAIContextSource) -> Void
    var continueInPanel: () -> Void
    @State private var unavailable = false
    @State private var activeCitation: String?
    @Environment(\.colorScheme) private var colorScheme

    /// The bar's material follows the window appearance, so the accent is guarded against that polarity.
    private var palette: BrowserAssistantPalette {
        let dark = colorScheme == .dark
        return BrowserAssistantPalette(theme: theme, appearance: NSAppearance(named: dark ? .darkAqua : .aqua)!, polarity: dark)
    }
    private var message: BrowserAIMessage? { conversation.messages.last.flatMap { $0.role == .assistant ? $0 : nil } }

    var body: some View {
        let palette = palette
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                ForEach(choices, id: \.self) { choice in
                    Button(choice.model ?? BrowserSettingsAIText.name(choice.provider)) { conversation.switchProvider(to: choice) }
                }
                if let usage = conversation.messages.last?.usage {
                    Divider()
                    ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                        Text(uiFormat("%ld%%", window.usedPercent))
                        if let reset = window.resetsAt { Text(reset, style: .time) }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    BrowserAssistantProviderMark(provider: conversation.choice.provider)
                    Text(conversation.choice.model ?? BrowserSettingsAIText.name(conversation.choice.provider))
                    if let usage = conversation.messages.last?.usage?.windows.first { Text(uiFormat("%ld%%", usage.usedPercent)) }
                }.font(.system(size: 12)).foregroundStyle(palette.secondary.swiftUI)
            }.menuStyle(.borderlessButton).fixedSize()
            ScrollView {
                if let message {
                    VStack(alignment: .leading, spacing: 8) {
                        if message.text.isEmpty && message.state == .streaming { BrowserAssistantThinkingView() }
                        if !BrowserAICitation.segments(message).isEmpty {
                            BrowserAssistantAnswerText(message: message, open: { open($0) }, activeCitation: activeCitation)
                        }
                        if message.state == .stopped { Text(uiText("Stopped")).foregroundStyle(palette.secondary.swiftUI) }
                        if case .failed(let error) = message.state { Text(browserAssistantErrorText(error)).foregroundStyle(palette.secondary.swiftUI) }
                        let sources = uniqueCitations(message)
                        if !sources.isEmpty {
                            BrowserAssistantFlowLayout {
                                ForEach(sources) { source in
                                    Button { open(source) } label: {
                                        HStack(spacing: 6) {
                                            BrowserAssistantCitationNumber(number: source.number)
                                            Text(source.snapshot.source.title).lineLimit(1).truncationMode(.tail)
                                        }.font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondary.swiftUI)
                                            .padding(.leading, 6).padding(.trailing, 9).frame(height: 28)
                                    }.buttonStyle(BrowserAssistantButtonStyle(kind: .outlined(radius: 8)))
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.font(.system(size: 13))
            if unavailable { Text(uiText("This passage is no longer available.")).font(.system(size: 12)).foregroundStyle(palette.secondary.swiftUI) }
            HStack(spacing: 16) {
                Spacer(minLength: 0)
                if conversation.isRunning {
                    Button(uiText("Stop")) { conversation.stop() }
                } else {
                    Menu(uiText("Open Sources")) {
                        ForEach(conversation.messages.last?.context ?? [], id: \.source.id) { snapshot in
                            Button(snapshot.source.title) { openSource(snapshot.source) }
                        }
                    }.disabled(conversation.messages.last?.context.isEmpty != false)
                    Button(uiText("Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.map(BrowserAICitation.displayText) ?? "", forType: .string)
                    }
                    Button(uiText("Continue in Panel"), action: continueInPanel)
                }
            }.font(.system(size: 13, weight: .medium)).buttonStyle(.plain)
        }.padding(.leading, 34).padding(.trailing, 12).padding(.vertical, 8)
            .foregroundStyle(palette.ink.swiftUI)
            .environment(\.assistantPalette, palette)
    }

    private func uniqueCitations(_ message: BrowserAIMessage) -> [BrowserAICitation] {
        var numbers: Set<Int> = []
        return BrowserAICitation.parse(message).filter { numbers.insert($0.number).inserted }
    }

    private func open(_ source: BrowserAICitation) {
        activeCitation = source.id
        Task {
            let shown = await citation(source)
            unavailable = !shown
            if !shown { activeCitation = nil }
        }
    }
}

struct BrowserAssistantThinkingView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.assistantPalette) private var palette
    private var reduced: Bool { systemReduced || OrbitMotionPreferences.prefersReducedMotion }
    private var sparkle: some View {
        OrbitIcon.view(sfName: "sparkles", pointSize: 16).font(.system(size: 14)).foregroundStyle(palette.accentInk.swiftUI)
    }
    var body: some View {
        HStack(spacing: 8) {
            if reduced {
                sparkle
                Text(uiText("Thinking")).foregroundStyle(palette.secondary.swiftUI)
            } else {
                TimelineView(.animation) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    let pulse = time.truncatingRemainder(dividingBy: 2.4) / 2.4
                    let shimmer = time.truncatingRemainder(dividingBy: 1.6) / 1.6
                    HStack(spacing: 8) {
                        sparkle.scaleEffect(0.99 - 0.07 * cos(pulse * 2 * .pi))
                        Text(uiText("Thinking")).foregroundStyle(palette.secondary.swiftUI).overlay {
                            LinearGradient(colors: [.clear, palette.ink.swiftUI, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 24).offset(x: shimmer * 140 - 70)
                                .mask(Text(uiText("Thinking")))
                        }
                    }
                }
            }
        }.font(.system(size: 14))
    }
}

func browserAssistantErrorText(_ error: BrowserAIError) -> String {
    switch error {
    case .limitReached: uiText("Usage limit reached. Choose another model or wait.")
    case .signedOut: uiText("Signed out")
    case .notInstalled: uiText("Program not installed")
    case .unavailable: uiText("Model unavailable")
    case .failed: uiText("Unable to answer. Choose a model or try again.")
    }
}
