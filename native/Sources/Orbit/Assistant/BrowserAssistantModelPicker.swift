import AppKit
import BrowserCore
import BrowserShell
import SwiftUI

/// Presentation metadata never changes the identifiers sent to the provider.
enum BrowserAssistantModels {
    static func models(_ provider: BrowserAIProviderID, choices: [BrowserAIModelChoice],
                       statuses: [BrowserAIProviderID: BrowserAIProviderStatus]) -> [BrowserAIModel] {
        let reported = statuses[provider]?.models ?? []
        let metadata = reported.isEmpty && provider == .claudeCode ? BrowserAIClaudeLaunch.models : reported
        return choices.filter { $0.provider == provider }.reduce(into: [BrowserAIModel]()) { result, choice in
            guard let id = choice.model, !result.contains(where: { $0.id == id }) else { return }
            result.append(metadata.first(where: { $0.id == id }) ?? BrowserAIModel(provider: provider, id: id, displayName: id))
        }
    }

    static func name(_ model: BrowserAIModel) -> String {
        guard model.displayName == model.id else { return model.displayName }
        return model.id.split(separator: "-").map { part in
            part.lowercased() == "gpt" ? "GPT" : String(part).prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }

    static func selecting(_ model: BrowserAIModel, previous: BrowserAIModelChoice) -> BrowserAIModelChoice {
        let effort = previous.provider == model.provider && previous.effort.map(model.efforts.contains) == true
            ? previous.effort : model.defaultEffort.flatMap { model.efforts.contains($0) ? $0 : nil }
        return BrowserAIModelChoice(provider: model.provider, model: model.id, effort: effort)
    }

    static func pickerWidth(windowWidth: CGFloat) -> CGFloat { min(560, max(240, windowWidth - 40)) }
}

struct BrowserAssistantModelControl: View {
    let conversation: BrowserAIConversation
    let choices: [BrowserAIModelChoice]
    let statuses: [BrowserAIProviderID: BrowserAIProviderStatus]
    @State private var presented = false
    @State private var windowWidth: CGFloat = 700

    private var model: BrowserAIModel? {
        BrowserAssistantModels.models(conversation.choice.provider, choices: choices, statuses: statuses)
            .first { $0.id == conversation.choice.model }
    }

    private var modelName: some View {
        Text(model.map(BrowserAssistantModels.name) ?? BrowserSettingsAIText.name(conversation.choice.provider))
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private var effortName: some View {
        if let effort = conversation.choice.effort ?? model?.defaultEffort {
            Text(BrowserSettingsAIText.effort(effort)).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 5) {
                BrowserAssistantProviderMark(provider: conversation.choice.provider)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) { modelName; effortName }.fixedSize()
                    VStack(alignment: .leading, spacing: 1) { modelName; effortName }
                }
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .medium))
            }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 8).frame(minHeight: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityIdentifier("assistant-provider")
            .background(AssistantWindowWidth(width: $windowWidth).frame(width: 0, height: 0))
            .assistantPopover(isPresented: $presented, trailing: true) {
                BrowserAssistantModelPicker(conversation: conversation, choices: choices, statuses: statuses,
                    width: BrowserAssistantModels.pickerWidth(windowWidth: windowWidth))
            }
    }
}

private struct BrowserAssistantModelPicker: View {
    let conversation: BrowserAIConversation
    let choices: [BrowserAIModelChoice]
    let statuses: [BrowserAIProviderID: BrowserAIProviderStatus]
    let width: CGFloat
    @State private var provider: BrowserAIProviderID?
    @State private var search = ""
    @FocusState private var searching: Bool
    private var selectedProvider: BrowserAIProviderID { provider ?? conversation.choice.provider }
    private var providers: [BrowserAIProviderID] { BrowserAIProviderID.allCases.filter { id in choices.contains { $0.provider == id } } }
    private var models: [BrowserAIModel] { BrowserAssistantModels.models(selectedProvider, choices: choices, statuses: statuses) }
    private var selectedModel: BrowserAIModel? {
        guard selectedProvider == conversation.choice.provider else { return nil }
        return models.first { $0.id == conversation.choice.model }
    }
    private var available: Bool { statuses[selectedProvider]?.state.isReady == true }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 8) {
                ForEach(providers) { id in
                    Button { provider = id; search = "" } label: {
                        BrowserAssistantProviderMark(provider: id).frame(width: 36, height: 36)
                            .background(selectedProvider == id ? Color.primary.opacity(0.09) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).help(BrowserSettingsAIText.name(id))
                        .accessibilityLabel(BrowserSettingsAIText.name(id)).accessibilityIdentifier("assistant-provider-" + id.rawValue)
                }
            }.padding(6)
            Divider()
            if width >= 460 {
                modelList.frame(maxWidth: .infinity)
                Divider()
                reasoning.frame(width: 168)
            } else {
                VStack(spacing: 0) { modelList; Divider(); reasoning }.frame(maxWidth: .infinity)
            }
        }.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .font(.system(size: 13))
            .task { searching = true }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(uiText("Search models…"), text: $search).textFieldStyle(.plain)
                    .focused($searching)
                    .accessibilityIdentifier("assistant-model-search")
            }.padding(.horizontal, 8).frame(height: 32)
            if let reason = BrowserSettingsAIText.reason(statuses[selectedProvider]?.state) {
                Text(reason).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(models.filter { search.isEmpty || BrowserAssistantModels.name($0).localizedCaseInsensitiveContains(search) }) { model in
                        Button { conversation.switchProvider(to: BrowserAssistantModels.selecting(model, previous: conversation.choice)) } label: {
                            HStack(spacing: 8) {
                                Text(BrowserAssistantModels.name(model)).multilineTextAlignment(.leading)
                                Spacer(minLength: 4)
                                if selectedModel?.id == model.id { Image(systemName: "checkmark") }
                            }.padding(.horizontal, 8).frame(minHeight: 34).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedModel?.id == model.id ? Color.primary.opacity(0.07) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).disabled(!available).accessibilityIdentifier("assistant-model-" + model.id)
                    }
                }
            }.frame(height: min(238, CGFloat(max(1, models.count)) * 36))
        }.padding(8)
    }

    private var reasoning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(uiText("Reasoning")).foregroundStyle(.secondary).padding(.horizontal, 8).frame(height: 32)
            if let model = selectedModel, !model.efforts.isEmpty {
                ForEach(model.efforts, id: \.self) { effort in
                    Button {
                        conversation.switchProvider(to: BrowserAIModelChoice(provider: model.provider, model: model.id, effort: effort))
                    } label: {
                        HStack(spacing: 6) {
                            Text(BrowserSettingsAIText.effort(effort))
                            Spacer(minLength: 0)
                            if model.defaultEffort == effort { Text(uiText("Default")).font(.system(size: 11)).foregroundStyle(.secondary) }
                            if (conversation.choice.effort ?? model.defaultEffort) == effort { Image(systemName: "checkmark") }
                        }.padding(.horizontal, 8).frame(minHeight: 34)
                            .background((conversation.choice.effort ?? model.defaultEffort) == effort ? Color.primary.opacity(0.07) : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).disabled(!available).accessibilityIdentifier("assistant-effort-" + effort)
                }
            } else {
                Text(uiText("Default")).foregroundStyle(.secondary).padding(8)
            }
        }.padding(8).frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The popover can use the window's width even when its anchor is in a narrow dock.
private struct AssistantWindowWidth: NSViewRepresentable {
    @Binding var width: CGFloat
    func makeNSView(context: Context) -> WidthView { WidthView() }
    func updateNSView(_ view: WidthView, context: Context) { view.changed = { if width != $0 { width = $0 } }; view.report() }
    final class WidthView: NSView {
        var changed: ((CGFloat) -> Void)?
        private var observation: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil
            if let window {
                observation = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }
        func report() {
            guard let width = window?.contentView?.bounds.width else { return }
            DispatchQueue.main.async { [weak self] in self?.changed?(width) }
        }
        isolated deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}
