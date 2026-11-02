import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Observation
import SwiftUI

extension BrowserWindowController {
    var errandChoice: BrowserAIModelChoice? {
        guard let service = aiService else { return nil }
        let choice = settingsPreferences?.runtime.document.ai.defaultModels[.errands]
            ?? BrowserAIPolicy.automaticChoice(for: .errands, statuses: service.statuses)
        return choice.flatMap { readyErrandChoice($0) ? $0 : nil }
    }
    func readyErrandChoice(_ choice: BrowserAIModelChoice) -> Bool {
        guard let service = aiService else { return false }
        return BrowserAIPolicy.choices(for: .errands, statuses: service.statuses).contains { $0.provider == choice.provider && $0.model == choice.model }
            && (choice.effort == nil || service.statuses[choice.provider]?.models.contains { $0.id == choice.model && $0.efforts.contains(choice.effort!) } == true)
            && service.statuses[choice.provider]?.state.isReady == true
            && service.statuses[choice.provider]?.state.usage?.limitReached != true
    }
    var errandActive: Bool {
        guard let task = errand else { return errandStarting }
        return [.thinking, .waiting, .acting].contains(task.phase) || errandStarting
    }
    var canStartErrand: Bool {
        guard !errandActive, assistantEnabled, errandChoice != nil,
              let current = session.organization, let selected = current.selectedTab,
              !selected.isOpenInAnotherWindow,
              assistantSources.contains(where: { $0.id == selected.id.rawValue }),
              session.selectedSurface is any BrowserAIErrandPageReading else { return false }
        return !current.rows(includingCollapsed: true).contains { row in
            guard case .split(let id) = row.node, case .split(let split)? = current.item(for: .split(id)) else { return false }
            return split.tabs.contains { $0.id == selected.id }
        }
    }
    func prefillErrand() {
        guard canStartErrand, let choice = errandChoice else { return }
        if assistantHost != nil { closeAssistant() }
        guard let conversation = ensureAssistant() else { return }
        conversation.stop(); conversation.switchProvider(to: choice)
        if let selected = session.organization?.selectedTab,
           let source = assistantSources.first(where: { $0.id == selected.id.rawValue }) { conversation.select(source) }
        errandDraft = true; toggleAssistant()
    }
    func submitErrand(_ goal: String) -> Bool {
        let choice = aiConversation?.choice ?? errandChoice
        guard errandDraft, canStartErrand, let choice, readyErrandChoice(choice), let service = aiService,
              let owner = session.organization, let selected = owner.selectedTab,
              aiConversation?.selectedSources.contains(where: { $0.id == selected.id.rawValue }) == true,
              !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              goal.count <= 4000, goal.utf8.count <= 16000 else { return false }
        stopErrand()
        let token = UUID(); errandEpoch = token
        let admission = BrowserSidebarSelectionAdmission()
        errandStartAdmission = admission; errandStarting = true; errandDraft = false
        errandStartChoice = choice; errandStartPreferences = settingsPreferences?.runtime.document.ai
        errandOwner = owner; errandTabs = [selected.id]; errandFolder = nil; errand = nil
        tidyHelpers.revokeStaleRequests()
        errandSummaryID = TabID()
        renderErrandSidebar()
        let departingComposer = assistantHost
        closeAssistant()
        let title = BrowserAIHelperName.title(String((goal.split(whereSeparator: \.isNewline).first ?? "").prefix(80))) ?? uiText("Errand")
        errandStartTask = Task { [weak self] in
            guard let self else { return }
            defer { if errandEpoch == token {
                errandStarting = false; errandStartAdmission = nil; errandStartTask = nil
                errandStartChoice = nil; errandStartPreferences = nil; renderErrandSidebar()
            } }
            let closeDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while departingComposer?.superview != nil {
                guard !Task.isCancelled, errandEpoch == token, admission.isValid, window?.isVisible == true,
                      ContinuousClock.now < closeDeadline else { stopErrand(); return }
                try? await Task.sleep(for: .milliseconds(16))
            }
            let folder = await session.createErrandFolder(title: title, tab: selected.id, admission: admission,
                isCurrent: { [weak self] in
                    guard let self, errandEpoch == token, admission.isValid else { return false }
                    return assistantEnabled && readyErrandChoice(choice) && session.activeProfileID == owner.profileID
                        && window?.isVisible == true && settingsPreferences?.runtime.document.ai == errandStartPreferences
                        && session.organization?.spaceID == owner.spaceID && session.organization?.selectedTab?.id == selected.id
                        && assistantSources.contains { $0.id == selected.id.rawValue }
                }).value
            guard let folder, errandEpoch == token, admission.isValid, !Task.isCancelled else { return }
            errandFolder = folder
            guard errandOwnerCurrent(choice) else { stopErrand(); return }
            for id in errandTabs {
                if let occurrence = session.organization?.tab(id)?.occurrenceID, let surface = session.surface(for: occurrence) {
                    errandGuardedSurfaces.insert(ObjectIdentifier(surface))
                }
            }
            let task = BrowserAIErrand(goal: goal, choice: choice, client: service.client(choice.provider),
                preferences: { [weak self] in self?.settingsPreferences?.runtime.document.ai ?? .init() },
                ownerCurrent: { [weak self] in self?.errandEpoch == token && self?.errandOwnerCurrent(choice) == true },
                observe: { [weak self] in
                    guard let self, errandEpoch == token else { throw CancellationError() }
                    try await waitForErrandLoads(choice: choice, token: token)
                    await clearErrandLeases()
                    var pages: [BrowserAIErrandPage] = []
                    let goalBytes = (try? JSONEncoder().encode(goal).count) ?? 16_000
                    let perPage = max(256, (18_000 - goalBytes) / max(1, errandTabs.count))
                    for id in errandTabs.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
                        guard errandEpoch == token, errandOwnerCurrent(choice),
                              let occurrence = session.organization?.tab(id)?.occurrenceID,
                              let surface = session.surface(for: occurrence),
                              let reader = surface as? any BrowserAIErrandPageReading else { throw BrowserEngineError.documentChanged }
                        let page = try await reader.observeErrandPage(tabID: id.rawValue, revision: surface.documentGeneration,
                            isCurrent: { [weak self, weak surface] in
                                guard let self, let surface else { return false }
                                return errandEpoch == token && errandOwnerCurrent(choice) && session.surface(for: occurrence) === surface
                            })
                        guard errandEpoch == token, errandOwnerCurrent(choice) else {
                            await reader.clearErrandTarget(snapshot: page.snapshot); throw CancellationError()
                        }
                        errandLeases[id.rawValue] = (reader, page)
                        pages.append(try boundedErrandPage(page, bytes: perPage))
                    }
                    return .init(pages: pages)
                }, isCurrent: { [weak self] in
                    self?.errandEpoch == token && self?.errandPagesCurrent($0, choice: choice) == true
                }, execute: { [weak self] action, observation in
                    guard let self, errandEpoch == token, errandPagesCurrent(observation, choice: choice) else { return false }
                    return try await executeErrand(action, observation: observation, choice: choice, token: token)
                })
            errand = task; task.start(); watchErrand(task)
        }
        return true
    }
    private func boundedErrandPage(_ page: BrowserAIErrandPage, bytes: Int) throws -> BrowserAIErrandPage {
        var text = page.text, targets = page.targets
        func value() -> BrowserAIErrandPage { .init(id: page.id, snapshot: page.snapshot, revision: page.revision,
            url: page.url, title: page.title, text: text, targets: targets) }
        while try JSONEncoder().encode(value()).count > bytes {
            if !text.isEmpty { text = String(text.prefix(text.count / 2)) }
            else if !targets.isEmpty { targets.removeLast() }
            else { throw BrowserAIError.failed }
        }
        return value()
    }
    private func executeErrand(_ action: BrowserAIErrandAction, observation: BrowserAIErrandObservation,
                                choice: BrowserAIModelChoice, token: UUID) async throws -> Bool {
        if case .open(let url) = action {
            guard errandTabs.count < 8, let folder = errandFolder,
                  BrowserAIPolicy.allowsPageAccess(settingsPreferences?.runtime.document.ai ?? .init(), isPrivate: isPrivateWindow, host: url.host) else { return false }
            let admission = BrowserSidebarSelectionAdmission()
            errandNavigationAdmission = admission; errandOpeningURL = url
            defer {
                if errandEpoch == token {
                    errandNavigationAdmission = nil; errandOpening = nil; errandOpeningURL = nil
                    errandNavigationGrants.values.forEach { $0.revoke() }; errandNavigationGrants = [:]
                }
            }
            let created = await session.openErrandTab(url: url, folder: folder, expectedTabs: errandTabs, admission: admission, isCurrent: { [weak self] in
                guard let self else { return false }
                return errandEpoch == token && admission.isValid && errandPagesCurrent(observation, choice: choice)
            }, onCreate: { [weak self] id in
                guard let self, errandEpoch == token else { return }
                errandTabs.insert(id); errandOpening = id
            }).value
            guard let created, admission.isValid, errandEpoch == token else { return false }
            try await waitForErrandLoads(choice: choice, token: token)
            return errandOwnerCurrent(choice) && assistantSources.contains { $0.id == created.rawValue }
        }
        guard let page = observation.pages.first(where: { $0.id == action.tabID }),
              let occurrence = session.organization?.allTabs.first(where: { $0.id.rawValue == page.id })?.occurrenceID,
              let surface = session.surface(for: occurrence), let reader = surface as? any BrowserAIErrandPageReading else { return false }
        let key = ObjectIdentifier(surface)
        if case .click = action, let target = page.targets.first(where: { $0.id == action.targetID }) {
            errandNavigationGrants[key] = .init(surface: surface, destination: target.destination ?? page.url, form: target.submitsForm)
        }
        defer { if errandEpoch == token { errandNavigationGrants.removeValue(forKey: key)?.revoke() } }
        let result = try await reader.executeErrandAction(action, page: page, isCurrent: { [weak self, weak surface] in
            guard let self, let surface else { return false }
            return errandEpoch == token && errandOwnerCurrent(choice) && session.surface(for: occurrence) === surface
        })
        if result { try await waitForErrandLoads(choice: choice, token: token) }
        return result && errandEpoch == token && errandOwnerCurrent(choice)
    }
    private func waitForErrandLoads(choice: BrowserAIModelChoice, token: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while true {
            guard !Task.isCancelled, errandEpoch == token, errandOwnerCurrent(choice) else { throw CancellationError() }
            let surfaces = errandTabs.compactMap { session.organization?.tab($0)?.occurrenceID }.compactMap { session.surface(for: $0) }
            if surfaces.count == errandTabs.count && surfaces.allSatisfy({ !$0.navigationState.isLoading && $0.navigationState.committedURL != nil }) { return }
            guard ContinuousClock.now < deadline else { throw BrowserAIError.failed }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    func errandOwnerCurrent(_ choice: BrowserAIModelChoice) -> Bool {
        guard assistantEnabled, !session.isClosed, window?.isVisible == true,
              let owner = errandOwner, let current = session.organization,
              owner.profileID == current.profileID, owner.spaceID == current.spaceID, owner.windowID == current.windowID,
              let folder = errandFolder, case .folder(let item)? = current.item(for: .folder(folder)), item.liveFolder == nil,
              Set(item.children.compactMap { $0.node.tabID }) == Set(errandTabs.filter({ $0 != errandOpening || current.tab($0) != nil })),
              item.children.count == errandTabs.filter({ $0 != errandOpening || current.tab($0) != nil }).count,
              !errandTabs.isEmpty, errandTabs.count <= 8, readyErrandChoice(choice) else { return false }
        return errandTabs.allSatisfy { id in
            if id == errandOpening, current.tab(id) == nil { return errandNavigationAdmission?.isValid == true }
            guard let tab = current.tab(id), !tab.isOpenInAnotherWindow, let occurrence = tab.occurrenceID else { return false }
            if id == errandOpening, session.surface(for: occurrence) == nil { return true }
            guard let surface = session.surface(for: occurrence), surface.profileID == owner.profileID else { return false }
            if id == errandOpening, surface.navigationState.committedURL == nil { return true }
            return assistantSources.contains { $0.id == id.rawValue }
        }
    }
    func errandPagesCurrent(_ observation: BrowserAIErrandObservation, choice: BrowserAIModelChoice) -> Bool {
        guard errandOwnerCurrent(choice), Set(observation.pages.map(\.id)) == Set(errandTabs.map(\.rawValue)) else { return false }
        return observation.pages.allSatisfy { page in
            assistantSources.contains { $0.id == page.id && $0.revision == page.revision && $0.url == page.url }
        }
    }
    func isErrandSurface(_ surface: Surface) -> Bool {
        if errandGuardedSurfaces.contains(ObjectIdentifier(surface)) { return true }
        guard let occurrence = session.occurrenceID(for: surface), let id = session.tabID(for: occurrence) else { return false }
        return errandTabs.contains(id) && errandActive
    }
    func errandNavigationPolicy(_ action: BrowserNavigationAction, in surface: Surface) -> BrowserNavigationActionPolicy? {
        guard isErrandSurface(surface) else { return nil }
        if action.isMainFrame == false { return .allow }
        let key = ObjectIdentifier(surface)
        if !errandActive {
            return .cancel
        }
        errandGuardedSurfaces.insert(key)
        if errandNavigationGrants[key] == nil, let url = errandOpeningURL,
           let occurrence = session.occurrenceID(for: surface), session.tabID(for: occurrence) == errandOpening,
           errandNavigationAdmission?.isValid == true {
            errandNavigationGrants[key] = .init(surface: surface, destination: url)
        }
        guard let choice = errand?.choice, errandOwnerCurrent(choice), let url = action.url,
              BrowserAIPolicy.allowsPageAccess(settingsPreferences?.runtime.document.ai ?? .init(), isPrivate: isPrivateWindow, host: url.host),
              errandNavigationGrants[key]?.permits(action, from: surface) == true else { stopErrand(); return .cancel }
        return .allow
    }
    func stopErrand(animated: Bool = false) {
        let wasActive = errandActive
        errandEpoch = UUID(); errandStartAdmission?.revoke(); errandStartAdmission = nil
        errandStartChoice = nil; errandStartPreferences = nil
        errandStartTask?.cancel(); errandStartTask = nil
        errandNavigationAdmission?.revoke(); errandNavigationAdmission = nil
        errandNavigationGrants.values.forEach { $0.revoke() }; errandNavigationGrants = [:]
        errand?.stop(); errandDraft = false; errandStarting = false
        errandOpening = nil; errandOpeningURL = nil; errandObservation = UUID()
        (errandHost as? BrowserErrandApprovalCard)?.dismiss(animated: animated)
        errandHost = nil; errandRenderedApprovalID = nil; errandCardSurfaceID = nil
        for id in wasActive ? errandTabs : [] {
            guard let occurrence = session.organization?.tab(id)?.occurrenceID, let surface = session.surface(for: occurrence), owns(surface) else { continue }
            surface.stopLoading()
        }
        let leases = errandLeases; errandLeases = [:]
        for (_, (reader, page)) in leases { Task { await reader.clearErrandTarget(snapshot: page.snapshot) } }
        renderErrandSidebar()
    }
    private func clearErrandLeases() async {
        let leases = errandLeases; errandLeases = [:]
        for (_, (reader, page)) in leases { await reader.clearErrandTarget(snapshot: page.snapshot) }
    }
    func reconcileErrand() {
        if errandStarting {
            guard assistantEnabled, window?.isVisible == true, let choice = errandStartChoice, readyErrandChoice(choice),
                  errandStartPreferences == settingsPreferences?.runtime.document.ai,
                  errandOwner?.profileID == session.activeProfileID, errandOwner?.spaceID == session.organization?.spaceID else { stopErrand(); return }
        }
        guard let task = errand else { return }
        if errandActive, !errandOwnerCurrent(task.choice) { stopErrand(); return }
        task.reconcile()
        if task.phase == .stopped || { if case .failed = task.phase { return true }; return false }() {
            if !errandLeases.isEmpty { stopErrand() }
        }
        renderErrand(task)
    }
    func watchErrand(_ task: BrowserAIErrand) {
        let token = errandObservation
        withObservationTracking { _ = task.phase; _ = task.approval; _ = task.summary } onChange: { [weak self, weak task] in
            Task { @MainActor in
                guard let self, let task, self.errand === task, self.errandObservation == token else { return }
                self.reconcileErrand(); self.watchErrand(task)
            }
        }
        renderErrand(task)
    }
    func renderErrand(_ task: BrowserAIErrand) {
        renderErrandSidebar()
        guard let approval = task.approval,
              let selected = session.organization?.selectedTab, errandTabs.contains(selected.id),
              approval.page == nil || approval.page?.id == selected.id.rawValue,
              let surface = session.selectedSurface, let parent = surface.hostView.superview else {
            let sameSurface = session.selectedSurface.map { ObjectIdentifier($0) == errandCardSurfaceID } ?? false
            let departing = [.acting, .thinking, .completed].contains(task.phase) && sameSurface && errandOwnerCurrent(task.choice)
            (errandHost as? BrowserErrandApprovalCard)?.dismiss(animated: departing)
            errandHost = nil; errandRenderedApprovalID = nil; errandCardSurfaceID = nil; return
        }
        guard errandRenderedApprovalID != approval.id else { return }
        errandHost?.removeFromSuperview(); errandHost = nil
        let palette = BrowserAssistantPalette(theme: windowShell.theme, appearance: window?.effectiveAppearance ?? NSApp.effectiveAppearance)
        let host = BrowserErrandApprovalCard(approval: approval, palette: palette,
            stop: { [weak self] in self?.stopErrand(animated: true) }, allow: { [weak self, weak task] in
                guard let self, let task, self.errand === task, window?.isKeyWindow == true,
                      window?.isOnActiveSpace == true, errandHost?.isHiddenOrHasHiddenAncestor == false,
                      errandRenderedApprovalID == approval.id, session.selectedSurface === surface,
                      errandPagesCurrent(approval.observation, choice: task.choice) else { return }
                task.allowOnce(approval.id)
            })
        host.translatesAutoresizingMaskIntoConstraints = false
        host.isHidden = approval.page != nil
        parent.addSubview(host); errandHost = host; errandRenderedApprovalID = approval.id
        errandCardSurfaceID = ObjectIdentifier(surface)
        let width = host.widthAnchor.constraint(equalToConstant: 420); width.priority = .defaultHigh
        NSLayoutConstraint.activate([host.centerXAnchor.constraint(equalTo: surface.hostView.centerXAnchor),
            host.bottomAnchor.constraint(equalTo: surface.hostView.bottomAnchor, constant: -20), width,
            host.widthAnchor.constraint(lessThanOrEqualTo: surface.hostView.widthAnchor, constant: -40)])
        parent.layoutSubtreeIfNeeded()
        if !host.isHidden { host.enter() }
        if let page = approval.page, let target = approval.action.targetID, let reader = surface as? any BrowserAIErrandPageReading {
            Task { [weak self, weak task] in
                guard let self, let task else { return }
                let rgb = palette.strong.usingColorSpace(.sRGB) ?? .controlAccentColor
                let accent = String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
                let foreground = palette.onStrong.usingColorSpace(.sRGB)!
                let ink = String(format: "#%02X%02X%02X", Int(foreground.redComponent * 255), Int(foreground.greenComponent * 255), Int(foreground.blueComponent * 255))
                let valid = (try? await reader.highlightErrandTarget(target, page: page, color: accent, ink: ink, provider: BrowserSettingsAIText.name(task.choice.provider), reducedMotion: OrbitMotionPreferences.prefersReducedMotion, isCurrent: { [weak self, weak task] in
                    guard let self, let task else { return false }
                    return self.errand === task && task.approval?.id == approval.id && errandPagesCurrent(approval.observation, choice: task.choice)
                })) == true
                if !valid, task.approval?.id == approval.id { stopErrand() }
                else if valid, task.approval?.id == approval.id, self.errandHost === host { host.isHidden = false; host.enter() }
            }
        }
    }

    func openErrandSummary() {
        guard assistantEnabled, errandOwner?.profileID == session.activeProfileID,
              errandOwner?.spaceID == session.organization?.spaceID, errand?.summary.isEmpty == false else { return }
        if assistantHost == nil { toggleAssistant() } else { reconcileAssistant() }
    }
    func cancelErrandForOwnerNavigation(_ surface: Surface) {
        guard isErrandSurface(surface) else { return }
        stopErrand(); errandGuardedSurfaces.remove(ObjectIdentifier(surface))
    }
    /// CEF's gesture bit may remain true for several scripted callbacks after one approved
    /// action. Only a new native event delivered to the actual page releases its quarantine.
    func handleErrandOwnerInput(_ event: NSEvent) {
        guard event.window === window, let surface = session.selectedSurface, isErrandSurface(surface),
              let root = window?.contentView else { return }
        let hit: NSView?
        if event.type == .keyDown { hit = window?.firstResponder as? NSView }
        else if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
        } else { return }
        guard let hit, hit === surface.hostView || hit.isDescendant(of: surface.hostView) else { return }
        cancelErrandForOwnerNavigation(surface)
    }
    func renderErrandSidebar() {
        let current = assistantEnabled && errandOwner?.profileID == session.activeProfileID && errandOwner?.spaceID == session.organization?.spaceID
        sidebar.setErrandActive(current && errandActive)
        sidebar.page.list.onErrandSummary = { [weak self] in self?.openErrandSummary() }
        var marks: [BrowserOrganizationNode: BrowserErrandRowMark.State] = [:]
        if current, let task = errand, let folder = errandFolder,
           session.organization?.item(for: .folder(folder)) != nil {
            marks[.folder(folder)] = .count(task.completedActions)
            for id in errandTabs {
                if task.phase == .completed { marks[.tab(id)] = .done }
                else if task.phase == .waiting, task.approval?.page?.id == id.rawValue || task.approval?.page == nil { marks[.tab(id)] = .waiting }
                else if errandActive { marks[.tab(id)] = .working }
            }
            sidebar.presentErrandSummary(task.summary.isEmpty ? nil : .init(id: errandSummaryID, folder: folder, profile: errandOwner!.profileID, space: errandOwner!.spaceID))
        } else { sidebar.presentErrandSummary(nil) }
        sidebar.page.list.errandMarks = marks
        refreshAssistantErrandPresentation()
    }
}
