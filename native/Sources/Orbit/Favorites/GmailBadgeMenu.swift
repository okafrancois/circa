import AppKit
import BrowserCore

@MainActor
final class GmailBadgeMenu: NSObject, NSMenuItemValidation {
    let item = NSMenuItem(title: uiText("Show Unread Badge"), action: nil, keyEquivalent: "")
    private let tab: TabID
    private let profile: ProfileID
    private weak var runtime: BrowserSettingsRuntime?
    private let permitted: () -> Bool
    private let changed: () -> Void
    private let failed: (Error) -> Void
    init(tab: TabID, profile: ProfileID, runtime: BrowserSettingsRuntime,
         permitted: @escaping () -> Bool, changed: @escaping () -> Void, failed: @escaping (Error) -> Void) {
        self.tab = tab; self.profile = profile; self.runtime = runtime
        self.permitted = permitted; self.changed = changed; self.failed = failed
        super.init()
        item.target = self; item.action = #selector(toggleBadge)
        item.state = runtime.document.profile(profile).hiddenGmailBadges.contains(tab) ? .off : .on
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        BrowserCommandKeyboard.permitsCurrentMenuEvent() && permitted() && runtime?.isUnavailable == false
    }
    @objc private func toggleBadge() {
        guard validateMenuItem(item), let runtime else { return }
        let hide = item.state == .on, tab = tab, profile = profile
        Task { [self] in
            guard permitted() else { return }
            do {
                try await runtime.updateProfile(profile) { settings in
                    if hide { settings.hiddenGmailBadges.insert(tab) }
                    else { settings.hiddenGmailBadges.remove(tab) }
                }
                changed()
            } catch { failed(error) }
        }
    }
}
