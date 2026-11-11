import os
import ProvisionerKit

/// Records what it was asked to post; fails the posts whose title is in `failing`.
final class RecordingPoster: NotificationPoster {
    struct Refused: Error {}

    private let posted = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let failing: Set<String>

    init(failing: Set<String> = []) {
        self.failing = failing
    }

    var titles: [String] { posted.withLock { $0 } }

    func post(_ notification: InstallNotification) async throws {
        posted.withLock { $0.append(notification.title) }
        if failing.contains(notification.title) { throw Refused() }
    }
}
