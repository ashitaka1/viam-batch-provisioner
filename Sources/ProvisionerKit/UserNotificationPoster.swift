import UserNotifications

/// Delivers through `UNUserNotificationCenter`, which needs a bundled app.
public struct UserNotificationPoster: NotificationPoster {
    public init() {}

    /// Asks the operator to allow alerts and sounds. True when allowed.
    public static func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    public func post(_ notification: InstallNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle ?? ""
        content.body = notification.body
        content.sound = .default
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil))
    }
}
