import Foundation
import os
@testable import ProvisionerKit
import Testing

/// Answers `entry(named:)` from a table the test edits; records each lookup and removal.
private final class FakeQueueSource: QueueSource {
    private struct State {
        var entries: [String: Result<QueueEntry, ProvisionerError>] = [:]
        var lookups: [String] = []
        var removals: [String] = []
        var removeFailure: ProvisionerError?
        var snapshot: Result<QueueSnapshot, ProvisionerError> = .success(QueueSnapshot(entries: [], lastEventID: 0))
        var holdingLookups = false
        var held: [CheckedContinuation<Void, Never>] = []
        /// "lookup <name>", "looked up <name>" and "queue", in order.
        var calls: [String] = []
        var openStreams: [AsyncThrowingStream<ServerSentEvent, any Error>.Continuation] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func set(_ entry: QueueEntry) { state.withLock { $0.entries[entry.name] = .success(entry) } }
    func setMissing(_ name: String) { state.withLock { $0.entries[name] = .failure(notFound(name)) } }
    func setFailure(_ name: String, _ error: ProvisionerError) { state.withLock { $0.entries[name] = .failure(error) } }
    func failRemovals(with error: ProvisionerError) { state.withLock { $0.removeFailure = error } }
    func setSnapshot(_ snapshot: Result<QueueSnapshot, ProvisionerError>) { state.withLock { $0.snapshot = snapshot } }
    var lookups: [String] { state.withLock { $0.lookups } }
    var removals: [String] { state.withLock { $0.removals } }
    var calls: [String] { state.withLock { $0.calls } }
    func holdLookups() { state.withLock { $0.holdingLookups = true } }
    var heldLookups: Int { state.withLock { $0.held.count } }
    func releaseLookups() {
        let held = state.withLock {
            $0.holdingLookups = false
            defer { $0.held = [] }
            return $0.held
        }
        held.forEach { $0.resume() }
    }

    func entry(named name: String) async throws(ProvisionerError) -> QueueEntry {
        let hold = state.withLock {
            $0.lookups.append(name)
            $0.calls.append("lookup \(name)")
            return $0.holdingLookups
        }
        if hold { await withCheckedContinuation { c in state.withLock { $0.held.append(c) } } }
        let result = state.withLock {
            $0.calls.append("looked up \(name)")
            return $0.entries[name] ?? .failure(notFound(name))
        }
        return try result.get()
    }

    func remove(named name: String) async throws(ProvisionerError) {
        let failure = state.withLock {
            $0.removals.append(name)
            return $0.removeFailure
        }
        if let failure { throw failure }
    }

    func queue() async throws -> QueueSnapshot {
        try state.withLock {
            $0.calls.append("queue")
            return $0.snapshot
        }.get()
    }
    /// Stays open, sending nothing.
    func eventFrames(after id: Int) async throws -> AsyncThrowingStream<ServerSentEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ServerSentEvent.self)
        state.withLock { $0.openStreams.append(continuation) }
        return stream
    }
}

private func notFound(_ name: String) -> ProvisionerError {
    .server(status: 404, code: "not-found", message: "no \(name)", details: [])
}

private func entry(_ name: String, _ status: EntryStatus, stage: String? = nil) -> QueueEntry {
    QueueEntry(name: name, status: status, stage: stage, hasCredentials: true)
}

private func event(_ id: Int, _ name: String, _ kind: MachineEvent.Kind = .assigned) -> MachineEvent {
    MachineEvent(id: id, timestamp: Date(timeIntervalSince1970: TimeInterval(id)), name: name, mac: "aa:bb:cc:dd:ee:ff", kind: kind)
}

/// Feeds a model hand-made updates and states, and lets the test wait for each to be handled.
@MainActor
private final class Harness {
    let source = FakeQueueSource()
    let model: QueueModel
    private let updates: AsyncStream<QueueUpdate>.Continuation
    private let states: AsyncStream<FeedState>.Continuation
    private let running: Task<Void, Never>

    init() {
        let source = source
        model = QueueModel(serverName: "bench", source: source)
        let (updateStream, updates) = AsyncStream.makeStream(of: QueueUpdate.self)
        let (stateStream, states) = AsyncStream.makeStream(of: FeedState.self)
        self.updates = updates
        self.states = states
        running = Task { [model] in await model.follow(updates: updateStream, states: stateStream) }
    }

    deinit { running.cancel() }

    func yield(_ update: QueueUpdate) { updates.yield(update) }

    /// Sends the update and returns once the model has handled it.
    func send(_ update: QueueUpdate) async {
        let before = model.handledUpdates
        updates.yield(update)
        #expect(await poll { self.model.handledUpdates > before }, "update \(update) was never handled")
    }

    func yield(_ state: FeedState) { states.yield(state) }

    func names() -> [String] { model.entries.map(\.name) }
    func status(_ name: String) -> EntryStatus? { model.entry(named: name)?.status }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct QueueModelTests {
    @Test func snapshotReplacesEntriesInNaturalNameOrder() async {
        let h = Harness()
        await h.send(.snapshot([entry("old", .queued)]))
        await h.send(.snapshot([entry("lab-10", .queued), entry("lab-2", .installing), entry("Lab-1", .failed)]))

        #expect(h.names() == ["Lab-1", "lab-2", "lab-10"])
    }

    @Test func liveEventTakesTheEntryFromTheServerNotFromTheEvent() async {
        let h = Harness()
        await h.send(.snapshot([entry("m1", .queued)]))
        // The server derives status from disk; the event's kind says nothing about it.
        h.source.set(entry("m1", .installing, stage: "late-commands"))

        await h.send(.event(event(11, "m1", .assigned), inSnapshot: false))

        #expect(h.model.entry(named: "m1") == entry("m1", .installing, stage: "late-commands"))
        #expect(h.names() == ["m1"], "the fresh entry replaces the old one")
        #expect(h.model.timeline(for: "m1").map(\.id) == [11])
    }

    @Test func eventInSnapshotJoinsTheTimelineWithoutALookup() async {
        let h = Harness()
        await h.send(.snapshot([entry("m1", .assigned)]))

        await h.send(.event(event(9, "m1"), inSnapshot: true))

        #expect(h.source.lookups == [])
        #expect(h.status("m1") == .assigned)
        #expect(h.model.timeline(for: "m1").map(\.id) == [9])
    }

    @Test func downloadProgressRefreshesTheEntryButStaysOutOfTheTimeline() async {
        let h = Harness()
        await h.send(.snapshot([entry("m1", .assigned)]))
        h.source.set(entry("m1", .assigned, stage: "late-commands"))

        await h.send(.event(event(11, "m1", .stepReached(step: .downloading, attempt: 1)), inSnapshot: false))
        await h.send(.event(event(12, "m1", .downloadProgress(bytes: 50, total: 100)), inSnapshot: false))

        #expect(h.source.lookups == ["m1", "m1"])
        #expect(h.model.entry(named: "m1")?.stage == "late-commands")
        #expect(h.model.timeline(for: "m1").map(\.id) == [11])
    }

    @Test func replayedEventIsKeptOnceInTheTimeline() async {
        let h = Harness()
        h.source.set(entry("m1", .assigned))
        // A reconnect can replay an older event after a newer one.
        await h.send(.event(event(12, "m1", .installStarted), inSnapshot: false))
        await h.send(.event(event(11, "m1"), inSnapshot: false))
        await h.send(.event(event(11, "m1"), inSnapshot: true))

        #expect(h.model.timeline(for: "m1").map(\.id) == [11, 12])
    }

    @Test func eventForANameNotYetListedAddsIt() async {
        let h = Harness()
        await h.send(.snapshot([entry("m2", .queued)]))
        h.source.set(entry("m1", .assigned))

        await h.send(.event(event(11, "m1"), inSnapshot: false))

        #expect(h.names() == ["m1", "m2"])
    }

    @Test func eventForANameTheServerNoLongerHasRemovesIt() async {
        let h = Harness()
        await h.send(.snapshot([entry("m1", .installed), entry("m2", .queued)]))
        h.source.setMissing("m1")

        await h.send(.event(event(11, "m1", .installComplete(duration: 600)), inSnapshot: false))

        #expect(h.names() == ["m2"])
    }

    @Test func failedLookupKeepsTheEntryAsItWas() async {
        let h = Harness()
        await h.send(.snapshot([entry("m1", .queued)]))
        h.source.setFailure("m1", .unexpectedResponse(status: 502))

        await h.send(.event(event(11, "m1"), inSnapshot: false))

        #expect(h.status("m1") == .queued)
    }

    @Test func connectionFollowsTheFeedState() async {
        let h = Harness()
        #expect(h.model.connection == .connecting)

        h.yield(.live)
        _ = await poll { h.model.connection == .live }
        #expect(h.model.connection == .live)

        h.yield(.waiting(retryIn: .seconds(6), lastError: ProvisionerError.unexpectedResponse(status: 503)))
        let waiting = QueueModel.Connection.waiting(retryIn: .seconds(6), message: "The server answered with HTTP 503.")
        _ = await poll { h.model.connection == waiting }
        #expect(h.model.connection == waiting)
    }

    @Test func removeKeepsTheEntryWhenTheServerRefuses() async throws {
        let h = Harness()
        await h.send(.snapshot([entry("m1", .queued), entry("m2", .installing)]))

        try await h.model.remove(named: "m1")
        #expect(h.names() == ["m2"])

        let conflict = ProvisionerError.server(status: 409, code: "conflict", message: "m2 is installing", details: [])
        h.source.failRemovals(with: conflict)
        await #expect(throws: conflict) { try await h.model.remove(named: "m2") }
        #expect(h.names() == ["m2"])
        #expect(h.source.removals == ["m1", "m2"])
    }

    /// A 404 means the server no longer has the entry, which is what removing asked for (decision 39).
    @Test func removeDropsAnEntryTheServerNoLongerHas() async throws {
        let h = Harness()
        await h.send(.snapshot([entry("m1", .queued), entry("m2", .queued)]))
        h.source.failRemovals(with: notFound("m1"))

        try await h.model.remove(named: "m1")

        #expect(h.names() == ["m2"])
    }

    @Test func countsGroupStatusesTheWayTheQueueViewShowsThem() async {
        let h = Harness()
        await h.send(.snapshot([
            entry("a", .queued), entry("b", .flashed), entry("c", .assigned), entry("d", .installing),
            entry("e", .installed), entry("f", .failed), entry("g", .failed),
        ]))

        #expect(h.model.counts == QueueModel.Counts(waiting: 2, installing: 2, installed: 1, failed: 2))
    }

    @Test func refreshReadsTheWholeQueueAgain() async {
        // Queueing a batch emits no event, so the view refreshes after provisioning.
        let h = Harness()
        await h.send(.snapshot([]))
        h.source.setSnapshot(.success(QueueSnapshot(entries: [entry("qa-2", .queued), entry("qa-1", .queued)], lastEventID: 0)))

        await h.model.refresh()

        #expect(h.names() == ["qa-1", "qa-2"])
    }

    @Test func runFollowsTheServersFeed() async {
        let source = FakeQueueSource()
        source.setSnapshot(.success(QueueSnapshot(entries: [entry("m1", .queued)], lastEventID: 0)))
        let model = QueueModel(serverName: "bench", source: source)

        let running = Task { await model.run() }
        _ = await poll { model.entries.map(\.name) == ["m1"] }
        #expect(model.entries.map(\.name) == ["m1"])
        running.cancel()
        await running.value
    }

    @Test func failedRefreshKeepsTheEntries() async {
        let h = Harness()
        await h.send(.snapshot([entry("m1", .queued)]))
        h.source.setSnapshot(.failure(.unexpectedResponse(status: 502)))

        await h.model.refresh()

        #expect(h.names() == ["m1"])
    }

    @Test func refreshWaitsForTheLookupInProgress() async {
        // A snapshot read before a lookup's answer lands would overwrite that newer answer.
        let h = Harness()
        await h.send(.snapshot([entry("m1", .installing)]))
        h.source.set(entry("m1", .installed))
        h.source.holdLookups()
        h.yield(.event(event(11, "m1", .installComplete(duration: 60)), inSnapshot: false))
        _ = await poll { h.source.heldLookups == 1 }

        let refreshing = Task { await h.model.refresh() }
        for _ in 0..<50 { await Task.yield() }
        #expect(!h.source.calls.contains("queue"), "the refresh read the queue while the lookup was in flight")

        h.source.releaseLookups()
        await refreshing.value
        #expect(h.source.calls == ["lookup m1", "looked up m1", "queue"])
    }

    @Test func runRefreshesTheQueueOnItsInterval() async {
        let source = FakeQueueSource()
        // Each sleep ends by taking a permit the test grants.
        let permits = OSAllocatedUnfairLock(initialState: 0)
        let model = QueueModel(serverName: "bench", source: source, refreshInterval: .seconds(15), sleep: { _ in
            while !permits.withLock({ if $0 > 0 { $0 -= 1; return true } else { return false } }) {
                try await Task.sleep(for: .milliseconds(1))
            }
        })
        let running = Task { await model.run() }
        defer { running.cancel() }
        _ = await poll { source.calls.contains("queue") }

        source.setSnapshot(.success(QueueSnapshot(entries: [entry("qa-1", .queued)], lastEventID: 0)))
        permits.withLock { $0 += 1 }

        _ = await poll { model.entries.map(\.name) == ["qa-1"] }
        #expect(model.entries.map(\.name) == ["qa-1"], "machines queued without an event appear on the next refresh")
    }
}
