import AppKit
import BrowserCore
import BrowserShell
import SwiftUI

struct BrowserAssistantView: View {
    let conversation: BrowserAIConversation
    let choices: [BrowserAIModelChoice]
    let sources: [BrowserAIContextSource]
    let scopes: [String: [BrowserAIContextSource]]
    let enabled: Bool
    var citation: (BrowserAICitation) async -> Bool
    var close: () -> Void
    var continueInPanel: (() -> Void)?
    @State private var citationUnavailable = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(uiText("Assistant")).font(.system(size: 13, weight: .medium))
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            Menu {
                ForEach(choices, id: \.self) { choice in
                    Button(choice.model ?? choice.provider.rawValue) { conversation.switchProvider(to: choice) }
                }
            } label: { Text(conversation.choice.model ?? conversation.choice.provider.rawValue).font(.system(size: 12)) }
            if let usage = conversation.messages.last?.usage {
                ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                    ProgressView(value: Double(window.usedPercent), total: 100)
                        .tint(window.isFull ? .red : window.usedPercent >= 80 ? .orange : .accentColor)
                    Text("\(window.usedPercent)%").font(.system(size: 11))
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(conversation.messages) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            if message.text.isEmpty && message.state == .streaming {
                                HStack { ProgressView().controlSize(.small); Text(uiText("Thinking")) }
                            } else { Text(message.text).textSelection(.enabled) }
                            if message.state == .stopped { Text(uiText("Stopped")).foregroundStyle(.secondary) }
                            if case .failed(let error) = message.state { Text(errorText(error)).foregroundStyle(.secondary) }
                            ForEach(BrowserAICitation.parse(message)) { source in
                                Button("[\(source.number)] " + source.snapshot.source.title) { Task { citationUnavailable = !(await citation(source)) } }
                            }
                            if message.role == .assistant && !message.text.isEmpty {
                                Button(uiText("Copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
                            }
                        }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if citationUnavailable { Text(uiText("This passage is no longer available.")).font(.system(size: 12)).foregroundStyle(.secondary) }
            if let continueInPanel { Button(uiText("Continue in Panel"), action: continueInPanel) }
            ScrollView(.horizontal) {
                HStack {
                    ForEach(conversation.selectedSources) { source in
                        HStack { Text(source.title); Button { conversation.removeSource(source.id) } label: { Image(systemName: "xmark") } }
                            .font(.system(size: 11)).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    Menu {
                        ForEach(sources) { source in Button(source.title) { conversation.select(source) } }
                        ForEach(scopes.keys.sorted(), id: \.self) { name in
                            Button(name) { for source in scopes[name] ?? [] { conversation.select(source) } }
                        }
                    } label: { Image(systemName: "at") }
                }
            }
            HStack {
                TextField(uiText("Ask a question"), text: $draft).onSubmit(send)
                Button { if conversation.isRunning { conversation.stop() } else { send() } } label: {
                    Image(systemName: conversation.isRunning ? "stop.fill" : "arrow.up")
                }.disabled(!enabled || (!conversation.isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }.padding(16).background(Color(nsColor: .windowBackgroundColor)).cornerRadius(6)
    }
    private func errorText(_ error: BrowserAIError) -> String {
        switch error {
        case .limitReached: uiText("Usage limit reached. Choose another model or wait.")
        case .signedOut: uiText("Signed out")
        case .notInstalled: uiText("Program not installed")
        case .unavailable: uiText("Model unavailable")
        case .failed: uiText("Unable to answer. Choose a model or try again.")
        }
    }
    private func send() {
        guard enabled, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if conversation.send(draft) { draft = "" }
    }
}
