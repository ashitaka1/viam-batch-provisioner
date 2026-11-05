import Foundation
import OpenAPIRuntime
import ProvisionerAPI
import ServiceLifecycle
import NIOConcurrencyHelpers

/// Caps the number of open event streams.
actor StreamLimiter {
    private let limit: Int
    private var open = 0

    init(limit: Int = 64) { self.limit = limit }

    func acquire() -> Bool {
        guard open < limit else { return false }
        open += 1
        return true
    }

    func release() { open -= 1 }
}

extension APIHandler {
    func streamEvents(_ input: Operations.StreamEvents.Input) async throws -> Operations.StreamEvents.Output {
        let cursor = input.headers.lastEventID ?? input.query.lastEventId
        if let cursor, cursor < 0 {
            return .badRequest(.init(body: .json(errorPayload(.invalidRequest, "Last-Event-ID must be at least 0"))))
        }
        guard await streams.acquire() else {
            return .serviceUnavailable(.init(body: .json(errorPayload(.tooManyStreams, "too many open event streams"))))
        }
        let subscription = await provisioner.subscribe(after: cursor)
        let streams = streams
        let body = sseBody(subscription, keepalive: streamOptions.keepalive) {
            Task { await streams.release() }
        }
        return .ok(.init(body: .textEventStream(body)))
    }
}

/// The SSE byte stream: `retry`, the backlog or a resync, then live events with a
/// keepalive comment after each `keepalive` of silence. The stream ends when
/// the server shuts down gracefully. Ending it, by shutdown, disconnect or
/// cancellation, cancels the subscription and calls `release`.
func sseBody(_ subscription: EventSubscription, keepalive: Duration,
             release: @escaping @Sendable () -> Void) -> HTTPBody {
    let (stream, out) = AsyncStream.makeStream(of: ArraySlice<UInt8>.self)
    let quiet = NIOLockedValueBox(true)
    out.yield(frame("retry: 3000\n\n"))
    switch subscription.backlog {
    case .events(let events):
        for event in events { out.yield(frame(sseFrame(event))) }
    case .resync(let latest):
        out.yield(frame("event: resync\ndata: {\"latest_id\":\(latest),\"type\":\"resync\"}\n\n"))
    }
    let live = Task {
        for await event in subscription.live {
            quiet.withLockedValue { $0 = false }
            out.yield(frame(sseFrame(event)))
        }
        out.finish()
    }
    let ticks = Task {
        while !Task.isCancelled {
            try await Task.sleep(for: keepalive)
            let silent = quiet.withLockedValue { was in
                defer { was = true }
                return was
            }
            if silent { out.yield(frame(": keepalive\n\n")) }
        }
    }
    out.onTermination = { _ in
        live.cancel()
        ticks.cancel()
        subscription.cancel()
        release()
    }
    return HTTPBody(SSEFrames(stream: stream, finish: { out.finish() }), length: .unknown, iterationBehavior: .single)
}

/// The frame stream, finished when graceful shutdown begins so the response
/// ends and the stream's termination handler releases its slot.
private struct SSEFrames: AsyncSequence, Sendable {
    typealias Element = ArraySlice<UInt8>

    let stream: AsyncStream<Element>
    let finish: @Sendable () -> Void

    func makeAsyncIterator() -> Iterator {
        Iterator(base: stream.makeAsyncIterator(), finish: finish)
    }

    struct Iterator: AsyncIteratorProtocol {
        var base: AsyncStream<Element>.Iterator
        let finish: @Sendable () -> Void

        mutating func next() async -> Element? {
            var base = self.base
            defer { self.base = base }
            return await withGracefulShutdownHandler {
                await base.next()
            } onGracefulShutdown: { [finish] in
                finish()
            }
        }
    }
}

private func frame(_ text: String) -> ArraySlice<UInt8> {
    ArraySlice(text.utf8)
}

private func sseFrame(_ event: Components.Schemas.MachineEvent) -> String {
    let data = (try? StoreCoding.encoder.encode(event)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    return "id: \(event.id ?? 0)\nevent: \(event.typeName)\ndata: \(data)\n\n"
}

extension Components.Schemas.MachineEvent {
    var typeName: String {
        switch self {
        case .machineAssigned: "machine-assigned"
        case .installStarted: "install-started"
        case .installProgress: "install-progress"
        case .installFailed: "install-failed"
        case .installComplete: "install-complete"
        case .guardInstalled: "guard-installed"
        case .resync: "resync"
        }
    }
}
