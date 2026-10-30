import Foundation
import os
import ProvisionerKit
import Testing

/// Records what it was asked to post; fails the posts whose title is in `failing`.
private final class RecordingPoster: NotificationPoster {
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

private func event(_ id: Int, _ name: String, _ kind: MachineEvent.Kind) -> MachineEvent {
    MachineEvent(id: id, timestamp: Date(timeIntervalSince1970: 0), name: name, mac: nil, kind: kind)
}

private let failed = MachineEvent.Kind.installFailed(stage: "tooling", reason: "curl failed", source: .installer)

struct InstallNotifierTests {
    @Test func postsCompleteAndFailedOnly() async {
        let poster = RecordingPoster()
        let notifier = InstallNotifier(poster: poster)

        for update: QueueUpdate in [
            .event(event(1, "m1", .assigned), inSnapshot: false),
            .event(event(2, "m1", .installStarted), inSnapshot: false),
            .event(event(3, "m1", .installProgress(stage: "tooling")), inSnapshot: false),
            .event(event(4, "m1", failed), inSnapshot: false),
            .event(event(5, "m2", .installComplete(duration: 60)), inSnapshot: false),
        ] {
            await notifier.handle(update)
        }

        #expect(poster.titles == ["m1 failed", "m2 installed"])
    }

    @Test func snapshotsDoNotPost() async {
        let poster = RecordingPoster()

        await InstallNotifier(poster: poster).handle(
            .snapshot([QueueEntry(name: "m1", status: .failed, failureReason: "curl failed", hasCredentials: true)]))

        #expect(poster.titles == [])
    }

    /// Events replayed after a reconnect happened while the client wasn't watching.
    @Test func gapEventsInSnapshotPost() async {
        let poster = RecordingPoster()

        await InstallNotifier(poster: poster).handle(.event(event(7, "m1", .installComplete(duration: 1)), inSnapshot: true))

        #expect(poster.titles == ["m1 installed"])
    }

    @Test func posterFailureDoesNotStopLaterPosts() async {
        let poster = RecordingPoster(failing: ["m1 failed"])
        let (updates, continuation) = AsyncStream.makeStream(of: QueueUpdate.self)
        continuation.yield(.event(event(1, "m1", failed), inSnapshot: false))
        continuation.yield(.event(event(2, "m2", .installComplete(duration: 1)), inSnapshot: false))
        continuation.finish()

        await InstallNotifier(poster: poster).run(updates)

        #expect(poster.titles == ["m1 failed", "m2 installed"])
    }
}
