import AppKit
import BrowserCore

/// Captures the Space before menu tracking; changing focus never substitutes another target.
@MainActor
final class BrowserSpaceProfileMenu: NSMenu, NSMenuItemValidation {
    let space: BrowserSpace
    private let profiles: [BrowserProfile]
    private let isCurrent: () -> Bool
    private let move: (ProfileID) async throws -> Void
    private let create: (String) async throws -> ProfileID
    private let reportError: (Error) -> Void
    var presentAlert: (NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    private(set) var pending: Task<Void, Never>?
    private var choosing = false

    init(space: BrowserSpace, profiles: [BrowserProfile], isCurrent: @escaping () -> Bool,
         move: @escaping (ProfileID) async throws -> Void, create: @escaping (String) async throws -> ProfileID,
         reportError: @escaping (Error) -> Void,
         presentAlert: @escaping (NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Void) {
        self.space = space
        self.profiles = profiles
        self.isCurrent = isCurrent
        self.move = move
        self.create = create
        self.reportError = reportError
        self.presentAlert = presentAlert
        super.init(title: uiText("Set Profile"))
        for (index, profile) in profiles.enumerated() {
            let item = addItem(withTitle: profile.name, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = profile.id == space.profileID ? .on : .off
        }
        addItem(.separator())
        let new = addItem(withTitle: uiText("New Profile…"), action: #selector(newProfile(_:)), keyEquivalent: "")
        new.target = self
        new.tag = profiles.count
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        !choosing && pending == nil && isCurrent()
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), profiles.indices.contains(sender.tag) else { return }
        let profile = profiles[sender.tag]
        guard profile.id != space.profileID else { return }
        choosing = true
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = uiFormat("Switch to your %@ Profile?", profile.name)
        alert.informativeText = uiFormat("Each Profile has different browser data, so your %@ Space might look a little different!\n\nFor example, you might get logged out of some websites, see different Favorites up top, or need to re-install an extension.\n\nThis action cannot be undone.", space.name)
        alert.addButton(withTitle: uiText("Switch it up"))
        alert.addButton(withTitle: uiText("Cancel"))
        presentAlert(alert) { [self] response in
            guard choosing else { return }
            choosing = false
            guard response == .alertFirstButtonReturn, isCurrent() else { return }
            pending = Task { [self] in
                do { try await move(profile.id) }
                catch { reportError(error) }
            }
        }
    }

    @objc private func newProfile(_ sender: NSMenuItem) {
        guard validateMenuItem(sender) else { return }
        choosing = true
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = uiText("Create a new Profile")
        alert.informativeText = uiText("Profiles make your Spaces truly separate — with their own history, saved passwords, extensions, and other browsing data. No more flipping between work and personal accounts!\n\nWhat do you want to call this Profile?")
        alert.addButton(withTitle: uiText("Create Profile"))
        alert.addButton(withTitle: uiText("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.setAccessibilityLabel(uiText("Profile Name"))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        presentAlert(alert) { [self] response in
            guard choosing else { return }
            choosing = false
            guard response == .alertFirstButtonReturn, isCurrent() else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            pending = Task { [self] in
                do {
                    guard !name.isEmpty, name.rangeOfCharacter(from: .controlCharacters) == nil,
                          !profiles.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                        throw BrowserStoreError.invalidSpaceName
                    }
                    let profile = try await create(name)
                    try await move(profile)
                } catch { reportError(error) }
            }
        }
    }
}

/// Refreshes destinations when the menu bar opens, after window and catalog changes.
@MainActor
final class BrowserDynamicProfileMenu: NSMenu, NSMenuDelegate {
    private let provider: () -> NSMenu?
    private var retainedMenu: NSMenu?
    init(provider: @escaping () -> NSMenu?) {
        self.provider = provider
        super.init(title: uiText("Change Profile"))
        delegate = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        retainedMenu = provider()
        for item in retainedMenu?.items ?? [] {
            retainedMenu?.removeItem(item)
            addItem(item)
        }
    }
}

extension BrowserWindowController {
    func makeSpaceProfileMenu(for id: SpaceID) -> BrowserSpaceProfileMenu? {
        guard acceptsCommands, !isPrivateWindow, !session.isClosed, !session.hasPendingCommands,
              let catalog = session.catalog, let space = catalog.spaces.first(where: { $0.id == id }),
              onMoveSpaceToProfile != nil, onCreateSpaceProfile != nil else { return nil }
        return BrowserSpaceProfileMenu(space: space, profiles: catalog.profiles, isCurrent: { [weak self] in
            guard let self else { return false }
            return acceptsCommands && !session.isClosed && !session.hasPendingCommands
                && session.catalog == catalog
        }, move: { [weak self] profile in
            guard let self, acceptsCommands, !session.isClosed else { return }
            try await onMoveSpaceToProfile?(id, profile, space.profileID)
        }, create: { [weak self] name in
            guard let self, acceptsCommands, !session.isClosed, let create = onCreateSpaceProfile else { throw CancellationError() }
            return try await create(name)
        }, reportError: { [weak self] in self?.session.onError?($0) }, presentAlert: { [weak self] alert, completion in
            guard let window = self?.window else { completion(.abort); return }
            alert.beginSheetModal(for: window, completionHandler: completion)
        })
    }

    func presentSpaceProfileMenu() {
        guard let id = session.snapshot?.activeSpaceID, let menu = makeSpaceProfileMenu(for: id) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 16, y: sidebar.bounds.maxY - 80), in: sidebar)
    }
}
