import Foundation
@testable import ProvisionerKit
import Testing

private func feed(_ source: FakeFeedSource, _ sleep: RecordingSleep = RecordingSleep()) -> QueueFeed {
    QueueFeed(source: source, sleep: sleep.sleep)
}

/// Follows `feed` for the duration of `body`. Releasing the updates stream
/// cancels the feed, so a test that asserts on what the feed does after its
/// last consumed update must hold the stream until those assertions finish.
private func following<T>(_ feed: QueueFeed, _ body: (AsyncStream<QueueUpdate>) async -> T) async -> T {
    let updates = feed.updates()
    let result = await body(updates)
    withExtendedLifetime(updates) {}
    return result
}

/// Summarizes updates as "s<count>" for a snapshot and "e<id>" / "e<id>*" for an event (* = inSnapshot).
private func trace(_ updates: [QueueUpdate]) -> [String] {
    updates.map {
        switch $0 {
        case .snapshot(let entries): "s\(entries.count)"
        case .event(let e, let inSnapshot): "e\(e.id)" + (inSnapshot ? "*" : "")
        }
    }
}

/// A wrong feed leaves a test waiting on an update that never comes; the
/// time limit turns that into a failure.
@Suite(.timeLimit(.minutes(1)))
struct QueueFeedTests {
    @Test func firstConnectStreamsFromSnapshot() async {
        let source = FakeFeedSource(snapshots: [snapshot(10, "m1")], streams: [.frames([assigned(11)])])

        await following(feed(source)) { updates in
            let got = await updates.first(2)

            #expect(trace(got) == ["s1", "e11"])
            #expect(await source.afterIDs.first(1) == [10])
        }
    }

    @Test func reconnectReplaysGapTaggedInSnapshot() async {
        let source = FakeFeedSource(
            snapshots: [snapshot(10, "m1"), snapshot(14, "m1", "m2")],
            streams: [.frames([assigned(11)]), .frames([assigned(12), assigned(13), assigned(14), assigned(15)])])

        await following(feed(source)) { updates in
            let got = await updates.first(7)

            #expect(trace(got) == ["s1", "e11", "s2", "e12*", "e13*", "e14*", "e15"])
            #expect(await source.afterIDs.first(2) == [10, 11])
        }
    }

    @Test func resyncRestartsFromNewSnapshotWithoutWaiting() async {
        let source = FakeFeedSource(
            snapshots: [snapshot(50), snapshot(3, "m1")],
            streams: [.frames([resync(latest: 3)]), .frames([assigned(4)])])

        await following(QueueFeed(source: source, sleep: source.sleep)) { updates in
            let got = await updates.first(3)

            #expect(trace(got) == ["s0", "s1", "e4"])
            #expect(await source.log.first(4) == ["queue", "after 50", "queue", "after 3"])
        }
    }

    @Test func undecodableFrameIsSkippedAndIDAdvances() async {
        let future = ServerSentEvent(id: "11", event: "future-thing", data: #"{"id":11,"type":"future-thing"}"#)
        let source = FakeFeedSource(snapshots: [snapshot(10), snapshot(20)], streams: [.frames([future])])

        await following(feed(source)) { updates in
            let got = await updates.first(2)

            #expect(trace(got) == ["s0", "s0"])
            #expect(await source.afterIDs.first(2) == [10, 11])
        }
    }

    @Test func failureToOpenTheStreamBacksOff() async {
        let source = FakeFeedSource(
            snapshots: [snapshot(1), snapshot(1)], streams: [.refuse(FakeError(label: "busy")), .frames([assigned(2)])])

        await following(QueueFeed(source: source, sleep: source.sleep)) { updates in
            let got = await updates.first(3)

            #expect(trace(got) == ["s0", "s0", "e2"])
            #expect(await source.log.first(5) == ["queue", "after 1", "sleep 3.0 seconds", "queue", "after 1"])
        }
    }

    @Test func releasingTheUpdatesStopsTheFeed() async {
        let source = FakeFeedSource(snapshots: [snapshot(1)], streams: [])

        await following(feed(source)) { updates in
            _ = await updates.first(1)
        }

        #expect(await source.log.first(3) == ["queue", "after 1", "cancelled"])
    }

    @Test func unreachableServerRetriesWithCappedBackoff() async {
        let sleep = RecordingSleep()
        let down = Result<QueueSnapshot, FakeError>.failure(FakeError(label: "refused"))
        let source = FakeFeedSource(snapshots: [down, down, down, down, down, snapshot(1, "m1")], streams: [])

        await following(feed(source, sleep)) { updates in
            let got = await updates.first(1)

            #expect(trace(got) == ["s1"])
            #expect(await sleep.durations.first(5) == [.seconds(3), .seconds(6), .seconds(12), .seconds(24), .seconds(30)])
        }
    }

    @Test func retryFieldSetsBase() async {
        let sleep = RecordingSleep()
        let source = FakeFeedSource(
            snapshots: [snapshot(1)],
            streams: [.framesThenFail([ServerSentEvent(retry: 1000)], FakeError(label: "dropped"))])

        await following(feed(source, sleep)) { updates in
            _ = await updates.first(1)

            #expect(await sleep.durations.first(1) == [.seconds(1)])
        }
    }

    @Test func backoffResetsAfterLive() async {
        let sleep = RecordingSleep()
        let down = Result<QueueSnapshot, FakeError>.failure(FakeError(label: "refused"))
        let source = FakeFeedSource(snapshots: [down, down, snapshot(1)], streams: [.frames([assigned(2)])])

        await following(feed(source, sleep)) { updates in
            _ = await updates.first(2)

            #expect(await sleep.durations.first(3) == [.seconds(3), .seconds(6), .seconds(3)])
        }
    }

    /// `FeedState` with the error reduced to something comparable.
    private enum State: Equatable {
        case connecting, live
        case waiting(Duration, String)

        init(_ state: FeedState) {
            switch state {
            case .connecting: self = .connecting
            case .live: self = .live
            case .waiting(let delay, let error):
                self = .waiting(delay, (error as? FakeError)?.label ?? String(describing: type(of: error)))
            }
        }
    }

    @Test func statesReportWaitingWithTheErrorThenLive() async {
        let source = FakeFeedSource(
            snapshots: [.failure(FakeError(label: "refused")), snapshot(1)], streams: [.frames([])])
        let feed = feed(source)
        let states = feed.states

        await following(feed) { updates in
            _ = await updates.first(1)

            #expect(await states.first(5).map(State.init) == [
                .connecting, .waiting(.seconds(3), "refused"), .connecting, .live, .waiting(.seconds(3), "StreamClosed"),
            ])
        }
    }

    @Test func lateSubscriberGetsTheLatestState() async {
        let source = FakeFeedSource(snapshots: [snapshot(1)], streams: [.framesThenStayOpen([assigned(2)])])
        let feed = feed(source)

        await following(feed) { updates in
            _ = await updates.first(2)

            #expect(await feed.states.first(1).map(State.init) == [.live])
        }
    }
}
