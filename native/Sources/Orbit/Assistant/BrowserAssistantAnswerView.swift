import AppKit
import BrowserCore
import BrowserShell
import SwiftUI

/// The bar keeps its question and presents only the current answer and its actions.
struct BrowserAssistantAnswerView: View {
    let conversation: BrowserAIConversation
    let choices: [BrowserAIModelChoice]
    var citation: (BrowserAICitation) async -> Bool
    var openSource: (BrowserAIContextSource) -> Void
    var continueInPanel: () -> Void
    @State private var unavailable = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                ForEach(choices, id: \.self) { choice in
                    Button(choice.model ?? BrowserSettingsAIText.name(choice.provider)) { conversation.switchProvider(to: choice) }
                }
                if let usage = conversation.messages.last?.usage {
                    Divider()
                    ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                        Text("\(window.usedPercent)%")
                        if let reset = window.resetsAt { Text(reset, style: .time) }
                    }
                }
            } label: {
            HStack(spacing: 7) {
                BrowserAssistantProviderMark(provider: conversation.choice.provider)
                Text(conversation.choice.model ?? BrowserSettingsAIText.name(conversation.choice.provider))
                if let usage = conversation.messages.last?.usage?.windows.first { Text("\(usage.usedPercent)%") }
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            }.menuStyle(.borderlessButton).fixedSize()
            ScrollView {
                if let message = conversation.messages.last, message.role == .assistant {
                    VStack(alignment: .leading, spacing: 8) {
                        if message.text.isEmpty && message.state == .streaming { BrowserAssistantThinkingView() }
                        BrowserAssistantStreamingText(message: message).textSelection(.enabled)
                        if message.state == .stopped { Text(uiText("Stopped")).foregroundStyle(.secondary) }
                        if case .failed(let error) = message.state { Text(browserAssistantErrorText(error)).foregroundStyle(.secondary) }
                        ForEach(BrowserAICitation.parse(message)) { source in
                            Button("[\(source.number)] " + source.snapshot.source.title) { Task { unavailable = !(await citation(source)) } }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.font(.system(size: 13)).lineSpacing(4)
            if unavailable { Text(uiText("This passage is no longer available.")).font(.system(size: 12)).foregroundStyle(.secondary) }
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
                        NSPasteboard.general.setString(conversation.messages.last?.text ?? "", forType: .string)
                    }
                    Button(uiText("Continue in Panel"), action: continueInPanel)
                }
            }.font(.system(size: 13, weight: .medium)).buttonStyle(.plain)
        }.padding(.leading, 34).padding(.trailing, 12).padding(.vertical, 8)
    }
}

struct BrowserAssistantProviderMark: View {
    let provider: BrowserAIProviderID
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if provider == .onDevice {
                OrbitIcon.view(sfName: "laptopcomputer", pointSize: 16)
            } else if let mark = BrowserSettingsAIMark.image(provider, isDark: colorScheme == .dark) {
                Image(nsImage: mark).resizable()
            }
        }.frame(width: 18, height: 18).accessibilityHidden(true)
    }
}

struct BrowserAssistantThinkingView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    private var reduced: Bool { systemReduced || OrbitMotionPreferences.prefersReducedMotion }
    var body: some View {
        HStack(spacing: 8) {
            if reduced {
                Image(systemName: "sparkles").font(.system(size: 16))
            } else {
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                    Image(systemName: "sparkles").font(.system(size: 16))
                        .scaleEffect(0.99 - 0.07 * cos(phase * 2 * .pi))
                }
            }
            if reduced { Text(uiText("Thinking")) } else {
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    Text(uiText("Thinking")).foregroundStyle(.secondary)
                        .overlay {
                            LinearGradient(colors: [.clear, Color(nsColor: .labelColor), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 24).offset(x: phase * 140 - 70)
                                .mask(Text(uiText("Thinking")))
                        }
                }
            }
        }.foregroundStyle(.secondary).font(.system(size: 13))
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

struct BrowserAssistantStreamingText: View {
    let message: BrowserAIMessage
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    private var reduced: Bool { systemReduced || OrbitMotionPreferences.prefersReducedMotion }
    @State private var visible: Set<UUID> = []
    var body: some View {
        rendered.onChange(of: message.chunks.map(\.id), initial: true) { _, ids in
            Task { @MainActor in
                await Task.yield()
                withAnimation(.linear(duration: reduced ? 0.15 : 0.12)) { visible.formUnion(ids) }
            }
        }
    }
    private var rendered: Text {
        guard !message.chunks.isEmpty else { return Text(message.text) }
        return message.chunks.reduce(Text("")) { result, chunk in
            result + Text(chunk.text).foregroundColor(Color.primary.opacity(visible.contains(chunk.id) ? 1 : 0))
        }
    }
}
