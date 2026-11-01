import AppKit
import BrowserCore
import BrowserShell
import SwiftUI

/// Presentation metadata never changes the identifiers sent to the provider.
enum BrowserAssistantModels {
    /// Below this panel width the reasoning levels move under the models.
    static let narrowPanelWidth: CGFloat = 340

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

    /// A row in the selector. A program that takes no model choice still has one row for itself.
    struct Row: Identifiable, Equatable {
        let provider: BrowserAIProviderID
        let model: BrowserAIModel?
        let title: String
        var id: String { provider.rawValue + "/" + (model?.id ?? "") }
    }

    static func rows(_ provider: BrowserAIProviderID, choices: [BrowserAIModelChoice],
                     statuses: [BrowserAIProviderID: BrowserAIProviderStatus]) -> [Row] {
        let listed = models(provider, choices: choices, statuses: statuses)
        if listed.isEmpty, choices.contains(where: { $0.provider == provider }) {
            return [Row(provider: provider, model: nil, title: BrowserSettingsAIText.name(provider))]
        }
        return listed.map { Row(provider: provider, model: $0, title: name($0)) }
    }

    /// With a query the search spans every program; without one it lists the program in view.
    static func rows(viewing provider: BrowserAIProviderID, query: String, providers: [BrowserAIProviderID],
                     choices: [BrowserAIModelChoice], statuses: [BrowserAIProviderID: BrowserAIProviderStatus]) -> [Row] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows(provider, choices: choices, statuses: statuses) }
        return providers.flatMap { rows($0, choices: choices, statuses: statuses) }.filter {
            ($0.title + " " + BrowserSettingsAIText.name($0.provider)).localizedCaseInsensitiveContains(query)
        }
    }
}

struct BrowserAssistantModelControl: View {
    let conversation: BrowserAIConversation
    let choices: [BrowserAIModelChoice]
    let statuses: [BrowserAIProviderID: BrowserAIProviderStatus]
    var narrow = false
    @Binding var presented: Bool
    @Environment(\.assistantPalette) private var palette

    private var model: BrowserAIModel? {
        BrowserAssistantModels.models(conversation.choice.provider, choices: choices, statuses: statuses)
            .first { $0.id == conversation.choice.model }
    }
    private var title: String { model.map(BrowserAssistantModels.name) ?? BrowserSettingsAIText.name(conversation.choice.provider) }
    private var effort: String? { (conversation.choice.effort ?? model?.defaultEffort).map(BrowserSettingsAIText.effort) }

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: narrow ? 5 : 6) {
                BrowserAssistantProviderMark(provider: conversation.choice.provider)
                Text(title).font(.system(size: narrow ? 12.5 : 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                if let effort {
                    Text(effort).font(.system(size: narrow ? 12.5 : 13)).foregroundStyle(palette.secondary.swiftUI)
                        .lineLimit(1).fixedSize()
                }
                OrbitIcon.view(sfName: "chevron.up", pointSize: 10).font(.system(size: 9, weight: .medium))
                    .foregroundStyle(palette.tertiary.swiftUI)
            }.padding(.leading, narrow ? 4 : 5).padding(.trailing, narrow ? 5 : 7).frame(height: 30)
        }.buttonStyle(BrowserAssistantButtonStyle(kind: .quiet(radius: 8), active: presented))
            .accessibilityLabel(uiText("Model and reasoning"))
            .accessibilityValue([BrowserSettingsAIText.name(conversation.choice.provider), title, effort].compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier("assistant-provider")
    }
}

struct BrowserAssistantModelPicker: View {
    let conversation: BrowserAIConversation
    let choices: [BrowserAIModelChoice]
    let statuses: [BrowserAIProviderID: BrowserAIProviderStatus]
    let width: CGFloat
    var narrow = false
    var dismiss: () -> Void = {}

    private enum Column { case rail, models, efforts }
    private struct Cursor: Equatable { var column: Column; var index: Int }
    @State private var provider: BrowserAIProviderID?
    @State private var search = ""
    @State private var cursor: Cursor?
    @FocusState private var searching: Bool
    @Environment(\.assistantPalette) private var palette

    private var viewed: BrowserAIProviderID { provider ?? conversation.choice.provider }
    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var providers: [BrowserAIProviderID] { BrowserAIProviderID.allCases.filter { id in choices.contains { $0.provider == id } } }
    private var rows: [BrowserAssistantModels.Row] {
        BrowserAssistantModels.rows(viewing: viewed, query: search, providers: providers, choices: choices, statuses: statuses)
    }
    private var currentModel: BrowserAIModel? {
        BrowserAssistantModels.models(conversation.choice.provider, choices: choices, statuses: statuses)
            .first { $0.id == conversation.choice.model }
    }
    private var efforts: [String] { currentModel?.efforts ?? [] }
    private var currentEffort: String? { conversation.choice.effort ?? currentModel?.defaultEffort }
    private var listHeight: CGFloat {
        let tallest = providers.map { BrowserAssistantModels.rows($0, choices: choices, statuses: statuses).count }.max() ?? 1
        return min(narrow ? 176 : 238, CGFloat(max(1, tallest)) * 34)
    }
    private var usage: BrowserAIUsage? {
        guard !isSearching, let usage = statuses[viewed]?.state.usage, !usage.windows.isEmpty else { return nil }
        return usage
    }
    private var anyUsage: Bool { providers.contains { statuses[$0]?.state.usage?.windows.isEmpty == false } }
    private func ready(_ provider: BrowserAIProviderID) -> Bool { statuses[provider]?.state.isReady == true }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                rail
                line(vertical: true)
                if narrow {
                    VStack(spacing: 0) { modelList; line(vertical: false); reasoningGrid }.frame(maxWidth: .infinity)
                } else {
                    modelList.frame(maxWidth: .infinity)
                    line(vertical: true)
                    reasoningColumn.frame(width: 134)
                }
            }
            if anyUsage { usageRow }
        }
        .frame(width: width)
        .foregroundStyle(palette.ink.swiftUI)
        .background(BrowserAssistantKeyMonitor(handler: handleKey).frame(width: 0, height: 0))
        .task { searching = true }
        .onChange(of: search) { _, _ in cursor = nil }
    }

    private func line(vertical: Bool) -> some View {
        palette.line.swiftUI.frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }

    private var rail: some View {
        VStack(spacing: 4) {
            ForEach(Array(providers.enumerated()), id: \.element) { index, id in
                let pressed = !isSearching && viewed == id
                Button { provider = id; search = ""; cursor = nil } label: {
                    BrowserAssistantProviderMark(provider: id).frame(width: 32, height: 32)
                }
                .buttonStyle(BrowserAssistantButtonStyle(kind: .quiet(radius: 8), active: pressed,
                                                         cursor: cursor == Cursor(column: .rail, index: index)))
                .overlay(alignment: .leading) {
                    if pressed {
                        UnevenRoundedRectangle(cornerRadii: .init(bottomTrailing: 2, topTrailing: 2)).fill(palette.strong.swiftUI)
                            .frame(width: 2, height: 16).offset(x: -6)
                    }
                }
                .help(BrowserSettingsAIText.name(id))
                .accessibilityLabel(BrowserSettingsAIText.name(id))
                .accessibilityAddTraits(pressed ? .isSelected : [])
                .accessibilityIdentifier("assistant-provider-" + id.rawValue)
            }
        }.padding(.vertical, 8).padding(.horizontal, 6).frame(width: 44)
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                OrbitIcon.view(sfName: "magnifyingglass", pointSize: 14).font(.system(size: 13))
                    .foregroundStyle(palette.secondary.swiftUI)
                TextField("", text: $search, prompt: Text(uiText("Search models…")).foregroundStyle(palette.tertiary.swiftUI))
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($searching)
                    .accessibilityLabel(uiText("Search models…"))
                    .accessibilityIdentifier("assistant-model-search")
            }.padding(.horizontal, 8).frame(height: 32).padding(.bottom, 4)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if !isSearching, let reason = BrowserSettingsAIText.reason(statuses[viewed]?.state) {
                            Text(reason).font(.system(size: 11.5)).foregroundStyle(palette.secondary.swiftUI)
                                .padding(.horizontal, 8).padding(.bottom, 4)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in modelRow(row, index: index).id(row.id) }
                        if rows.isEmpty {
                            Text(uiText("No models")).font(.system(size: 12)).foregroundStyle(palette.secondary.swiftUI).padding(8)
                        }
                    }
                }.frame(minHeight: 34, idealHeight: listHeight, maxHeight: listHeight)
                    .onChange(of: cursor) { _, cursor in
                        if let cursor, cursor.column == .models, rows.indices.contains(cursor.index) { scroll.scrollTo(rows[cursor.index].id) }
                    }
            }
        }.padding(6)
    }

    private func modelRow(_ row: BrowserAssistantModels.Row, index: Int) -> some View {
        let selected = row.provider == conversation.choice.provider && row.model?.id == conversation.choice.model
        return Button { choose(row) } label: {
            HStack(spacing: 8) {
                if isSearching { BrowserAssistantProviderMark(provider: row.provider) }
                Text(row.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected { checkmark }
            }.padding(.horizontal, 8).frame(minHeight: 32)
        }
        .buttonStyle(BrowserAssistantButtonStyle(kind: .option(selected: selected), cursor: cursor == Cursor(column: .models, index: index)))
        .disabled(!ready(row.provider))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("assistant-model-" + (row.model?.id ?? row.provider.rawValue))
    }

    private var checkmark: some View {
        OrbitIcon.view(sfName: "checkmark", pointSize: 14).font(.system(size: 12)).foregroundStyle(palette.accentInk.swiftUI)
    }

    private var reasoningColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(uiText("Reasoning")).font(.system(size: 12)).foregroundStyle(palette.secondary.swiftUI)
                .padding(.horizontal, 8).frame(height: 32).padding(.bottom, 4)
            if efforts.isEmpty { noReasoning }
            ForEach(Array(efforts.enumerated()), id: \.element) { index, effort in effortRow(effort, index: index, showDefault: true) }
        }.padding(6).frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var reasoningGrid: some View {
        Group {
            if efforts.isEmpty { noReasoning.frame(maxWidth: .infinity, alignment: .leading) }
            else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible())], spacing: 2) {
                    ForEach(Array(efforts.enumerated()), id: \.element) { index, effort in effortRow(effort, index: index, showDefault: false) }
                }
            }
        }.padding(6)
    }

    private var noReasoning: some View {
        Text(uiText("Default")).font(.system(size: 12)).foregroundStyle(palette.secondary.swiftUI).padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func effortRow(_ effort: String, index: Int, showDefault: Bool) -> some View {
        let selected = currentEffort == effort
        return Button { chooseEffort(effort) } label: {
            HStack(spacing: 6) {
                Text(BrowserSettingsAIText.effort(effort)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if showDefault, currentModel?.defaultEffort == effort {
                    Text(uiText("Default")).font(.system(size: 11.5)).foregroundStyle(palette.secondary.swiftUI).lineLimit(1)
                }
                if selected { checkmark }
            }.padding(.horizontal, 8).frame(minHeight: 32)
        }
        .buttonStyle(BrowserAssistantButtonStyle(kind: .option(selected: selected), cursor: cursor == Cursor(column: .efforts, index: index)))
        .disabled(!ready(conversation.choice.provider))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("assistant-effort-" + effort)
    }

    private var usageRow: some View {
        VStack(spacing: 0) {
            line(vertical: false)
            HStack(spacing: 12) {
                ForEach(Array((usage?.windows ?? []).enumerated()), id: \.offset) { _, window in
                    HStack(spacing: 8) {
                        Text(BrowserSettingsAIText.span(window.span)).lineLimit(1).fixedSize()
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.hover.swiftUI)
                            GeometryReader { proxy in
                                Capsule().fill(meter(window)).frame(width: proxy.size.width * CGFloat(window.usedPercent) / 100)
                            }
                        }.frame(height: 4).accessibilityHidden(true)
                        Text(uiFormat("%ld%%", window.usedPercent)).monospacedDigit().lineLimit(1).fixedSize()
                    }.accessibilityElement(children: .combine)
                }
            }.font(.system(size: 11.5)).foregroundStyle(palette.secondary.swiftUI)
                .padding(.horizontal, 12).frame(height: 33)
        }
    }

    private func meter(_ window: BrowserAIUsageWindow) -> Color {
        window.isFull ? palette.critical.swiftUI : window.usedPercent >= 80 ? palette.warning.swiftUI : palette.secondary.swiftUI
    }

    private func choose(_ row: BrowserAssistantModels.Row) {
        provider = row.provider
        search = ""
        conversation.switchProvider(to: row.model.map { BrowserAssistantModels.selecting($0, previous: conversation.choice) }
            ?? BrowserAIModelChoice(provider: row.provider))
    }

    private func chooseEffort(_ effort: String) {
        guard let model = currentModel else { return }
        conversation.switchProvider(to: BrowserAIModelChoice(provider: model.provider, model: model.id, effort: effort))
        dismiss()
    }

    /// Arrows walk the provider rail, the models and the reasoning levels; Return activates.
    private func handleKey(_ event: NSEvent) -> Bool {
        func count(_ column: Column) -> Int {
            switch column {
            case .rail: providers.count
            case .models: rows.count
            case .efforts: efforts.count
            }
        }
        switch event.keyCode {
        case BrowserAssistantKey.down, BrowserAssistantKey.up:
            let step = event.keyCode == BrowserAssistantKey.down ? 1 : -1
            guard let current = cursor else {
                if !rows.isEmpty { cursor = Cursor(column: .models, index: step > 0 ? 0 : rows.count - 1) }
                return true
            }
            let total = count(current.column)
            if total > 0 { cursor = Cursor(column: current.column, index: (current.index + step + total) % total) }
            return true
        case BrowserAssistantKey.left, BrowserAssistantKey.right:
            guard let current = cursor else { return false }
            let order: [Column] = [.rail, .models, .efforts]
            let position = (order.firstIndex(of: current.column) ?? 1) + (event.keyCode == BrowserAssistantKey.right ? 1 : -1)
            if order.indices.contains(position), count(order[position]) > 0 {
                cursor = Cursor(column: order[position], index: 0)
            }
            return true
        case BrowserAssistantKey.returnKey, BrowserAssistantKey.keypadEnter:
            switch cursor {
            case let cursor? where cursor.column == .rail && providers.indices.contains(cursor.index):
                provider = providers[cursor.index]; search = ""
            case let cursor? where cursor.column == .efforts && efforts.indices.contains(cursor.index):
                chooseEffort(efforts[cursor.index])
            default:
                let index = cursor?.index ?? 0
                if rows.indices.contains(index), ready(rows[index].provider) { choose(rows[index]) }
            }
            return true
        default:
            return false
        }
    }
}
