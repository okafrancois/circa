import BrowserCore
import BrowserEngine
import BrowserShell
import SwiftUI

/// Reuses Settings list rows, switches and the field-editor sheet.
@MainActor
struct BrowserSiteSearchSettings<Engine: BrowserEngine>: View {
    @ObservedObject var model: BrowserSettingsModel<Engine>
    @ObservedObject var runtime: BrowserSettingsRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BrowserSiteSearch?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(uiText("Site Search")).fontWeight(.medium)
                Spacer()
                Button(uiText("Add")) { draft = .init(name: "", shortcut: "", template: "") }
                    .accessibilityIdentifier("settings-site-search-add")
            }
            ScrollView {
                SettingsCard {
                    ForEach(Array(runtime.document.siteSearches.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { SettingsRule() }
                        SettingsDetailRow(title: entry.isBuiltIn ? uiText(entry.name) : entry.name) {
                            Text(entry.shortcut).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 130, alignment: .trailing)
                            Toggle(uiText("Enabled"), isOn: Binding(get: { entry.isEnabled }, set: { value in
                                model.perform {
                                    try await runtime.store.setSiteSearchEnabled(entry.id, value)
                                    await runtime.refresh()
                                }
                            })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                                .accessibilityIdentifier("settings-site-search-enabled-" + entry.id)
                            Button(uiText("Edit")) { draft = entry }
                                .accessibilityIdentifier("settings-site-search-edit-" + entry.id)
                            if !entry.isBuiltIn {
                                Button(uiText("Delete"), role: .destructive) {
                                    model.perform {
                                        try await runtime.store.removeSiteSearch(entry.id)
                                        await runtime.refresh()
                                    }
                                }.settingsDestructive().accessibilityIdentifier("settings-site-search-delete-" + entry.id)
                            }
                        }
                    }
                }
            }.frame(minHeight: 130, maxHeight: 290)
            HStack {
                Spacer()
                Button(uiText("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 560).font(Font(BrandFonts.ui(13))).settingsFrost()
        .disabled(!model.acceptsActions || runtime.isUnavailable)
        .sheet(item: $draft) { entry in
            BrowserSiteSearchForm(entry: entry, entries: runtime.document.siteSearches, error: model.errorMessage, save: { value in
                model.perform {
                    try await runtime.store.saveSiteSearch(value)
                    await runtime.refresh()
                    draft = nil
                }
            }, cancel: { draft = nil })
        }
    }
}

@MainActor
struct BrowserSiteSearchForm: View {
    @State var entry: BrowserSiteSearch
    let entries: [BrowserSiteSearch]
    let error: String?
    let save: (BrowserSiteSearch) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(uiText("Site Search")).font(Font(BrandTextStyle.ui.font(size: 22, weight: .semibold)))
            field(uiText("Name"), value: $entry.name, identifier: "name")
            field(uiText("Shortcut"), value: $entry.shortcut, identifier: "shortcut")
            field(uiText("URL"), value: $entry.template, identifier: "url")
            if let error { Text(error).foregroundStyle(.red).font(Font(BrandFonts.ui(12))) }
            HStack {
                Spacer()
                Button(uiText("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(uiText("Save")) { save(entry) }.keyboardShortcut(.defaultAction)
                    .disabled((try? entry.validate(in: entries)) == nil)
                    .accessibilityIdentifier("settings-site-search-save")
            }
        }.padding(22).frame(width: 440).font(Font(BrandFonts.ui(13))).settingsFrost()
    }

    private func field(_ title: String, value: Binding<String>, identifier: String) -> some View {
        HStack {
            Text(title).frame(width: 70, alignment: .leading)
            TextField(title, text: value).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings-site-search-" + identifier)
        }
    }
}
