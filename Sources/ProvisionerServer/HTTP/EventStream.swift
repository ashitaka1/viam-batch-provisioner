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
        let body = sseBody(subscription, keepalive: streamOptions.keepalive, buffer: streamOptions.buffer) {
            Task { await streams.release() }
        }
        return .ok(.init(body: .textEventStream(body)))
    }
}

/// The SSE byte stream: `retry`, the backlog or a resync, then live events with a
/// keepalive comment after each `keepalive` of silence. The stream ends when
/// the server shuts down gracefully, and when `buffer` frames wait unread, so a
/// stalled client reconnects and resumes from its `Last-Event-ID`. Ending it,
/// by shutdown, overflow, disconnect or cancellation, cancels the subscription
/// and calls `release`.
func sseBody(_ subscription: EventSubscription, keepalive: Duration, buffer: Int,
             release: @escaping @Sendable () -> Void) -> HTTPBody {
    let backlog: [String] = switch subscription.backlog {
    case .events(let events): events.map(sseFrame)
    case .resync(let latest): ["event: resync\ndata: {\"latest_id\":\(latest),\"type\":\"resync\"}\n\n"]
    }
    let (stream, out) = AsyncStream.makeStream(of: ArraySlice<UInt8>.self,
                                               bufferingPolicy: .bufferingOldest(1 + backlog.count + buffer))
    let tasks = NIOLockedValueBox(StreamTasks())
    out.onTermination = { _ in
        tasks.withLockedValue { $0.terminate() }.forEach { $0.cancel() }
        subscription.cancel()
        release()
    }
    @Sendable func send(_ text: String) -> Bool {
        switch out.yield(frame(text)) {
        case .enqueued: return true
        case .dropped:
            out.finish()
            return false
        case .terminated: return false
        @unknown default: return false
        }
    }
    _ = send("retry: 3000\n\n")
    for text in backlog { _ = send(text) }

    let quiet = NIOLockedValueBox(true)
    let live = Task {
        for await event in subscription.live {
            quiet.withLockedValue { $0 = false }
            guard send(sseFrame(event)) else { return }
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
            if silent, !send(": keepalive\n\n") { return }
        }
    }
    if !tasks.withLockedValue({ $0.adopt([live, ticks]) }) {
        live.cancel()
        ticks.cancel()
    }
    return HTTPBody(SSEFrames(stream: stream, finish: { out.finish() }), length: .unknown, iterationBehavior: .single)
}

/// The tasks feeding a stream, cancelled by its termination handler. Tasks
/// adopted after termination are refused so the caller cancels them.
private struct StreamTasks {
    private var terminated = false
    private var tasks: [any Cancellable] = []

    mutating func adopt(_ more: [any Cancellable]) -> Bool {
        guard !terminated else { return false }
        tasks += more
        return true
    }

    mutating func terminate() -> [any Cancellable] {
        terminated = true
        defer { tasks = [] }
        return tasks
    }
}

private protocol Cancellable: Sendable { func cancel() }
extension Task: Cancellable {}

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
