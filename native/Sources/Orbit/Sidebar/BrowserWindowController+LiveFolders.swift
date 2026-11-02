import AppKit
import BrowserCore
import BrowserShell

extension BrowserWindowController {
    func makeLiveFoldersCreationMenu(spaceID: SpaceID) -> NSMenuItem? {
        guard liveFoldersRuntime != nil, !isPrivateWindow, let profileID = session.activeProfileID else { return nil }
        let item = NSMenuItem(title: uiText("Live Folders"), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(BrowserSplitMenuItem(title: uiText("GitHub")) { [weak self] in
            self?.performLiveFolderCommand(spaceID: spaceID, profileID: profileID) { runtime, context in
                _ = try await runtime.enable(configuration: .init(), context: context)
            }
        })
        item.submenu = menu
        return item
    }

    func makeLiveFolderContextMenu(folder: BrowserOrganizationFolderItem,
                                   configuration: BrowserLiveFolderConfiguration) -> (menu: NSMenu, owner: AnyObject)? {
        guard let spaceID = session.snapshot?.activeSpaceID, let profileID = session.activeProfileID else { return nil }
        let menu = NSMenu()
        let provider = NSMenuItem(title: uiText("Pull Requests"), action: nil, keyEquivalent: "")
        let options = NSMenu()
        options.autoenablesItems = false
        if let date = liveFoldersRuntime?.lastFetched(folder.id) {
            let value = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
            let status = NSMenuItem(title: uiFormat("Last fetch: %@", value), action: nil, keyEquivalent: "")
            status.isEnabled = false
            options.addItem(status)
        }
        options.addItem(BrowserSplitMenuItem(title: uiText("Refresh")) { [weak self] in
            self?.performLiveFolderCommand(spaceID: spaceID, profileID: profileID) { runtime, context in
                try await runtime.refresh(folder.id, configuration: configuration, context: context)
            }
        })
        options.addItem(.separator())
        for (filter, title) in [(BrowserLiveFolderFilter.authored, uiText("Created by Me")), (.reviewRequested, uiText("Review Requests"))] {
            let item = BrowserSplitMenuItem(title: title) { [weak self] in
                self?.performLiveFolderCommand(spaceID: spaceID, profileID: profileID) { runtime, context in
                    // Re-read at execution time so an old menu cannot overwrite newer filters.
                    let document = await runtime.configuration(folder.id)
                    guard var current = document else { return }
                    if current.filters.contains(filter) { current.filters.remove(filter) }
                    else { current.filters.insert(filter) }
                    try await runtime.configure(folder.id, configuration: current, context: context)
                }
            }
            item.state = configuration.filters.contains(filter) ? .on : .off
            options.addItem(item)
        }
        provider.submenu = options
        menu.addItem(provider)
        if let commands = SidebarCommandHub.contextMenu(for: self, commands: [[.renameCurrentItem], [.sidebarDeleteFolderAndTabs]]) {
            for item in commands.menu.items { commands.menu.removeItem(item); menu.addItem(item) }
            menu.items.last?.title = uiText("Delete Live Folder")
            return (menu, commands.owner)
        }
        return nil
    }

    private func performLiveFolderCommand(spaceID: SpaceID, profileID: ProfileID,
        operation: @escaping @MainActor (BrowserLiveFoldersRuntime, BrowserContext) async throws -> Void) {
        guard acceptsCommands, let runtime = liveFoldersRuntime else { return }
        Task { [weak self] in
            guard let self, let context = await session.captureContextInCommandOrder().value,
                  context.spaceID == spaceID, context.profileID == profileID, acceptsCommands else { return }
            do { try await operation(runtime, context) }
            catch BrowserGitHubProviderError.signedOut {
                // Use the owning profile's ordinary web login; activation can be retried from
                // the same native menu after login. No credentials enter the shell.
                guard session.activeProfileID == context.profileID else { return }
                openTab(url: URL(string: "https://github.com/login")!)
            } catch { session.onError?(error) }
        }
    }
}
