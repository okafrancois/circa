import AppKit
import BrowserCore
import BrowserEngine
import Observation
import SwiftUI

@MainActor @Observable final class BrowserSkillDraft {
    var text = ""
    var selectionID: UUID?
    var revision = 0
    var editorRequested = false
    var editing: BrowserAISkill?
    var notice: String?
    var revokeRevision = 0
    private var pendingInvocation: UUID?
    func beginInvocation() -> UUID {
        cancelInvocation()
        let id = UUID(); pendingInvocation = id
        return id
    }
    func isCurrentInvocation(_ id: UUID) -> Bool { pendingInvocation == id }
    func cancelInvocation() {
        pendingInvocation = nil; notice = nil
        editorRequested = false; editing = nil
    }
    @discardableResult func applyInvocation(_ id: UUID, text: String) -> Bool {
        guard isCurrentInvocation(id) else { return false }
        pendingInvocation = nil; notice = nil
        self.text = text; revision += 1
        return true
    }
    private struct Permissions: Equatable {
        let enabled: Bool
        let readsPage: Bool
        let disabledSites: [String]
    }
    private var permissions: Permissions?
    @discardableResult func reconcilePermissions(_ preferences: BrowserAIPreferences) -> Bool {
        let next = Permissions(enabled: preferences.isEnabled, readsPage: preferences.readsCurrentTabOnRequest,
                               disabledSites: preferences.disabledSites)
        let changed = permissions.map { $0 != next } ?? false
        permissions = next
        if changed { cancelInvocation(); revokeRevision += 1 }
        return changed
    }
}

struct BrowserSkillOption: Identifiable {
    let id: String
    let name: String
    let prompt: String
    let scope: BrowserAISkillScope
    let custom: BrowserAISkill?
    var symbol: String {
        switch id {
        case "compare": "rectangle.split.2x1"
        case "csv": "tablecells"
        case "reply": "arrowshape.turn.up.left"
        default: "text.alignleft"
        }
    }
    static func options(_ custom: [BrowserAISkill]) -> [Self] {
        [Self(id: "summary", name: uiText("Summarize this tab"), prompt: uiText("Summarize this tab."), scope: .thisTab, custom: nil),
         Self(id: "compare", name: uiText("Compare tabs"), prompt: uiText("Compare the selected tabs."), scope: .selectedTabs, custom: nil),
         Self(id: "csv", name: uiText("Extract table to CSV"), prompt: uiText("Extract the table as CSV in your answer."), scope: .thisTab, custom: nil),
         Self(id: "reply", name: uiText("Draft a reply"), prompt: uiText("Draft a reply to the selected text."), scope: .selection, custom: nil)]
        + custom.map { Self(id: $0.id.uuidString, name: $0.name, prompt: $0.prompt, scope: $0.scope, custom: $0) }
    }
}

struct BrowserSkillInvocation: Equatable {
    let profile: ProfileID?
    let sources: [BrowserAIContextSource]
    let selectedTab: TabID?
    let conversation: UUID?
    let revocation: Int
}

extension BrowserWindowController {
    var skillInvocation: BrowserSkillInvocation {
        .init(profile: session.activeProfileID, sources: assistantSources,
              selectedTab: session.organization?.selectedTab?.id,
              conversation: aiConversation?.id, revocation: skillDraft.revokeRevision)
    }
    func prefillSkill(_ option: BrowserSkillOption, invocation: BrowserSkillInvocation, intent: UUID) async {
        guard assistantEnabled, window?.isVisible == true, skillInvocation == invocation,
              skillDraft.isCurrentInvocation(intent), let conversation = ensureAssistant(),
              skillDraft.isCurrentInvocation(intent) else { return }
        let admitted = skillInvocation
        skillDraft.notice = nil
        let profile = session.activeProfileID
        if let custom = option.custom {
            guard let profile, let runtime = skillsRuntime, let store = try? runtime.store(for: profile),
                  await store.snapshot().skills.contains(custom), skillInvocation == admitted,
                  skillDraft.isCurrentInvocation(intent) else { return }
        }
        let current = assistantSources.first { $0.id == session.organization?.selectedTab?.id.rawValue }
        skillSelection = nil; skillDraft.selectionID = nil
        if option.scope == .selection {
            for source in conversation.selectedSources { conversation.removeSource(source.id) }
            skillDraft.notice = uiText("Select visible page text to use this Skill.")
            guard let current, let tab = session.organization?.allTabs.first(where: { $0.id.rawValue == current.id }),
                  let occurrence = tab.occurrenceID, let surface = session.surface(for: occurrence),
                  let reader = surface as? any BrowserAIPageReading,
                  let text = try? await reader.readAISelection(revision: current.revision, isCurrent: { [weak self, weak surface] in
                      guard let self, let surface else { return false }
                      return self.assistantEnabled && self.skillInvocation == admitted && self.skillDraft.isCurrentInvocation(intent) && self.assistantSources.contains(current)
                          && self.session.surface(for: occurrence) === surface && self.aiConversation === conversation
                  }), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  assistantEnabled, skillInvocation == admitted, skillDraft.isCurrentInvocation(intent), assistantSources.contains(current), aiConversation === conversation else { return }
            skillSelection = (source: current, text: text)
            skillDraft.selectionID = current.id
            conversation.select(current)
        } else if option.scope == .thisTab {
            for source in conversation.selectedSources { conversation.removeSource(source.id) }
            if let current { conversation.select(current) }
        }
        guard assistantEnabled, skillInvocation == admitted, aiConversation === conversation,
              skillDraft.applyInvocation(intent, text: option.prompt) else { return }
        if assistantHost == nil { toggleAssistant() }
    }
}

/// Reads the shared authority inside SwiftUI's observation scope, including in native hosts.
struct BrowserAssistantSkillSourceMenu: View {
    let runtime: BrowserSkillsRuntime?
    let profile: ProfileID?
    let filter: String
    let width: CGFloat
    let choose: (BrowserSkillOption) -> Void
    let create: () -> Void
    let edit: (BrowserAISkill) -> Void
    var body: some View {
        let custom = profile.flatMap { runtime?.documents[$0]?.skills } ?? []
        let options = BrowserSkillOption.options(custom).filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
        BrowserAssistantSkillsMenu(options: options, width: width, choose: choose, create: create, edit: edit)
    }
}

struct BrowserAssistantSkillsMenu: View {
    let options: [BrowserSkillOption]
    let width: CGFloat
    let choose: (BrowserSkillOption) -> Void
    let create: () -> Void
    let edit: (BrowserAISkill) -> Void
    @State private var cursor = 0
    @Environment(\.assistantPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(uiText("Skills")).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.tertiary.swiftUI).padding(.horizontal, 8).frame(height: 24)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        Button { choose(option) } label: {
                            HStack(spacing: 8) {
                                OrbitIcon.view(sfName: option.symbol, pointSize: 16)
                                Text(option.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Text(option.scope == .thisTab ? uiText("This tab").lowercased() : option.scope == .selectedTabs ? uiText("@ tabs") : uiText("Selection").lowercased())
                                    .font(.system(size: 11.5)).foregroundStyle(cursor == index ? Color.white.opacity(0.8) : palette.tertiary.swiftUI)
                            }.font(.system(size: 13)).padding(.horizontal, 8).frame(height: 28)
                                .foregroundStyle(cursor == index ? Color.white : palette.ink.swiftUI)
                                .background(cursor == index ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).focusable(false).onHover { if $0 { cursor = index } }
                            .overlay {
                                if let skill = option.custom { BrowserSkillContextAnchor(edit: { edit(skill) }).accessibilityHidden(true) }
                            }
                    }
                }
            }.frame(height: min(256, CGFloat(options.count) * 28))
            Divider().padding(.vertical, 4).padding(.horizontal, 6)
            Button(action: create) {
                HStack { OrbitIcon.view(sfName: "plus", pointSize: 16); Text(uiText("New Skill…")); Spacer() }.font(.system(size: 13)).padding(.horizontal, 8).frame(height: 28)
            }.buttonStyle(.plain).focusable(false)
                .foregroundStyle(cursor == options.count ? Color.white : palette.ink.swiftUI)
                .background(cursor == options.count ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                .onHover { if $0 { cursor = options.count } }
        }.padding(5).frame(width: width)
            .onChange(of: options.map(\.id)) { _, _ in cursor = 0 }
            .background(BrowserAssistantKeyMonitor { event in
                switch event.keyCode {
                case BrowserAssistantKey.down: cursor = (cursor + 1) % (options.count + 1); return true
                case BrowserAssistantKey.up: cursor = (cursor + options.count) % (options.count + 1); return true
                case BrowserAssistantKey.returnKey, BrowserAssistantKey.keypadEnter:
                    if cursor < options.count { choose(options[cursor]) } else { create() }; return true
                default: return false
                }
            }.frame(width: 0, height: 0))
    }
}

struct BrowserAssistantSkillEditor: View {
    let runtime: BrowserSkillsRuntime
    let expected: BrowserAISkillDocument
    let original: BrowserAISkill?
    var sync: BrowserSyncRuntime? = nil
    let valid: () -> Bool
    let dismiss: () -> Void
    @State private var name = ""
    @State private var prompt = ""
    @State private var scope = BrowserAISkillScope.thisTab
    @State private var saveFailed = false
    @State private var staleSave = false
    @State private var saving = false
    @State private var mutation: Task<Void, Never>?
    @Environment(\.assistantPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(original == nil ? uiText("New Skill") : uiText("Edit Skill")).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(uiText("Name")).font(.system(size: 12)).foregroundStyle(palette.tertiary.swiftUI).frame(height: 18)
                TextField(uiText("Name"), text: $name).textFieldStyle(.plain).font(.system(size: 13))
                    .padding(.vertical, 5).padding(.horizontal, 9)
                    .background(palette.composer.swiftUI, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.line.swiftUI))
                    .accessibilityIdentifier("skill-name")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(uiText("What should it do?")).font(.system(size: 12)).foregroundStyle(palette.tertiary.swiftUI).frame(height: 18)
                TextEditor(text: $prompt).font(.system(size: 13)).lineSpacing(3).scrollContentBackground(.hidden)
                    .padding(4).frame(height: 52).background(palette.composer.swiftUI, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.line.swiftUI))
                    .accessibilityIdentifier("skill-prompt")
            }
            HStack(spacing: 8) {
                Picker(uiText("Works on"), selection: $scope) {
                    Text(uiText("This tab")).tag(BrowserAISkillScope.thisTab)
                    Text(uiText("Selected tabs")).tag(BrowserAISkillScope.selectedTabs)
                    Text(uiText("Selection")).tag(BrowserAISkillScope.selection)
                }.fixedSize()
                Spacer(minLength: 0)
                if let sync { BrowserSkillSyncLabel(runtime: sync).lineLimit(1) }
            }
            if saveFailed {
                Text(staleSave ? uiText("Skills changed. Reopen the editor and try again.") : uiText("Could not save Skill. Check the fields and try again.")).font(.system(size: 12))
            }
            HStack {
                if original != nil { Button(uiText("Delete")) { mutate(remove: true) }.settingsDestructive() }
                Spacer()
                Button(action: dismiss) { Text(uiText("Cancel")).font(.system(size: 12.5, weight: .medium)).padding(.horizontal, 10).frame(height: 26) }
                    .buttonStyle(BrowserAssistantButtonStyle(kind: .outlined(radius: 7)))
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("skill-cancel")
                Button { mutate(remove: false) } label: {
                    Text(original == nil ? uiText("Create Skill") : uiText("Save"))
                        .font(.system(size: 12.5, weight: .medium)).padding(.horizontal, 10).frame(height: 26).foregroundStyle(palette.onStrong.swiftUI)
                        .background(palette.strong.swiftUI, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).keyboardShortcut(.defaultAction).accessibilityIdentifier("skill-save")
            }.padding(.top, 4).disabled(saving)
        }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16).frame(width: 400).settingsFrost().foregroundStyle(palette.ink.swiftUI)
            .onDisappear { mutation?.cancel() }
            .onAppear { name = original?.name ?? ""; prompt = original?.prompt ?? ""; scope = original?.scope ?? .thisTab }
    }
    private func mutate(remove: Bool) {
        guard valid(), !saving else { dismiss(); return }
        saving = true
        mutation = Task { @MainActor in
            do {
                let store = try runtime.store(for: expected.profileID)
                guard valid() else { dismiss(); return }
                if remove, let original { try await store.remove(original.id, expected: expected) }
                else { try await store.save(BrowserAISkill(id: original?.id ?? UUID(), name: name, prompt: prompt, scope: scope), expected: expected) }
                sync?.skillsChanged()
                await runtime.refresh(expected.profileID)
                dismiss()
            } catch {
                await runtime.refresh(expected.profileID)
                staleSave = (error as? BrowserAISkillError) == .staleRevision || (error as? BrowserAISkillError) == .wrongProfile
                saving = false; saveFailed = true
            }
        }
    }
}

private struct BrowserSkillSyncLabel: View {
    @ObservedObject var runtime: BrowserSyncRuntime
    var body: some View {
        if runtime.enabled {
            Text(runtime.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Native menu tracking remains inside the owning popover's responder chain.
private struct BrowserSkillContextAnchor: NSViewRepresentable {
    let edit: () -> Void
    func makeNSView(context: Context) -> ContextView { ContextView() }
    func updateNSView(_ view: ContextView, context: Context) { view.edit = edit }
    final class ContextView: NSView {
        var edit: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard super.hitTest(point) != nil, let event = NSApp.currentEvent,
                  event.window === window,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
            return self
        }
        override func rightMouseDown(with event: NSEvent) {
            let menu = NSMenu()
            let item = NSMenuItem(title: uiText("Edit Skill…"), action: #selector(performEdit), keyEquivalent: "")
            item.target = self
            item.image = OrbitIcon.image(sfName: "pencil", pointSize: 14)
            menu.addItem(item)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        override func mouseDown(with event: NSEvent) { rightMouseDown(with: event) }
        @objc private func performEdit() { edit?() }
    }
}
