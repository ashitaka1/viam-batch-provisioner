import Foundation
import os
@testable import ProvisionerKit
import Testing

/// A server's queue: a fixed snapshot, and scripted answers to each provision call.
private final class FakeQueueWriter: QueueWriter {
    private struct State {
        var snapshot: Result<QueueSnapshot, ProvisionerError>
        var answers: [Result<[ProvisionResult]?, ProvisionerError>]
        var sent: [[ProvisionRequest]] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    /// A nil answer adds every item.
    init(queued: [String] = [], snapshotError: ProvisionerError? = nil,
         answers: [Result<[ProvisionResult]?, ProvisionerError>] = []) {
        let entries = queued.map { QueueEntry(name: $0, status: .queued, hasCredentials: true) }
        state = .init(initialState: State(
            snapshot: snapshotError.map { .failure($0) } ?? .success(QueueSnapshot(entries: entries, lastEventID: 0)),
            answers: answers))
    }

    var sent: [[ProvisionRequest]] { state.withLock { $0.sent } }

    func queue() async throws(ProvisionerError) -> QueueSnapshot {
        try state.withLock { $0.snapshot }.get()
    }

    func provision(_ requests: [ProvisionRequest]) async throws(ProvisionerError) -> [ProvisionResult] {
        let answer = state.withLock {
            $0.sent.append(requests)
            return $0.answers.isEmpty ? .success(nil) : $0.answers.removeFirst()
        }
        return try answer.get() ?? requests.map { ProvisionResult(name: $0.name, added: true) }
    }
}

private func environment(_ mode: ProvisionMode = .full) -> Environment {
    var environment = Environment.new(name: "lab")
    environment.provisionMode = mode
    environment.orgID = "org-1"
    environment.locationID = "loc-1"
    return environment
}

private func config(_ mode: ProvisionMode = .full) -> EnvironmentConfig {
    EnvironmentConfig(provisionMode: mode, username: "viam", passwordHash: "$6$salt$hash",
                      sshPublicKey: "ssh-ed25519 AAAA test", timezone: "UTC")
}

private let transportDown = ProvisionerError.transport(URLError(.cannotConnectToHost))

@MainActor
private func run(_ mode: ProvisionMode = .full, server: FakeQueueWriter, fleet: FakeFleet? = FakeFleet(), count: Int) async
    -> ProvisioningRun
{
    let run = ProvisioningRun(environment: environment(mode), config: config(mode), server: server, fleet: fleet)
    await run.start(count: count)
    return run
}

@MainActor
struct ProvisioningRunTests {
    @Test func fullModeQueuesEachCreatedMachineWithItsCredentialsAndTheEnvironment() async throws {
        let fleet = FakeFleet(existing: ["lab-1"])
        let server = FakeQueueWriter(queued: ["lab-2"])

        let run = await run(server: server, fleet: fleet, count: 2)

        #expect(run.phase == .finished)
        #expect(run.outcome.queued == ["lab-3", "lab-4"], "names skip the location's lab-1 and the queue's lab-2")
        let requests = try #require(server.sent.first)
        #expect(requests.map(\.name) == ["lab-3", "lab-4"])
        let blob = try #require(requests[0].credentialsJSON)
        let cloud = try #require((try JSONSerialization.jsonObject(with: blob) as? [String: [String: String]])?["cloud"])
        #expect(cloud["id"] == "p-lab-3" && cloud["secret"] == "s-lab-3")
        #expect(requests.allSatisfy { $0.environment == config() })
        #expect(run.outcome.unqueued.isEmpty)
    }

    @Test(arguments: [ProvisionMode.agent, .osOnly])
    func modesWithoutViamQueueNamesWithoutCredentialsOrViamCalls(mode: ProvisionMode) async throws {
        let fleet = FakeFleet(existing: ["lab-1"])
        let server = FakeQueueWriter(queued: ["lab-1"])

        let run = await run(mode, server: server, fleet: fleet, count: 2)

        #expect(run.outcome.queued == ["lab-2", "lab-3"], "only the queue's names are taken")
        let requests = try #require(server.sent.first)
        #expect(requests.allSatisfy { $0.credentialsJSON == nil && $0.environment == config(mode) })
        #expect(await fleet.calls == [])
    }

    @Test func unreadableQueueFailsBeforeAnythingIsCreated() async {
        let fleet = FakeFleet()
        let server = FakeQueueWriter(snapshotError: .server(status: 503, code: "queue-unreadable", message: "queue.json is corrupt", details: []))

        let run = await run(server: server, fleet: fleet, count: 1)

        #expect(run.phase == .failed("queue.json is corrupt"))
        #expect(await fleet.calls == [])
        #expect(server.sent.isEmpty)
    }

    @Test func badPrefixFailsBeforeAnythingIsCreated() async {
        var bad = environment()
        bad.namePrefix = "-lab"
        let fleet = FakeFleet()
        let run = ProvisioningRun(environment: bad, config: config(), server: FakeQueueWriter(), fleet: fleet)

        await run.start(count: 1)

        guard case .failed(let message) = run.phase else { Issue.record("expected failed, got \(run.phase)"); return }
        #expect(message.contains("starts with \"-\""))
        #expect(await fleet.calls == [])
    }

    @Test func viamFailuresAreReportedAndTheRestQueued() async {
        let fleet = FakeFleet(partFailures: ["lab-1": .failed("no main part")])
        let server = FakeQueueWriter()

        let run = await run(server: server, fleet: fleet, count: 2)

        #expect(run.outcome.queued == ["lab-2"])
        #expect(run.outcome.viamFailures.map(\.name) == ["lab-1"])
        #expect(server.sent.first?.map(\.name) == ["lab-2"], "a machine Viam didn't create is never sent")
    }

    @Test func rejectedKeyStopsTheBatchAndQueuesWhatWasCreated() async {
        let fleet = FakeFleet(createOutcomes: ["lab-2": .fail(.rejected("key revoked"))])
        let server = FakeQueueWriter()

        let run = await run(server: server, fleet: fleet, count: 3)

        #expect(run.outcome.stop == .rejected("key revoked"))
        #expect(run.outcome.untried == ["lab-3"])
        #expect(run.outcome.queued == ["lab-1"])
    }

    @Test func fullModeWithoutALocationFailsBeforeAnythingIsCreated() async {
        var noLocation = environment()
        noLocation.locationID = nil
        let fleet = FakeFleet()
        let server = FakeQueueWriter()
        let run = ProvisioningRun(environment: noLocation, config: config(), server: server, fleet: fleet)

        await run.start(count: 1)

        #expect(run.phase == .failed("Choose a Viam organization and location for lab."))
        #expect(await fleet.calls == [])
        #expect(server.sent.isEmpty)
    }

    @Test func aRunStartsOnce() async {
        let server = FakeQueueWriter()
        let run = await run(.osOnly, server: server, count: 1)

        await run.start(count: 1)
        await run.retrySending()

        #expect(server.sent.count == 1, "a second start or a retry after a clean run sends nothing")
    }

    @Test func failedSendKeepsTheMachinesForRetry() async {
        let server = FakeQueueWriter(answers: [.failure(transportDown)])

        let run = await run(server: server, count: 2)

        #expect(run.phase == .finished)
        #expect(run.outcome.queued == [])
        #expect(run.outcome.unqueued.map(\.name) == ["lab-1", "lab-2"])
        #expect(run.outcome.sendError == URLError(.cannotConnectToHost).localizedDescription)

        await run.retrySending()

        #expect(run.outcome.queued == ["lab-1", "lab-2"])
        #expect(run.outcome.unqueued.isEmpty)
        #expect(run.outcome.sendError == nil)
        #expect(server.sent.count == 2 && server.sent[1].map(\.name) == ["lab-1", "lab-2"], "the retry resends the same machines")
    }

    @Test func rejectedSendNamesTheServersReason() async {
        let server = FakeQueueWriter(answers: [.failure(.server(
            status: 400, code: "invalid-request", message: "Invalid request",
            details: [.init(index: 0, field: "environment.timezone", message: "unknown time zone")]))])

        let run = await run(.osOnly, server: server, count: 1)

        #expect(run.outcome.sendError == "Invalid request: unknown time zone")
    }

    @Test func machineTheServerSkippedIsLeftInViamUnqueued() async {
        let server = FakeQueueWriter(answers: [.success([
            ProvisionResult(name: "lab-1", added: true),
            ProvisionResult(name: "lab-2", added: false, reason: "already-queued"),
        ])])

        let run = await run(server: server, count: 2)

        #expect(run.outcome.queued == ["lab-1"])
        #expect(run.outcome.skipped == [ProvisionResult(name: "lab-2", added: false, reason: "already-queued")])
        #expect(run.outcome.unqueued.map(\.name) == ["lab-2"])
    }

    @Test func deletingUnqueuedMachinesRemovesThemFromViam() async {
        let fleet = FakeFleet(deleteFailures: ["lab-2": .unreachable("timeout")])
        let server = FakeQueueWriter(answers: [.failure(transportDown)])
        let run = await run(server: server, fleet: fleet, count: 2)

        await run.deleteUnqueued()

        #expect(await fleet.names == ["lab-2"])
        #expect(run.outcome.unqueued.map(\.name) == ["lab-2"], "a machine Viam didn't delete stays listed")
        // fleet.names lists what remains in Viam: lab-1 was deleted.
        #expect(run.outcome.deleteError == "lab-2: timeout")
    }

    @Test func failedSendWithoutViamIsReportedAndRetried() async {
        let server = FakeQueueWriter(answers: [.failure(transportDown)])

        let run = await run(.osOnly, server: server, count: 2)

        #expect(run.outcome.unsent == ["lab-1", "lab-2"])
        #expect(run.canRetry)
        #expect(run.outcome.problems.first == "lab-1 wasn't queued: \(URLError(.cannotConnectToHost).localizedDescription).")

        await run.retrySending()

        #expect(run.outcome.queued == ["lab-1", "lab-2"])
        #expect(run.outcome.problems == [])
    }

    @Test func skippedMachineIsNotRetried() async {
        let server = FakeQueueWriter(answers: [.success([ProvisionResult(name: "lab-1", added: false, reason: "already-queued")])])
        let run = await run(server: server, count: 1)

        await run.retrySending()

        #expect(!run.canRetry)
        #expect(server.sent.count == 1, "a skip is the server's answer; sending again gets the same one")
        #expect(run.outcome.problems == ["lab-1 was skipped: already-queued. It was created in Viam."])
    }

    @Test func deletedMachinesStayInTheReport() async {
        let server = FakeQueueWriter(answers: [.failure(transportDown)])
        let run = await run(server: server, count: 1)

        await run.deleteUnqueued()

        #expect(!run.canRetry)
        #expect(run.outcome.problems == ["lab-1 was deleted from Viam after it wasn't queued."])
    }
}
