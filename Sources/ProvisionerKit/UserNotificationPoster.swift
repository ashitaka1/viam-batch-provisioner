import os
import UserNotifications

/// Delivers through `UNUserNotificationCenter`, which needs a bundled app.
public struct UserNotificationPoster: NotificationPoster {
    private static let log = Logger(subsystem: "ProvisionerKit", category: "UserNotificationPoster")

    public init() {}

    /// Asks the operator to allow alerts and sounds, and shows notifications
    /// while the app is frontmost too, which macOS otherwise delivers silently
    /// to Notification Center. Call once at launch, before the first post.
    public static func prepare() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = ForegroundPresenter.shared
        do {
            if try await !center.requestAuthorization(options: [.alert, .sound]) {
                log.notice("the operator declined notifications")
            }
        } catch {
            log.error("requesting notification authorization failed: \(error, privacy: .public)")
        }
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

/// The notification center holds its delegate weakly; `shared` keeps this one alive.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = ForegroundPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
