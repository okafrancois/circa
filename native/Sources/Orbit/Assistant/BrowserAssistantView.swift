import AppKit
import BrowserCore
import BrowserShell
import SwiftUI

struct BrowserAssistantView: View {
    let conversation: BrowserAIConversation
    let choices: [BrowserAIModelChoice]
    let sources: [BrowserAIContextSource]
    let scopes: [String: [BrowserAIContextSource]]
    var currentTabID: UUID? = nil
    let enabled: Bool
    var citation: (BrowserAICitation) async -> Bool
    var close: () -> Void
    @State private var citationUnavailable = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composing: Bool
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(uiText("Assistant")).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
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
                    HStack(spacing: 6) {
                        Text(String(conversation.choice.provider.rawValue.prefix(1)).uppercased())
                            .font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18)
                            .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                        Text(conversation.choice.model ?? BrowserSettingsAIText.name(conversation.choice.provider)).lineLimit(1)
                        if let usage = conversation.messages.last?.usage?.windows.first {
                            Circle().trim(from: 0, to: Double(usage.usedPercent) / 100)
                                .stroke(usage.isFull ? Color.red : usage.usedPercent >= 80 ? .orange : .secondary, lineWidth: 2)
                                .rotationEffect(.degrees(-90)).frame(width: 12, height: 12)
                        }
                    }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 6).frame(height: 26)
                        .background(.quaternary, in: Capsule())
                }.menuStyle(.borderlessButton).fixedSize()
                Button(action: close) { Image(systemName: "xmark").frame(width: 26, height: 26) }.buttonStyle(.plain)
            }.padding(.leading, 14).padding(.trailing, 10).frame(height: 48)
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(conversation.selectedSources) { source in
                        HStack(spacing: 6) {
                            Text(source.id == currentTabID ? uiText("This tab") : source.title).lineLimit(1)
                            Button {
                                withAnimation(.linear(duration: reduceMotion ? 0.15 : 0.16)) { conversation.removeSource(source.id) }
                            } label: { Image(systemName: "xmark").frame(width: 16, height: 16) }
                        }.font(.system(size: 12)).padding(.leading, 8).padding(.trailing, 4).frame(height: 24)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                            .transition(.asymmetric(insertion: .scale(scale: reduceMotion ? 1 : 0.6).combined(with: .opacity), removal: .opacity))
                    }
                    Menu {
                        ForEach(sources) { source in Button(source.title) { select([source]) } }
                        ForEach(scopes.keys.sorted(), id: \.self) { name in Button(name) { select(scopes[name] ?? []) } }
                    } label: { Image(systemName: "at").frame(width: 24, height: 24) }.menuStyle(.borderlessButton).fixedSize()
                }.buttonStyle(.plain)
            }.padding(.horizontal, 14).padding(.top, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if conversation.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(.secondary)
                            Text(uiText("Ask about this tab")).font(.system(size: 16, weight: .semibold))
                            Button(uiText("Summarize this tab")) { _ = conversation.send(uiText("Summarize this tab")) }.disabled(!enabled)
                        }.padding(.vertical, 24)
                    }
                    ForEach(conversation.messages) { message in
                        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                            if message.text.isEmpty && message.state == .streaming { BrowserAssistantThinkingView() }
                            else {
                                BrowserAssistantStreamingText(message: message).textSelection(.enabled)
                                    .padding(.horizontal, message.role == .user ? 12 : 0)
                                    .padding(.vertical, message.role == .user ? 8 : 0)
                                    .background(message.role == .user ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 14))
                            }
                            if message.state == .stopped { Text(uiText("Stopped")).foregroundStyle(.secondary) }
                            if case .failed(let error) = message.state { Text(browserAssistantErrorText(error)).foregroundStyle(.secondary) }
                            ForEach(BrowserAICitation.parse(message)) { source in
                                Button("[\(source.number)] " + source.snapshot.source.title) { Task { citationUnavailable = !(await citation(source)) } }
                            }
                            if message.role == .assistant && !message.text.isEmpty {
                                Button(uiText("Copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
                            }
                        }.font(.system(size: 13)).lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                    }
                    if citationUnavailable { Text(uiText("This passage is no longer available.")).font(.system(size: 12)).foregroundStyle(.secondary) }
                }.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField(uiText("Ask a question"), text: $draft, axis: .vertical).textFieldStyle(.plain)
                    .font(.system(size: 13)).lineLimit(1...5).focused($composing).onSubmit(send)
                HStack {
                    if let usage = conversation.messages.last?.usage {
                        ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                            Text("\(window.usedPercent)%").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { if conversation.isRunning { conversation.stop() } else { send() } } label: {
                        Image(systemName: conversation.isRunning ? "stop.fill" : "arrow.up").frame(width: 24, height: 24)
                            .contentTransition(.opacity).animation(.linear(duration: reduceMotion ? 0.15 : 0.12), value: conversation.isRunning)
                    }.disabled(!enabled || (!conversation.isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 0.5)).padding(10)
        }.background(Color(nsColor: .windowBackgroundColor)).cornerRadius(6).onAppear { composing = true }
    }
    private func select(_ sources: [BrowserAIContextSource]) {
        withAnimation(reduceMotion ? .linear(duration: 0.15) : .timingCurve(0.3, 1.6, 0.5, 1, duration: 0.32)) {
            for source in sources { conversation.select(source) }
        }
    }
    private func send() {
        guard enabled, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if conversation.send(draft) { draft = "" }
    }
}
