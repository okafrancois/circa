import AppKit
import BrowserCore
import BrowserShell
import SwiftUI

/// Context revocation is immediate: the conversation forgets a source at the click. The chip that keeps
/// fading on screen is only this detached snapshot, which no send path can read.
struct BrowserAssistantContextChips: Equatable {
    struct Outgoing: Equatable {
        let source: BrowserAIContextSource
        let index: Int
    }
    struct Chip: Identifiable, Equatable {
        let source: BrowserAIContextSource
        let leaving: Bool
        var id: UUID { source.id }
    }
    private(set) var outgoing: [Outgoing] = []

    @MainActor
    mutating func revoke(_ source: BrowserAIContextSource, from conversation: BrowserAIConversation) {
        let index = conversation.selectedSources.firstIndex { $0.id == source.id }
        conversation.removeSource(source.id)
        if let index, !outgoing.contains(where: { $0.source.id == source.id }) {
            outgoing.append(Outgoing(source: source, index: index))
        }
    }

    mutating func finish(_ id: UUID) { outgoing.removeAll { $0.source.id == id } }

    /// Selected sources, with departing chips kept in place until their fade ends.
    func chips(selected: [BrowserAIContextSource]) -> [Chip] {
        var result = selected.map { Chip(source: $0, leaving: false) }
        for item in outgoing.sorted(by: { $0.index < $1.index }) where !selected.contains(where: { $0.id == item.source.id }) {
            result.insert(Chip(source: item.source, leaving: true), at: min(item.index, result.count))
        }
        return result
    }
}

struct BrowserAssistantView: View {
    let conversation: BrowserAIConversation
    let choices: [BrowserAIModelChoice]
    var statuses: [BrowserAIProviderID: BrowserAIProviderStatus] = [:]
    let sources: [BrowserAIContextSource]
    var usages: [BrowserAIProviderID: BrowserAIUsage] = [:]
    let scopes: [String: [BrowserAIContextSource]]
    var currentTabID: UUID? = nil
    let enabled: Bool
    var palette = BrowserAssistantPalette(theme: .default, appearance: NSAppearance(named: .aqua)!)
    var favicons: [UUID: NSImage] = [:]
    var citation: (BrowserAICitation) async -> Bool
    var close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @FocusState private var composing: Bool
    @State private var draft = ""
    @State private var chips = BrowserAssistantContextChips()
    @State private var leaving: Set<UUID> = []
    @State private var contextPickerPresented = false
    @State private var modelPickerPresented = false
    @State private var citationUnavailable = false
    @State private var activeCitation: String?
    @State private var citationReset: Task<Void, Never>?
    @State private var panelWidth: CGFloat = 372
    @State private var composerWidth: CGFloat = 352
    @State private var viewportHeight: CGFloat = 0

    private var reduceMotion: Bool { systemReduceMotion || OrbitMotionPreferences.prefersReducedMotion }
    private var narrow: Bool { panelWidth < BrowserAssistantModels.narrowPanelWidth }
    private var hasContextChoices: Bool { !sources.isEmpty || !scopes.isEmpty }
    private var currentUsage: BrowserAIUsage? {
        conversation.messages.last(where: { $0.choice.provider == conversation.choice.provider })?.usage
            ?? usages[conversation.choice.provider]
    }
    private var contextRemoval: Animation {
        reduceMotion ? .linear(duration: 0.15) : .timingCurve(1.0 / 3, 2.0 / 3, 2.0 / 3, 1, duration: 0.16)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                transcript
                composer.padding(.horizontal, 10).padding(.bottom, 10)
            }
            Button(action: close) {
                OrbitIcon.view(sfName: "xmark", pointSize: 16).font(.system(size: 13)).frame(width: 28, height: 28)
            }.buttonStyle(BrowserAssistantButtonStyle(kind: .quiet(radius: 6)))
                .foregroundStyle(palette.secondary.swiftUI).padding(8)
                .help(uiText("Close")).accessibilityLabel(uiText("Close")).accessibilityIdentifier("assistant-close")
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(palette.ink.swiftUI)
        .environment(\.assistantPalette, palette)
        .ignoresSafeArea()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { panelWidth = $0 }
        .background(BrowserAssistantKeyMonitor(handler: handleKey).frame(width: 0, height: 0))
        .task {
            await Task.yield()
            composing = true
        }
        .onChange(of: hasContextChoices) { _, available in
            if !available { contextPickerPresented = false }
        }
    }

    // MARK: Conversation

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(conversation.messages) { message in
                    if message.role == .user { userBubble(message) } else { answer(message) }
                }
                if citationUnavailable {
                    Text(uiText("This passage is no longer available.")).font(.system(size: 12)).foregroundStyle(palette.secondary.swiftUI)
                }
            }
            .padding(.horizontal, 16).padding(.top, 44).padding(.bottom, 14)
            .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .bottomLeading)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollIndicators(.automatic)
        .mask {
            VStack(spacing: 0) {
                Color.clear.frame(height: 20)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 24)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 10)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewportHeight = $0 }
    }

    private func userBubble(_ message: BrowserAIMessage) -> some View {
        Text(message.text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(palette.wash.swiftUI, in: UnevenRoundedRectangle(cornerRadii: .init(topLeading: 14, bottomLeading: 14, bottomTrailing: 4, topTrailing: 14)))
            .frame(maxWidth: max(0, panelWidth - 32) * (narrow ? 0.92 : 0.86), alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func answer(_ message: BrowserAIMessage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            answerMeta(message).padding(.bottom, 6)
            if message.text.isEmpty && message.state == .streaming {
                BrowserAssistantThinkingView()
            } else if !BrowserAICitation.segments(message).isEmpty {
                BrowserAssistantAnswerText(message: message, open: { open($0) }, activeCitation: activeCitation)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if message.state == .stopped {
                Text(uiText("Stopped")).font(.system(size: 12)).foregroundStyle(palette.secondary.swiftUI).padding(.top, 8)
            }
            if case .failed(let error) = message.state { failure(error).padding(.top, 8) }
            let sourceChips = uniqueCitations(message)
            if !sourceChips.isEmpty {
                BrowserAssistantFlowLayout {
                    ForEach(sourceChips) { source in
                        Button { open(source) } label: {
                            HStack(spacing: 6) {
                                BrowserAssistantCitationNumber(number: source.number)
                                Text(source.snapshot.source.title).lineLimit(1).truncationMode(.tail)
                            }.font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondary.swiftUI)
                                .padding(.leading, 6).padding(.trailing, 9).frame(height: 28)
                        }.buttonStyle(BrowserAssistantButtonStyle(kind: .outlined(radius: 8)))
                            .help(source.snapshot.source.title)
                    }
                }.padding(.top, 12)
            }
            if !message.text.isEmpty && message.state != .streaming {
                BrowserAssistantCopyButton(text: BrowserAICitation.displayText(message)).padding(.top, 6).padding(.leading, -6)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerMeta(_ message: BrowserAIMessage) -> some View {
        let model = BrowserAssistantModels.models(message.choice.provider, choices: choices, statuses: statuses)
            .first { $0.id == message.choice.model }
        var parts = [model.map(BrowserAssistantModels.name) ?? message.choice.model ?? BrowserSettingsAIText.name(message.choice.provider)]
        if !message.context.isEmpty { parts.append(uiText("%ld sources read", count: message.context.count)) }
        return HStack(spacing: 6) {
            BrowserAssistantProviderMark(provider: message.choice.provider, size: 16)
            Text(parts.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(palette.secondary.swiftUI).lineLimit(1)
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder private func failure(_ error: BrowserAIError) -> some View {
        if case .limitReached = error {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(palette.warning.swiftUI).frame(width: 7, height: 7)
                    Text(uiText("Usage limit reached")).font(.system(size: 13, weight: .semibold))
                }
                Text(uiText("Choose another model or wait.")).font(.system(size: 13)).foregroundStyle(palette.secondary.swiftUI)
                    .fixedSize(horizontal: false, vertical: true)
                Button { modelPickerPresented = true } label: {
                    Text(uiText("Change model")).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondary.swiftUI)
                        .padding(.horizontal, 10).frame(height: 28)
                }.buttonStyle(BrowserAssistantButtonStyle(kind: .outlined(radius: 8)))
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.composer.swiftUI, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.line.swiftUI, lineWidth: 1))
        } else {
            Text(browserAssistantErrorText(error)).font(.system(size: 12)).foregroundStyle(palette.secondary.swiftUI)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func uniqueCitations(_ message: BrowserAIMessage) -> [BrowserAICitation] {
        var numbers: Set<Int> = []
        return BrowserAICitation.parse(message).filter { numbers.insert($0.number).inserted }
    }

    /// Provenance is checked by the owner when opened; the pill holds its strong state during the highlight.
    private func open(_ source: BrowserAICitation) {
        citationReset?.cancel()
        activeCitation = source.id
        citationUnavailable = false
        Task {
            let shown = await citation(source)
            citationUnavailable = !shown
            guard shown else { activeCitation = nil; return }
            citationReset = Task {
                try? await Task.sleep(for: .seconds(2.65))
                if !Task.isCancelled { activeCitation = nil }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            let chipItems = chips.chips(selected: conversation.selectedSources)
            if !chipItems.isEmpty {
                BrowserAssistantFlowLayout {
                    ForEach(chipItems) { chip(item: $0) }
                }.padding(.horizontal, 4).padding(.bottom, 8)
            }
            TextField("", text: $draft, prompt: Text(uiText("Ask a question")).foregroundStyle(palette.tertiary.swiftUI), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineSpacing(3).lineLimit(3...7)
                .padding(.horizontal, 4).focused($composing).onSubmit(send)
                .accessibilityLabel(uiText("Ask a question")).accessibilityIdentifier("assistant-composer")
                .onChange(of: draft) { old, new in
                    if hasContextChoices && new.count > old.count && new.hasSuffix("@") { contextPickerPresented = true }
                }
            HStack(spacing: 6) {
                Button { contextPickerPresented.toggle() } label: {
                    // The native symbol preserves transparent counters when tinted.
                    Image(systemName: "at").font(.system(size: 14)).foregroundStyle(palette.secondary.swiftUI)
                        .frame(width: 30, height: 30)
                }.buttonStyle(BrowserAssistantButtonStyle(kind: .icon, active: contextPickerPresented))
                    .disabled(!hasContextChoices).help(uiText("Add context")).accessibilityLabel(uiText("Add context"))
                    .accessibilityIdentifier("assistant-add-context")
                Spacer(minLength: 0)
                BrowserAssistantModelControl(conversation: conversation, choices: choices, statuses: statuses, narrow: narrow,
                                             presented: $modelPickerPresented)
                    .help(usageHelp).layoutPriority(1)
                Button { if conversation.isRunning { conversation.stop() } else { send() } } label: {
                    OrbitIcon.view(sfName: conversation.isRunning ? "stop.fill" : "arrow.up", pointSize: 16).font(.system(size: 13, weight: .medium))
                        .frame(width: 16, height: 16)
                        .contentTransition(.opacity).animation(.linear(duration: reduceMotion ? 0.15 : 0.12), value: conversation.isRunning)
                }.buttonStyle(BrowserAssistantSendButtonStyle(running: conversation.isRunning))
                    .accessibilityLabel(conversation.isRunning ? uiText("Stop") : uiText("Send"))
                    .accessibilityIdentifier("assistant-send-stop")
                    .help(conversation.isRunning ? uiText("Stop") : uiText("Send"))
                    .disabled(!enabled || (!conversation.isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }.padding(.top, 6)
        }
        .padding(.top, 10).padding(.horizontal, 8).padding(.bottom, 8)
        .background(palette.composer.swiftUI, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(composing ? palette.composerFocusLine.swiftUI : palette.composerLine.swiftUI, lineWidth: 1)
                .animation(.linear(duration: reduceMotion ? 0.15 : 0.12), value: composing)
        }
        .shadow(color: palette.isDark ? .clear : Color(red: 20.0 / 255, green: 19.0 / 255, blue: 23.0 / 255, opacity: 0.06), radius: 1.5, y: 1)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { composerWidth = $0 }
        .assistantPopover(isPresented: $contextPickerPresented, placement: .above(maxWidth: 288)) {
            BrowserAssistantContextPicker(sources: sources, scopes: scopes, selected: conversation.selectedSources,
                                          currentTabID: currentTabID, favicons: favicons,
                                          width: min(288, composerWidth), choose: chooseContext)
        }
        .assistantPopover(isPresented: $modelPickerPresented, placement: .over(bottomInset: 48)) {
            BrowserAssistantModelPicker(conversation: conversation, choices: choices, statuses: statuses, width: composerWidth,
                                        narrow: narrow, dismiss: { modelPickerPresented = false })
        }
    }

    private var usageHelp: String {
        currentUsage?.windows.map { BrowserSettingsAIText.meter($0, limitReached: currentUsage?.limitReached == true) }.joined(separator: " · ") ?? ""
    }

    private func chip(item: BrowserAssistantContextChips.Chip) -> some View {
        let source = item.source
        let hidden = item.leaving && leaving.contains(source.id)
        return HStack(spacing: 6) {
            BrowserAssistantFavicon(image: favicons[source.id])
            Text(source.id == currentTabID ? uiText("This tab") : source.title).lineLimit(1).truncationMode(.tail)
            Button { remove(source) } label: {
                OrbitIcon.view(sfName: "xmark", pointSize: 12).font(.system(size: 10)).foregroundStyle(palette.secondary.swiftUI)
                    .frame(width: 20, height: 20)
            }.buttonStyle(BrowserAssistantButtonStyle(kind: .quiet(radius: 6)))
                .help(uiFormat("Remove %@", source.title)).accessibilityLabel(uiFormat("Remove %@", source.title))
                .accessibilityIdentifier("assistant-remove-" + source.id.uuidString)
        }
        .font(.system(size: 12, weight: .medium)).padding(.leading, 6).padding(.trailing, 2).frame(height: 24)
        .background(palette.wash.swiftUI, in: RoundedRectangle(cornerRadius: 8))
        .scaleEffect(hidden && !reduceMotion ? 0.8 : 1).opacity(hidden ? 0 : 1)
        .allowsHitTesting(!item.leaving).accessibilityHidden(item.leaving)
        .transition(.asymmetric(insertion: .scale(scale: reduceMotion ? 1 : 0.6).combined(with: .opacity), removal: .identity))
    }

    /// The source leaves the conversation before any animation starts; only a detached snapshot fades.
    private func remove(_ source: BrowserAIContextSource) {
        chips.revoke(source, from: conversation)
        withAnimation(contextRemoval, completionCriteria: .logicallyComplete) {
            _ = leaving.insert(source.id)
        } completion: {
            chips.finish(source.id)
            leaving.remove(source.id)
        }
    }

    private func chooseContext(_ chosen: [BrowserAIContextSource], toggles: Bool) {
        if toggles, let source = chosen.first, conversation.selectedSources.contains(where: { $0.id == source.id }) {
            remove(source)
        } else {
            for source in chosen { leaving.remove(source.id) }
            withAnimation(reduceMotion ? .linear(duration: 0.15) : .timingCurve(0.3, 1.6, 0.5, 1, duration: 0.32)) {
                for source in chosen { conversation.select(source) }
            }
        }
        if draft.hasSuffix("@") { draft.removeLast() }
        contextPickerPresented = false
        composing = true
    }

    private func send() {
        guard enabled, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if conversation.send(draft) { draft = "" }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == BrowserAssistantKey.escape, conversation.isRunning else { return false }
        conversation.stop()
        return true
    }
}

struct BrowserAssistantFavicon: View {
    let image: NSImage?
    @Environment(\.assistantPalette) private var palette
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
            else { OrbitIcon.view(sfName: "globe", pointSize: 14).font(.system(size: 12)).foregroundStyle(palette.secondary.swiftUI) }
        }.frame(width: 14, height: 14).clipShape(RoundedRectangle(cornerRadius: 3.5)).accessibilityHidden(true)
    }
}

struct BrowserAssistantCopyButton: View {
    let text: String
    @State private var copied = false
    @State private var reset: Task<Void, Never>?
    @Environment(\.assistantPalette) private var palette
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(for: .seconds(1.4))
                if !Task.isCancelled { copied = false }
            }
        } label: {
            HStack(spacing: 6) {
                OrbitIcon.view(sfName: "doc.on.clipboard", pointSize: 16).font(.system(size: 13))
                Text(copied ? uiText("Copied") : uiText("Copy"))
            }.font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondary.swiftUI)
                .padding(.leading, 6).padding(.trailing, 8).frame(height: 28)
        }.buttonStyle(BrowserAssistantButtonStyle(kind: .quiet(radius: 8))).accessibilityIdentifier("assistant-copy")
    }
}

struct BrowserAssistantContextPicker: View {
    let sources: [BrowserAIContextSource]
    let scopes: [String: [BrowserAIContextSource]]
    let selected: [BrowserAIContextSource]
    let currentTabID: UUID?
    let favicons: [UUID: NSImage]
    let width: CGFloat
    let choose: ([BrowserAIContextSource], Bool) -> Void
    @State private var cursor: Int?
    @Environment(\.assistantPalette) private var palette

    private var scopeNames: [String] { scopes.keys.sorted() }
    private var rowCount: Int { sources.count + scopeNames.count }
    private var contentHeight: CGFloat {
        min(336, CGFloat(rowCount) * 32 + (sources.isEmpty ? 0 : 28) + (scopeNames.isEmpty ? 0 : 28) + 12)
    }
    private func isSelected(_ source: BrowserAIContextSource) -> Bool { selected.contains { $0.id == source.id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !sources.isEmpty { header(uiText("Tabs")) }
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                    row(source.id == currentTabID ? source.title + " — " + uiText("This tab").lowercased() : source.title,
                        on: isSelected(source), index: index) {
                        BrowserAssistantFavicon(image: favicons[source.id])
                    } action: { choose([source], true) }
                }
                if !scopeNames.isEmpty { header(uiText("Scopes")) }
                ForEach(Array(scopeNames.enumerated()), id: \.element) { offset, name in
                    let members = scopes[name] ?? []
                    row(name, on: !members.isEmpty && members.allSatisfy(isSelected), index: sources.count + offset) {
                        OrbitIcon.view(sfName: name == uiText("Whole Space") ? "square.grid.2x2" : "folder", pointSize: 16)
                            .font(.system(size: 13)).foregroundStyle(palette.secondary.swiftUI).frame(width: 14, height: 14)
                    } action: { choose(members, false) }
                }
            }.padding(6)
        }
        .frame(width: width)
        .frame(minHeight: 44, idealHeight: contentHeight, maxHeight: contentHeight)
        .foregroundStyle(palette.ink.swiftUI)
        .background(BrowserAssistantKeyMonitor(handler: handleKey).frame(width: 0, height: 0))
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(palette.secondary.swiftUI)
            .padding(.horizontal, 8).frame(height: 28, alignment: .bottomLeading).padding(.bottom, 0)
    }

    private func row<Icon: View>(_ title: String, on: Bool, index: Int, @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon()
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if on {
                    OrbitIcon.view(sfName: "checkmark", pointSize: 14).font(.system(size: 12)).foregroundStyle(palette.accentInk.swiftUI)
                }
            }.padding(.horizontal, 8).frame(height: 32)
        }.buttonStyle(BrowserAssistantButtonStyle(kind: .option(selected: on), cursor: cursor == index)).help(title)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard rowCount > 0 else { return false }
        switch event.keyCode {
        case BrowserAssistantKey.down: cursor = ((cursor ?? -1) + 1) % rowCount; return true
        case BrowserAssistantKey.up: cursor = ((cursor ?? rowCount) - 1 + rowCount) % rowCount; return true
        case BrowserAssistantKey.returnKey, BrowserAssistantKey.keypadEnter:
            guard let cursor else { return false }
            if cursor < sources.count { choose([sources[cursor]], true) }
            else { choose(scopes[scopeNames[cursor - sources.count]] ?? [], false) }
            return true
        default: return false
        }
    }
}
