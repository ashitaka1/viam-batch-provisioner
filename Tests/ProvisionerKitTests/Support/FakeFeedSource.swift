import Foundation
import os
@testable import ProvisionerKit

struct FakeError: Error, Equatable {
    var label: String
}

/// A scripted server. Each `queue()` call takes the next snapshot or error and
/// each `eventFrames(after:)` call the next frame script. Past the end of a
/// script it suspends until cancelled, so the feed under test goes quiet.
final class FakeFeedSource: QueueFeedSource {
    enum Stream {
        /// Yields the frames, then ends the stream.
        case frames([ServerSentEvent])
        /// Yields the frames, then fails with the error.
        case framesThenFail([ServerSentEvent], FakeError)
        /// Fails to open.
        case refuse(FakeError)
    }

    private struct Script {
        var snapshots: [Result<QueueSnapshot, FakeError>]
        var streams: [Stream]
    }

    private let script: OSAllocatedUnfairLock<Script>
    private let afterContinuation: AsyncStream<Int>.Continuation
    /// Every `after` id the feed opened `/events` with, in order.
    let afterIDs: AsyncStream<Int>

    init(snapshots: [Result<QueueSnapshot, FakeError>], streams: [Stream]) {
        script = .init(initialState: Script(snapshots: snapshots, streams: streams))
        (afterIDs, afterContinuation) = AsyncStream.makeStream()
    }

    func queue() async throws -> QueueSnapshot {
        guard let next = script.withLock({ $0.snapshots.isEmpty ? nil : $0.snapshots.removeFirst() }) else {
            try await suspendUntilCancelled()
        }
        return try next.get()
    }

    func eventFrames(after id: Int) async throws -> AsyncThrowingStream<ServerSentEvent, any Error> {
        afterContinuation.yield(id)
        guard let next = script.withLock({ $0.streams.isEmpty ? nil : $0.streams.removeFirst() }) else {
            try await suspendUntilCancelled()
        }
        switch next {
        case .refuse(let error):
            throw error
        case .frames(let frames):
            return AsyncThrowingStream { c in
                frames.forEach { c.yield($0) }
                c.finish()
            }
        case .framesThenFail(let frames, let error):
            return AsyncThrowingStream { c in
                frames.forEach { c.yield($0) }
                c.finish(throwing: error)
            }
        }
    }

    private func suspendUntilCancelled() async throws -> Never {
        let (never, keep) = AsyncStream<Never>.makeStream()
        for await _ in never {}
        keep.finish()
        throw CancellationError()
    }
}

/// Records each backoff and returns at once.
final class RecordingSleep: Sendable {
    private let continuation: AsyncStream<Duration>.Continuation
    let durations: AsyncStream<Duration>

    init() {
        (durations, continuation) = AsyncStream.makeStream()
    }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [continuation] in continuation.yield($0) }
    }
}

func snapshot(_ lastEventID: Int, _ names: String...) -> Result<QueueSnapshot, FakeError> {
    .success(QueueSnapshot(entries: names.map { QueueEntry(name: $0, status: .queued, hasCredentials: false) },
                           lastEventID: lastEventID))
}

func assigned(_ id: Int, name: String = "m1") -> ServerSentEvent {
    ServerSentEvent(id: String(id), event: "machine-assigned", data: """
        {"id":\(id),"type":"machine-assigned","timestamp":"2026-10-04T04:08:29+00:00","name":"\(name)","mac":"aa:bb:cc:dd:ee:ff"}
        """)
}

func resync(latest: Int) -> ServerSentEvent {
    ServerSentEvent(event: "resync", data: #"{"type":"resync","latest_id":\#(latest)}"#)
}

extension AsyncStream {
    /// The next `count` elements.
    func first(_ count: Int) async -> [Element] {
        var out: [Element] = []
        for await element in self {
            out.append(element)
            if out.count == count { break }
        }
        return out
    }
}
