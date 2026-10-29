import AppKit

/// Native 13 pt menu type, 24 pt rows and a 225 pt minimum content width.
@MainActor
final class BrowserTranslationOptionsMenu: NSMenu {
    private let choose: (String) -> Void
    private let toggleSite: () -> Void
    private let settings: () -> Void

    init(targets: [String], suppressed: Bool, choose: @escaping (String) -> Void,
         toggleSite: @escaping () -> Void, settings: @escaping () -> Void) {
        self.choose = choose; self.toggleSite = toggleSite; self.settings = settings
        super.init(title: "")
        autoenablesItems = false
        font = .systemFont(ofSize: 13)
        minimumWidth = 225
        let languages = NSMenu()
        languages.autoenablesItems = false; languages.font = font
        for target in targets {
            let item = NSMenuItem(title: BrowserPageTranslation.languageName(target), action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = target
            languages.addItem(item)
        }
        let language = NSMenuItem(title: uiText("Choose Another Language"), action: nil, keyEquivalent: "")
        language.submenu = languages
        language.isEnabled = !targets.isEmpty
        addItem(language)
        let site = NSMenuItem(title: uiText("Never Translate This Site"), action: #selector(toggle(_:)), keyEquivalent: "")
        site.target = self; site.state = suppressed ? .on : .off
        addItem(site)
        addItem(.separator())
        let settings = NSMenuItem(title: uiText("Language Settings"), action: #selector(openSettings(_:)), keyEquivalent: "")
        settings.target = self
        addItem(settings)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func selectLanguage(_ item: NSMenuItem) {
        if let target = item.representedObject as? String { choose(target) }
    }
    @objc private func toggle(_ item: NSMenuItem) { toggleSite() }
    @objc private func openSettings(_ item: NSMenuItem) { settings() }
}
