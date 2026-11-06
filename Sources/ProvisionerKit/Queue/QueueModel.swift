public import Foundation
public import Observation
import os

/// A server's queue as `QueueModel` reads it.
public protocol QueueSource: QueueFeedSource {
    func entry(named name: String) async throws(ProvisionerError) -> QueueEntry
    func remove(named name: String) async throws(ProvisionerError)
}

extension ProvisionerClient: QueueSource {}

/// One server's queue, kept current from its feed. Entry status always comes
/// from the server: a snapshot, or a lookup of the entry an event names. The
/// events seen this session form each machine's timeline.
@MainActor @Observable
public final class QueueModel {
    public enum Connection: Equatable, Sendable {
        case connecting
        case live
        case waiting(retryIn: Duration, message: String)
    }

    public struct Counts: Equatable, Sendable {
        /// Queued or flashed: no machine has booted with the name yet.
        public var waiting = 0
        /// Assigned or installing.
        public var installing = 0
        public var installed = 0
        public var failed = 0
    }

    private static let log = Logger(subsystem: "ProvisionerKit", category: "QueueModel")

    public let serverName: String
    /// Sorted by name, numbers in names compared as numbers.
    public private(set) var entries: [QueueEntry] = []
    public private(set) var connection: Connection = .connecting
    private var timelines: [String: [MachineEvent]] = [:]
    /// Updates handled so far; tests wait on it.
    private(set) var handledUpdates = 0

    private let source: any QueueSource
    private let refreshInterval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    /// The last queued piece of work; each waits for the one before.
    private var tail: Task<Void, Never>?

    /// The queue is read again every `refreshInterval`, since queueing
    /// machines and changes outside the API emit no event.
    public init(serverName: String, source: any QueueSource, refreshInterval: Duration = .seconds(15),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.serverName = serverName
        self.source = source
        self.refreshInterval = refreshInterval
        self.sleep = sleep
    }

    public var counts: Counts {
        entries.reduce(into: Counts()) { counts, entry in
            switch entry.status {
            case .queued, .flashed: counts.waiting += 1
            case .assigned, .installing: counts.installing += 1
            case .installed: counts.installed += 1
            case .failed: counts.failed += 1
            }
        }
    }

    public func entry(named name: String) -> QueueEntry? {
        entries.first { $0.name == name }
    }

    /// Events seen for the machine this session, oldest first.
    public func timeline(for name: String) -> [MachineEvent] {
        timelines[name] ?? []
    }

    /// Follows the server until cancelled.
    public func run() async {
        let feed = QueueFeed(source: source)
        let refreshing = Task { [weak self, refreshInterval, sleep] in
            while true {
                do { try await sleep(refreshInterval) } catch { return }
                await self?.refresh()
            }
        }
        defer { refreshing.cancel() }
        await follow(updates: feed.updates(), states: feed.states)
    }

    func follow(updates: AsyncStream<QueueUpdate>, states: AsyncStream<FeedState>) async {
        let watching = Task { [weak self] in
            for await state in states { self?.connection = Connection(state) }
        }
        defer { watching.cancel() }
        for await update in updates {
            await serially { await self.handle(update) }
            handledUpdates += 1
        }
    }

    /// Reads the whole queue again. Queueing machines emits no event, and
    /// neither do changes made on the server outside the API.
    public func refresh() async {
        await serially {
            do {
                self.entries = try await self.source.queue().entries.sortedByName()
            } catch {
                Self.log.error("refreshing the queue failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Runs `work` after everything queued before it, so a lookup's answer
    /// never lands after a later read's, nor a stale read after a lookup's.
    private func serially(_ work: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let next = Task { @MainActor in
            await previous?.value
            await work()
        }
        tail = next
        await next.value
    }

    /// Removes the entry on the server, then here.
    /// A 404 counts as removed: the server no longer has the entry (decision 39).
    public func remove(named name: String) async throws(ProvisionerError) {
        do {
            try await source.remove(named: name)
        } catch .server(status: 404, _, _, _) {}
        entries.removeAll { $0.name == name }
    }

    private func handle(_ update: QueueUpdate) async {
        switch update {
        case .snapshot(let snapshot):
            entries = snapshot.sortedByName()
        case .event(let event, let inSnapshot):
            var timeline = timelines[event.name] ?? []
            if !timeline.contains(where: { $0.id == event.id }) {
                timeline.append(event)
                timeline.sort { $0.id < $1.id }
                timelines[event.name] = timeline
            }
            if !inSnapshot { await refreshEntry(event.name) }
        }
    }

    private func refreshEntry(_ name: String) async {
        do {
            let fresh = try await source.entry(named: name)
            entries.removeAll { $0.name == name }
            entries = (entries + [fresh]).sortedByName()
        } catch .server(status: 404, _, _, _) {
            entries.removeAll { $0.name == name }
        } catch {
            Self.log.error("refreshing \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}

extension QueueModel.Connection {
    init(_ state: FeedState) {
        switch state {
        case .connecting: self = .connecting
        case .live: self = .live
        case .waiting(let retry, let error): self = .waiting(retryIn: retry, message: error.queueMessage)
        }
    }
}

extension [QueueEntry] {
    func sortedByName() -> [QueueEntry] {
        sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension Error {
    /// What the operator reads when the server can't be used.
    var queueMessage: String {
        switch self as? ProvisionerError {
        case .server(_, _, let message, _)?: message
        case .unexpectedResponse(let status)?: "The server answered with HTTP \(status)."
        case .transport(let error)?: error.localizedDescription
        case .invalidCredentials?: "A machine's credentials aren't a valid viam.json."
        case nil: self is QueueFeed.StreamClosed ? "The server closed the event stream." : localizedDescription
        }
    }
}
