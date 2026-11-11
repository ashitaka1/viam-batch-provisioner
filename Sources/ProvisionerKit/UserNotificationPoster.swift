import os
import UserNotifications

/// Delivers through `UNUserNotificationCenter`, which needs a bundled app.
public struct UserNotificationPoster: NotificationPoster {
    private static let log = Logger(subsystem: "ProvisionerKit", category: "UserNotificationPoster")

    public init() {}

    /// The operator's answer to the authorization request; started by `prepare()`
    /// or the first post, and awaited by every post.
    private static let authorization = Task<Bool, Never> {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            if !allowed { log.notice("the operator declined notifications") }
            return allowed
        } catch {
            log.error("requesting notification authorization failed: \(error, privacy: .public)")
            return false
        }
    }

    /// Asks the operator to allow alerts and sounds, and shows notifications
    /// while the app is frontmost too, which macOS otherwise delivers silently
    /// to Notification Center. Call while the app launches.
    public static func prepare() {
        UNUserNotificationCenter.current().delegate = ForegroundPresenter.shared
        _ = authorization
    }

    public func post(_ notification: InstallNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle ?? ""
        content.body = notification.body
        content.sound = .default
        _ = await Self.authorization.value
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
