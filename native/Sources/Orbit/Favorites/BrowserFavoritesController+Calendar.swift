import AppKit
import BrowserCore
import BrowserEngine

extension BrowserFavoritesController {
    func installCalendar() {
        calendar.onChange = { [weak self] in self?.render() }
        calendarPreview.onPresentationChange = { [weak owner] in owner?.windowShell.hoverHoldDidChange() }
        calendarPreview.agenda = { [weak self] in self?.calendar.agendas[$0] }
        calendarPreview.refresh = { [weak self] in self?.calendar.refresh($0) }
        calendarPreview.permitted = { [weak self] _, captured, account in
            guard let self, self.calendarPermitted(captured, account), let owner = self.owner,
                  !owner.sidebar.isPresentationHidden, !owner.sidebar.isSwitchingSpace,
                  !owner.palette.isPresented, !owner.library.isPresented, owner.themeEditor == nil,
                  let profile = owner.session.organization?.profileID else { return false }
            return owner.settingsPreferences?.runtime.document.profile(profile).hiddenCalendarPreviews.contains(captured.id) != true
        }
        calendarPreview.menu = { [weak self] tab, account in self?.calendarMenu(tab, account: account, gear: true) }
        calendarPreview.open = { [weak self] tab, account, _ in
            guard let self, self.calendarPermitted(tab, account) else { return }
            self.owner?.session.openTab(url: account.pageURL.appendingPathComponent("eventedit"))
        }
    }
    func calendarPermitted(_ tab: BrowserOrganizationTabItem, _ account: BrowserCalendarWebAccount) -> Bool {
        guard let owner, owner.acceptsCommands, !owner.isPrivateWindow, !owner.session.isClosed,
              let current = owner.session.organization, current.favorites.contains(where: { $0.node == .tab(tab.id) }),
              let updated = current.tab(tab.id), BrowserCalendarWebAccount(url: updated.pinnedURL ?? updated.url) == account else { return false }
        return owner.settingsPreferences?.runtime.document.profile(current.profileID).disabledLiveCalendars.contains(tab.id) != true
    }
    func renderCalendarReminder(_ tabs: [BrowserOrganizationTabItem]) {
        guard let owner, let profile = owner.session.organization?.profileID else { return }
        let candidates = tabs.compactMap { tab -> (BrowserOrganizationTabItem, BrowserCalendarWebAccount, BrowserCalendarWebAgenda, BrowserCalendarWebEvent)? in
            guard let account = BrowserCalendarWebAccount(url: tab.pinnedURL ?? tab.url), calendarPermitted(tab, account),
                  let profile = owner.session.organization?.profileID,
                  owner.settingsPreferences?.runtime.document.profile(profile).hiddenCalendarMeetingLinks.contains(tab.id) != true,
                  let agenda = calendar.agendas[account], let event = agenda.nextMeeting(at: calendar.now()) else { return nil }
            return (tab, account, agenda, event)
        }
        guard let (tab, account, agenda, event) = candidates.min(by: { $0.3.start < $1.3.start }), calendar.online else {
            owner.sidebar.presentCalendarReminder(id: nil, title: nil, join: nil); return
        }
        owner.sidebar.presentCalendarReminder(id: "\(tab.id)-\(agenda.binding)-\(event.id)", title: event.title) { [weak self] in
            guard let self, self.calendar.online, self.calendarPermitted(tab, account),
                  self.owner?.session.organization?.profileID == profile,
                  self.owner?.settingsPreferences?.runtime.document.profile(profile).hiddenCalendarMeetingLinks.contains(tab.id) != true,
                  let current = self.calendar.agendas[account], current.binding == agenda.binding,
                  current.nextMeeting(at: self.calendar.now()) == event,
                  let url = event.joinURL, BrowserCalendarBootstrap.meetingURL(url.absoluteString) == url else { return false }
            self.owner?.session.openTab(url: url)
            return true
        }
    }
    func calendarCountdown(_ tab: BrowserOrganizationTabItem) -> String? {
        guard let account = BrowserCalendarWebAccount(url: tab.pinnedURL ?? tab.url), calendarPermitted(tab, account),
              let owner, let profile = owner.session.organization?.profileID,
              owner.settingsPreferences?.runtime.document.profile(profile).hiddenCalendarCountdowns.contains(tab.id) != true,
              let agenda = calendar.agendas[account], agenda.isFresh(at: calendar.now()) else { return nil }
        let now = calendar.now()
        guard let next = agenda.events.first(where: { $0.start >= now.addingTimeInterval(-300) }) else { return nil }
        let minutes = Int(ceil(abs(next.start.timeIntervalSince(now)) / 60))
        guard minutes > 0 else { return nil }
        return String(format: next.start >= now ? uiText("in %dm") : uiText("%dm ago"), minutes)
    }
    func calendarMenu(_ tab: BrowserOrganizationTabItem, account: BrowserCalendarWebAccount, gear: Bool) -> NSMenu? {
        guard let owner, !owner.isPrivateWindow, let profile = owner.session.organization?.profileID else { return nil }
        let menu = NSMenu(); menu.autoenablesItems = false
        let age = calendar.agendas[account].map { String(format: uiText("Last fetch: %dm ago"), max(0, Int(calendar.now().timeIntervalSince($0.fetchedAt) / 60))) } ?? uiText("Last fetch: unavailable")
        let last = NSMenuItem(title: age, action: nil, keyEquivalent: ""); last.isEnabled = false; menu.addItem(last)
        let enabled = calendarPermitted(tab, account)
        func action(_ title: String, _ block: @escaping () -> Void) -> NSMenuItem {
            let item = CalendarActionMenuItem(title: title) { [weak self] in
                guard let self, self.owner?.session.organization?.profileID == profile,
                      self.owner?.session.organization?.tab(tab.id)?.pinnedURL == tab.pinnedURL,
                      self.owner?.isPrivateWindow == false else { return }
                block()
            }
            menu.addItem(item); return item
        }
        action(uiText("Refresh")) { [weak self] in
            self?.calendarPreview.dismiss(); self?.calendar.refresh(account)
        }.isEnabled = enabled
        let settings = owner.settingsPreferences?.runtime.document.profile(profile)
        @discardableResult func preference(_ title: String, _ choice: Int, checked: Bool) -> NSMenuItem {
            let item = action(title) { [weak self] in
                guard let self, let runtime = self.owner?.settingsPreferences?.runtime else { return }
                Task { @MainActor [weak self] in
                    do {
                        try await runtime.updateProfile(profile) { settings in
                            let key: WritableKeyPath<BrowserProfileSettings, Set<TabID>> = choice == 0 ? \.hiddenCalendarPreviews
                                : choice == 1 ? \.hiddenCalendarCountdowns : choice == 3 ? \.hiddenCalendarMeetingLinks : \.disabledLiveCalendars
                            if settings[keyPath: key].contains(tab.id) { settings[keyPath: key].remove(tab.id) }
                            else { settings[keyPath: key].insert(tab.id) }
                        }
                        self?.calendarPreview.dismiss(); self?.render()
                    } catch { /* Leave the saved preference unchanged on failure. */ }
                }
            }
            item.state = checked ? .on : .off
            return item
        }
        menu.addItem(.separator())
        if !gear {
            preference(uiText("Show Hover Preview"), 0, checked: settings?.hiddenCalendarPreviews.contains(tab.id) != true)
            preference(uiText("Show Time to Next Meeting"), 1, checked: settings?.hiddenCalendarCountdowns.contains(tab.id) != true)
            let parent = NSMenuItem(title: uiText("Show Next Meeting Link"), action: nil, keyEquivalent: "")
            let submenu = NSMenu(); submenu.autoenablesItems = false
            let hidden = settings?.hiddenCalendarMeetingLinks.contains(tab.id) == true
            for (title, checked) in [(uiText("3 minutes before"), !hidden), (uiText("Never"), hidden)] {
                let item = preference(title, 3, checked: checked)
                item.isEnabled = !checked
                menu.removeItem(item); submenu.addItem(item)
            }
            parent.submenu = submenu; menu.addItem(parent)
        }
        preference(enabled ? uiText("Disable Live Calendar") : uiText("Enable Live Calendar"), 2, checked: false)
        return menu
    }
}

@MainActor
private final class CalendarActionMenuItem: NSMenuItem {
    private let invoke: () -> Void
    init(title: String, invoke: @escaping () -> Void) {
        self.invoke = invoke; super.init(title: title, action: #selector(run), keyEquivalent: ""); target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { invoke() }
}
