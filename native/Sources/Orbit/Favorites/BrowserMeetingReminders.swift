import AppKit
import BrowserCore
@preconcurrency import UserNotifications

/// App-wide, memory-only deduplication across Favorites, refreshes and windows.
@MainActor
final class BrowserMeetingReminders {
    struct Reminder {
        let key: String
        let title: String
        let start: Date
        let sound: Bool
        let valid: () -> Bool
        let inactive: () -> Bool
        let activate: () -> Void
        let join: () -> Bool
    }
    static let shared = BrowserMeetingReminders()
    var authorize: () async -> Bool = { await BrowserNotificationAuthorization.shared.authorize() }
    var playSound: () -> Void = { NSSound(named: .init("Glass"))?.play() }
    var post: (String, String, Int, Bool) async -> Void = { await BrowserMeetingNotificationDelivery.shared.post($0, title: $1, minutes: $2, sound: $3) }
    var remove: (String) -> Void = { BrowserMeetingNotificationDelivery.shared.remove($0) }
    private var current: [UUID: Reminder] = [:]
    private var seen: [String: Date] = [:]
    private var identifiers: [String: String] = [:]

    func update(owner: UUID, reminder: Reminder?, now: Date) {
        current[owner] = reminder
        for (key, identifier) in identifiers where !current.values.contains(where: { $0.key == key && $0.valid() }) {
            remove(identifier); identifiers[key] = nil
        }
        seen = seen.filter { $0.value >= now }
        guard let reminder, reminder.valid(), seen[reminder.key] == nil else { return }
        seen[reminder.key] = reminder.start
        let background = reminder.inactive()
        if reminder.sound && !background { playSound() }
        let key = reminder.key, firedAt = ProcessInfo.processInfo.systemUptime
        Task { [weak self] in
            guard let self, await self.authorize(), background, let live = self.live(key), live.inactive() else { return }
            let identifier = "orbit-meeting-" + UUID().uuidString
            self.identifiers[key] = identifier
            let minutes = max(1, Int(ceil((live.start.timeIntervalSince(now) - (ProcessInfo.processInfo.systemUptime - firedAt)) / 60)))
            await self.post(identifier, live.title, minutes, live.sound)
            // Permission/delivery may have yielded while the source was removed or disabled.
            if self.live(key) == nil { self.remove(identifier); self.identifiers[key] = nil }
        }
    }
    private func live(_ key: String) -> Reminder? { current.values.first { $0.key == key && $0.valid() } }
    func shouldPresent(_ identifier: String) -> Bool {
        guard let key = identifiers.first(where: { $0.value == identifier })?.key, let reminder = live(key) else { return false }
        return reminder.inactive()
    }
    @discardableResult func respond(_ identifier: String, join: Bool) -> Bool {
        guard let key = identifiers.first(where: { $0.value == identifier })?.key, let reminder = live(key) else { return false }
        reminder.activate()
        let opened = !join || reminder.join()
        remove(identifier); identifiers[key] = nil
        return opened
    }
}

/// Forwards website notifications to Chromium's existing delegate.
@MainActor
final class BrowserMeetingNotificationDelivery: NSObject, UNUserNotificationCenterDelegate {
    static let shared = BrowserMeetingNotificationDelivery()
    private let category = "orbit.calendar.meeting"
    nonisolated(unsafe) private weak var forwarded: (any UNUserNotificationCenterDelegate)?
    func post(_ identifier: String, title: String, minutes: Int, sound: Bool) async {
        let center = UNUserNotificationCenter.current()
        if center.delegate !== self { forwarded = center.delegate; center.delegate = self }
        var categories = await center.notificationCategories()
        categories = Set(categories.filter { $0.identifier != category })
        categories.insert(UNNotificationCategory(identifier: category, actions: [
            UNNotificationAction(identifier: "join", title: uiText("Join"), options: [.foreground])
        ], intentIdentifiers: []))
        center.setNotificationCategories(categories)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(format: uiText("Starts in %d min"), minutes)
        content.categoryIdentifier = category
        guard BrowserMeetingReminders.shared.shouldPresent(identifier) else { return }
        // Background audio belongs to the system so Focus and notification settings apply.
        content.sound = sound ? .default : nil
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
    func remove(_ identifier: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        if notification.request.content.categoryIdentifier == "orbit.calendar.meeting" {
            let identifier = notification.request.identifier
            Task { @MainActor in completionHandler(BrowserMeetingReminders.shared.shouldPresent(identifier) ? [.banner, .list, .sound] : []) }
        } else if let forwarded, forwarded.responds(to: #selector(userNotificationCenter(_:willPresent:withCompletionHandler:))) {
            forwarded.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
        } else { completionHandler([]) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        if response.notification.request.content.categoryIdentifier == "orbit.calendar.meeting" {
            let identifier = response.notification.request.identifier, action = response.actionIdentifier
            Task { @MainActor in
                if action == "join" || action == UNNotificationDefaultActionIdentifier {
                    BrowserMeetingReminders.shared.respond(identifier, join: action == "join")
                }
                completionHandler()
            }
        } else if let forwarded, forwarded.responds(to: #selector(userNotificationCenter(_:didReceive:withCompletionHandler:))) {
            forwarded.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
        } else { completionHandler() }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        forwarded?.userNotificationCenter?(center, openSettingsFor: notification)
    }
}
