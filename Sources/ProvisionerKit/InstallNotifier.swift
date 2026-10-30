import os

public protocol NotificationPoster: Sendable {
    func post(_ notification: InstallNotification) async throws
}

/// Posts a notification for each install that completes or fails. Snapshots
/// post nothing; events replayed after a reconnect post, since the operator
/// didn't see them happen.
public struct InstallNotifier: Sendable {
    private static let log = Logger(subsystem: "ProvisionerKit", category: "InstallNotifier")

    private let poster: any NotificationPoster

    public init(poster: any NotificationPoster) {
        self.poster = poster
    }

    /// Runs until `updates` ends.
    public func run(_ updates: AsyncStream<QueueUpdate>) async {
        for await update in updates { await handle(update) }
    }

    public func handle(_ update: QueueUpdate) async {
        guard case .event(let event, _) = update, let notification = InstallNotification(event) else { return }
        do {
            try await poster.post(notification)
        } catch {
            Self.log.error("posting \(notification.identifier, privacy: .public) failed: \(error, privacy: .public)")
        }
    }
}
