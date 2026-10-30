public import Foundation
public import OpenAPIRuntime
import os
internal import ProvisionerAPI

/// Where a `QueueFeed` reads the queue and its events.
public protocol QueueFeedSource: Sendable {
    func queue() async throws -> QueueSnapshot
    func eventFrames(after id: Int) async throws -> AsyncThrowingStream<ServerSentEvent, any Error>
}

extension ProvisionerClient: QueueFeedSource {}

public enum QueueUpdate: Sendable, Equatable {
    /// The whole queue. Replaces whatever the consumer holds.
    case snapshot([QueueEntry])
    /// `inSnapshot` is true when the last snapshot already reflects the event:
    /// a queue view skips it; notifications still act on it.
    case event(MachineEvent, inSnapshot: Bool)
}

public enum FeedState: Sendable {
    case connecting
    case live
    case waiting(retryIn: Duration, lastError: any Error)
}

/// Follows a server's queue: snapshot, then the event stream from the
/// snapshot's id, reconnecting with backoff and resuming from the last event
/// seen. See the API's snapshot-then-stream rule in openapi/provisioner.yaml.
public final class QueueFeed: Sendable {
    /// The server closed the event stream.
    public struct StreamClosed: Error {}

    private struct Subscribers {
        var latest: FeedState?
        var continuations: [UUID: AsyncStream<FeedState>.Continuation] = [:]
    }

    private static let defaultRetry = Duration.seconds(3)
    private static let log = Logger(subsystem: "ProvisionerKit", category: "QueueFeed")

    private let source: any QueueFeedSource
    private let maxBackoff: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let subscribers = OSAllocatedUnfairLock(initialState: Subscribers())

    public init(
        source: any QueueFeedSource,
        maxBackoff: Duration = .seconds(30),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.source = source
        self.maxBackoff = maxBackoff
        self.sleep = sleep
    }

    /// Connection state changes. A new subscriber first gets the latest state, if any.
    public var states: AsyncStream<FeedState> {
        let (stream, continuation) = AsyncStream.makeStream(of: FeedState.self)
        let id = UUID()
        subscribers.withLock {
            if let latest = $0.latest { continuation.yield(latest) }
            $0.continuations[id] = continuation
        }
        continuation.onTermination = { [subscribers] _ in
            subscribers.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    /// Starts following the queue. Runs until the consumer stops iterating.
    public func updates() -> AsyncStream<QueueUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: QueueUpdate.self)
        let task = Task {
            await run(continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func run(_ out: AsyncStream<QueueUpdate>.Continuation) async {
        var remembered: Int?
        var base = Self.defaultRetry
        var backoff = base

        while !Task.isCancelled {
            publish(.connecting)
            let failure: any Error
            do {
                let snapshot = try await source.queue()
                out.yield(.snapshot(snapshot.entries))
                let frames = try await source.eventFrames(after: remembered ?? snapshot.lastEventID)
                publish(.live)
                backoff = base

                var resynced = false
                frameLoop: for try await frame in frames {
                    if let retry = frame.retry {
                        base = .milliseconds(retry)
                        backoff = base
                    }
                    guard let data = frame.data else { continue }
                    switch Self.decode(data) {
                    case .machine(let event):
                        out.yield(.event(event, inSnapshot: event.id <= snapshot.lastEventID))
                        remembered = event.id
                    case .resync:
                        remembered = nil
                        resynced = true
                        break frameLoop
                    case nil:
                        Self.log.error("skipping undecodable event \(frame.id ?? "-", privacy: .public): \(data, privacy: .public)")
                        if let id = frame.id.flatMap(Int.init) { remembered = id }
                    }
                }
                if resynced { continue }
                failure = StreamClosed()
            } catch {
                failure = error
            }
            if Task.isCancelled { return }

            publish(.waiting(retryIn: backoff, lastError: failure))
            do {
                try await sleep(backoff)
            } catch {
                return
            }
            backoff = min(backoff * 2, maxBackoff)
        }
    }

    private static func decode(_ data: String) -> WireEvent? {
        guard let wire = try? WireCoding.decoder.decode(Components.Schemas.MachineEvent.self, from: Data(data.utf8))
        else { return nil }
        return WireEvent(wire)
    }

    private func publish(_ state: FeedState) {
        subscribers.withLock {
            $0.latest = state
            for continuation in $0.continuations.values { continuation.yield(state) }
        }
    }
}
