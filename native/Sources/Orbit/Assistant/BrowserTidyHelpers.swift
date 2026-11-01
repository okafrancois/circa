import AppKit
import BrowserCore
import BrowserShell
import BrowserEngine

/// Window-scoped metadata helpers. Initial snapshots establish a baseline, never work to replay.
@MainActor
final class BrowserTidyHelpers<Engine: BrowserEngine> {
    weak var owner: BrowserWindowController<Engine>?
    private var previous: BrowserOrganizationSnapshot?
    private var downloadsSeen: Set<BrowserDownloadKey> = []
    private var validations: [UUID: @MainActor () -> Bool] = [:]
    private var requests: [UUID: BrowserAIHelperRequest] = [:]
    private(set) var originals: [TabID: String] = [:]

    init(owner: BrowserWindowController<Engine>) { self.owner = owner }

    private func choice(for url: URL) -> (BrowserAIPreferences, BrowserAIModelChoice)? {
        guard let owner, let preferences = owner.settingsPreferences?.runtime.document.ai,
              preferences.helpers.tidyTitlesAndDownloads, let service = owner.aiService,
              ["http", "https"].contains(url.scheme ?? ""),
              BrowserAIPolicy.allowsPageAccess(preferences, isPrivate: owner.isPrivateWindow, host: url.host),
              let choice = preferences.defaultModels[.quick] ?? BrowserAIPolicy.automaticChoice(for: .quick, statuses: service.statuses),
              BrowserAIPolicy.choices(for: .quick, statuses: service.statuses).contains(choice),
              let status = service.statuses[choice.provider], status.state.isReady,
              status.state.usage?.limitReached != true else { return nil }
        return (preferences, choice)
    }

    func cancel() {
        for request in requests.values { request.cancel() }
        requests.removeAll(); validations.removeAll()
    }
    func revokeStaleRequests() {
        for (id, valid) in validations where !valid() { requests[id]?.cancel(); requests[id] = nil; validations[id] = nil }
    }
    func reconcile() {
        revokeStaleRequests()
        guard let owner, let next = owner.session.organization else { return }
        if owner.tidyDownloadSpace != next.spaceID, let panel = owner.tidyDownloadPanel {
            owner.window?.removeChildWindow(panel); panel.orderOut(nil); owner.tidyDownloadPanel = nil
        }
        let old = previous
        previous = next
        for tab in next.allTabs {
            originals[tab.id] = tab.tidiedTitle == tab.customTitle ? tab.tidiedTitle : nil
        }
        guard let old, old.profileID == next.profileID, old.spaceID == next.spaceID,
              owner.settingsPreferences?.runtime.document.ai.isEnabled == true,
              owner.settingsPreferences?.runtime.document.ai.helpers.tidyTitlesAndDownloads == true else { return }
        let previousTabs = Dictionary(old.allTabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for tab in next.allTabs {
            guard case .pinned = tab.section, tab.customTitle == nil, let title = tab.pageTitle,
                  let prior = previousTabs[tab.id], case .today = prior.section,
                  prior.customTitle == nil, let (preferences, model) = choice(for: tab.url),
                  let service = owner.aiService else { continue }
            let surface = tab.occurrenceID.flatMap { owner.session.surface(for: $0) }
            let generation = surface?.documentGeneration
            let valid: @MainActor () -> Bool = { [weak self, weak owner, weak surface] in
                guard let self, let owner, let current = owner.session.organization,
                      self.choice(for: tab.url)?.0 == preferences, self.choice(for: tab.url)?.1 == model else { return false }
                return current.profileID == next.profileID && current.spaceID == next.spaceID
                    && current.organizationRevision == next.organizationRevision
                    && owner.session.organizationTab(tab.id) == tab && surface?.documentGeneration == generation
            }
            run(preferences: preferences, model: model, service: service, valid: valid,
                instructions: "Shorten the page title to a clear, concise pinned tab name. Return only the name.",
                metadata: String(decoding: title.utf8.prefix(4096), as: UTF8.self)) { [weak self, weak owner] output in
                guard let name = BrowserAIHelperName.title(output), name != title else { return }
                self?.originals[tab.id] = name
                owner?.session.tidyPinnedTitle(tab, revision: next.organizationRevision, to: name, isCurrent: valid)
            }
        }
    }

    func restore(_ id: TabID) {
        guard let owner, let name = originals[id], let tab = owner.session.organizationTab(id),
              tab.customTitle == name, let snapshot = owner.session.organization else { return }
        originals[id] = nil
        owner.session.tidyPinnedTitle(tab, revision: snapshot.organizationRevision, to: nil, isCurrent: { [weak owner] in
            owner?.session.organizationTab(id) == tab
        })
    }

    func downloadChanges(_ delta: BrowserDownloadCoordinator.Delta) {
        guard let owner else { return }
        for item in delta.changed {
            guard item.owner.sourceWindowID == owner.session.organization?.windowID else { continue }
            let fresh = downloadsSeen.insert(item.key).inserted
            // Registrations arrive before completion. History restored before subscription is excluded.
            guard !fresh, item.state == .complete, item.fileAvailability == .available,
                  item.owner.profileID == owner.session.activeProfileID,
                  let downloadURL = item.currentURL, choice(for: downloadURL) != nil,
                  let occurrence = item.owner.sourceOccurrenceID, let surface = owner.session.surface(for: occurrence),
                  surface.profileID == item.owner.profileID,
                  let source = surface.navigationState.committedURL, let (preferences, model) = choice(for: source),
                  let service = owner.aiService,
                  let lease = owner.downloads.coordinator.renameLease(in: item.context) else { continue }
            // Consume completion once, even if validation fails or the provider refuses.
            guard !completed.contains(item.key) else { continue }
            completed.insert(item.key)
            let generation = surface.documentGeneration
            let valid: @MainActor () -> Bool = { [weak self, weak owner, weak surface] in
                guard let self, let owner, let surface else { return false }
                return self.choice(for: source)?.0 == preferences && self.choice(for: source)?.1 == model
                    && self.choice(for: downloadURL) != nil
                    && owner.session.surface(for: occurrence) === surface && surface.documentGeneration == generation
                    && surface.navigationState.committedURL == source
                    && owner.session.activeProfileID == item.owner.profileID
                    && owner.downloads.coordinator.renameLease(in: item.context) == lease
            }
            run(preferences: preferences, model: model, service: service, valid: valid,
                instructions: "Suggest a concise descriptive download filename based only on the original filename. Return only a filename. Preserve the extension.",
                metadata: String(decoding: lease.url.lastPathComponent.utf8.prefix(1024), as: UTF8.self)) { [weak owner] output in
                guard let owner, let name = BrowserAIHelperName.download(output, original: lease.url.lastPathComponent),
                      let renamed = owner.downloads.coordinator.rename(lease, to: name) else { return }
                owner.showTidyDownload(renamed, original: lease.url.lastPathComponent)
            }
        }
    }
    private var completed: Set<BrowserDownloadKey> = []

    private func run(preferences: BrowserAIPreferences, model: BrowserAIModelChoice, service: OrbitAIService,
                     valid: @escaping @MainActor () -> Bool, instructions: String, metadata: String,
                     apply: @escaping @MainActor (String) -> Void) {
        let id = UUID(), request = BrowserAIHelperRequest()
        requests[id] = request
        validations[id] = valid
        Task { [weak self] in
            defer { self?.requests[id] = nil; self?.validations[id] = nil }
            guard valid() else { return }
            let result = try? await request.run(client: service.client(model.provider), choice: model,
                instructions: instructions, preferences: { valid() ? preferences : .init() },
                isCurrent: valid, extract: { metadata }, outputLimit: 240)
            guard valid(), let result else { return }
            apply(result)
        }
    }
}
