import AppKit
import BrowserCore
import BrowserEngine

@MainActor
final class BrowserArchivePresentation {
    struct Request: Equatable {
        let profile: ProfileID
        /// Signals a change of this profile's archive; rows are read with `archivedTabs(matching:)`.
        let revision: UInt64
        let query: String
        let threshold: BrowserAutoArchiveThreshold
        let inheritsThreshold: Bool
    }
    /// Tests can answer the production confirmation without showing a window.
    var confirmation: (@MainActor (NSAlert) async -> NSApplication.ModalResponse)?
    var confirmationTask: Task<Void, Never>?
    var collectProtection: @MainActor () async -> Set<TabID> = { [] }
    lazy var view = BrowserArchiveView()
    var isPresented = false
    var request: Request?
    var displayedProfile: ProfileID?
    var previewTabID: TabID?
    var task: Task<Void, Never>?
}

extension BrowserWindowController {
    func installArchive(in root: NSView) {
        let view = archive.view
        view.setLibraryEmbedded()
        view.favicon = { [weak self] url in
            guard let self, let profile = archive.displayedProfile else { return nil }
            return sidebar.previewIcon(profile, url)
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            view.topAnchor.constraint(equalTo: root.topAnchor),
            view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view.onBack = { [weak self] in self?.submitInput { $0.hideArchive() } }
        view.onDownloads = { [weak self] in self?.submitInput { $0.showDownloads() } }
        view.onSearch = { [weak self] in self?.renderArchive() }
        view.onRestore = { [weak self] id in
            guard let self, let profile = archive.displayedProfile else { return }
            submitInput { controller in
                guard controller.session.activeProfileID == profile else { return }
                controller.session.restoreArchivedTab(id)
                // Returning focus before restore completes can reactivate the displaced page.
                controller.session.performWindowAction { [weak controller] in controller?.hideArchive() }
            }
        }
        view.onPreview = { [weak self] record in
            guard let self, let profile = archive.displayedProfile, record.profileID == profile else { return }
            submitInput { controller in
                guard controller.session.activeProfileID == profile else { return }
                controller.archive.previewTabID = record.id
                guard controller.openLibraryBoostPage(record.tab.url, profile: profile) != nil else {
                    controller.archive.previewTabID = nil
                    return
                }
            }
        }
        view.onDelete = { [weak self] id in
            guard let self, let profile = archive.displayedProfile else { return }
            submitInput { controller in
                guard controller.session.activeProfileID == profile else { return }
                controller.session.deleteArchivedTabs([id])
            }
        }
        view.onClear = { [weak self] in self?.submitInput { $0.confirmClearArchive() } }
        view.onSettings = { [weak self] index in
            guard let self, let profile = archive.displayedProfile else { return }
            let options: [BrowserAutoArchiveThreshold?] = [nil, .twelveHours, .oneDay, .sevenDays, .thirtyDays]
            guard options.indices.contains(index) else { return }
            submitInput { $0.session.setAutoArchiveThreshold(options[index], inProfile: profile) }
        }
    }

    func showArchive() { showLibrary(.archive) }

    func hideArchive() { hideLibrary() }

    func deactivateArchiveCategory() {
        archive.isPresented = false
        archive.view.isHidden = true
        archive.request = nil
        archive.displayedProfile = nil
        archive.task?.cancel()
        archive.task = nil
    }

    func renderArchive() {
        guard archive.isPresented, let organization = session.organization else { return }
        let request = BrowserArchivePresentation.Request(profile: organization.profileID,
            revision: organization.archiveRevision, query: archive.view.searchField.stringValue,
            threshold: organization.autoArchiveThreshold, inheritsThreshold: organization.inheritsAutoArchiveThreshold)
        guard archive.request != request else { return }
        archive.view.settings.isEnabled = false
        archive.request = request
        archive.task?.cancel()
        let profileName = session.catalog?.profiles.first { $0.id == request.profile }?.name ?? ""
        let options: [BrowserAutoArchiveThreshold] = [.twelveHours, .oneDay, .sevenDays, .thirtyDays]
        let setting = organization.inheritsAutoArchiveThreshold ? 0 : (options.firstIndex(of: organization.autoArchiveThreshold).map { $0 + 1 } ?? 0)
        // Remove the old profile immediately; an asynchronous query never leaves private rows visible.
        if archive.displayedProfile != request.profile {
            archive.displayedProfile = nil
            archive.view.render([], profileName: profileName, setting: setting)
        }
        let spaceNames = Dictionary(uniqueKeysWithValues: (session.catalog?.spaces ?? []).map { ($0.id, $0.name) })
        let records = session.archivedTabs(matching: request.query)
        archive.task = Task { [weak self] in
            let result = await records.value
            guard !Task.isCancelled, let self, archive.isPresented, archive.request == request,
                  session.activeProfileID == request.profile else { return }
            archive.displayedProfile = request.profile
            archive.view.settings.isEnabled = true
            archive.view.render(result, profileName: profileName, setting: setting, spaceNames: spaceNames)
        }
    }

    func confirmClearArchive() {
        session.performWindowAction { [weak self] in
            guard let self, let window, let profile = session.activeProfileID else { return }
            let alert = makeClearArchiveAlert()
            let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.submitInput { $0.session.clearArchive(inProfile: profile) }
            }
            if let present = archive.confirmation {
                archive.confirmationTask = Task { respond(await present(alert)) }
            } else { alert.beginSheetModal(for: window, completionHandler: respond) }
        }
    }

    func makeClearArchiveAlert() -> NSAlert {
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = uiText("Are you sure you'd like to Clear Archive?")
        alert.informativeText = uiText("This action is permanent.")
        alert.addButton(withTitle: uiText("Clear Archive"))
        alert.addButton(withTitle: uiText("Cancel"))
        return alert
    }

    /// SB-LIST hook for the Today separator's Clear button. The store protects visible tabs.
    func clearTodayFromArchiveCommand() {
        session.clearTodayPreservingVisibleTabs(protection: archive.collectProtection)
    }
}
