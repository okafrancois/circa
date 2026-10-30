import UserNotifications

/// Uses the main application's identity without replacing Chromium's delivery/click delegate.
@MainActor
final class BrowserNotificationAuthorization {
    static let shared = BrowserNotificationAuthorization()
    var status: () async -> UNAuthorizationStatus
    var request: () async throws -> Bool
    private var pending: Task<Bool, Never>?

    init(status: @escaping () async -> UNAuthorizationStatus = {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }, request: @escaping () async throws -> Bool = {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }) {
        self.status = status
        self.request = request
    }

    func authorize() async -> Bool {
        if let pending { return await pending.value }
        let task = Task { [status, request] in
            var current = await status()
            if current == .notDetermined {
                do { _ = try await request() }
                catch { return false }
                current = await status()
            }
            return current == .authorized || current == .provisional
        }
        pending = task
        let authorized = await task.value
        pending = nil
        return authorized
    }
}
