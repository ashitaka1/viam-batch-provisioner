import Foundation
import os
@testable import ProvisionerKit
import Testing

private let server = URL(string: "http://10.0.0.2:8235/")!
private let t0 = Date(timeIntervalSince1970: 5_000)

private func entry(_ name: String, _ status: EntryStatus = .installed, mode: ProvisionMode? = .full) -> QueueEntry {
    QueueEntry(name: name, status: status, hasCredentials: true, provisionMode: mode)
}

@MainActor
private func monitor(
    names: [String], url: URL = server, orgID: String? = "o1", locationID: String? = "loc-1", fleet: FakeFleet,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
) throws -> OnlineMonitor {
    let file = FileManager.default.temporaryDirectory.appending(path: "online-\(UUID().uuidString)/batches.json")
    let history = BatchHistory(file: file)
    try history.save(BatchRecord(
        id: UUID(), date: t0, environmentName: "Lab", mode: .full, orgName: "Acme", locationName: "Bench",
        serverName: "bench", serverURL: url, machines: names, problems: [], orgID: orgID, locationID: locationID))
    return OnlineMonitor(serverURL: server, history: history, fleet: { _ in fleet }, now: { t0 }, sleep: sleep)
}

/// A server whose queue is `entries`.
private struct FixedQueue: QueueSource {
    let entries: [QueueEntry]

    func queue() async throws -> QueueSnapshot { QueueSnapshot(entries: entries, lastEventID: 0) }
    func entry(named name: String) async throws(ProvisionerError) -> QueueEntry { entries.first { $0.name == name }! }
    func remove(named name: String) async throws(ProvisionerError) {}
    func eventFrames(after id: Int) async throws -> AsyncThrowingStream<ServerSentEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct StopSleeping: Error {}

@MainActor
struct OnlineMonitorTests {
    @Test func onlineMachineIsMarked() async throws {
        let fleet = FakeFleet(existing: ["m-1", "m-2"], online: ["m-1"])
        let monitor = try monitor(names: ["m-1", "m-2"], fleet: fleet)

        await monitor.check([entry("m-1"), entry("m-2")])

        #expect(monitor.onlineAt == ["m-1": t0])
        #expect(await fleet.machinesCalls == 1)
    }

    @Test func agentMachineIsNotChecked() async throws {
        let fleet = FakeFleet(existing: ["a-1"], online: ["a-1"])
        let monitor = try monitor(names: ["a-1"], fleet: fleet)

        await monitor.check([entry("a-1", mode: .agent)])

        #expect(await fleet.machinesCalls == 0)
        #expect(monitor.onlineAt.isEmpty)
    }

    @Test func machineWithoutAModeIsNotChecked() async throws {
        let fleet = FakeFleet(existing: ["m-1"], online: ["m-1"])
        let monitor = try monitor(names: ["m-1"], fleet: fleet)

        await monitor.check([entry("m-1", mode: nil)])

        #expect(await fleet.machinesCalls == 0)
        #expect(monitor.onlineAt.isEmpty)
    }

    @Test func machineStillInstallingIsNotChecked() async throws {
        let fleet = FakeFleet(existing: ["m-1"], online: ["m-1"])
        let monitor = try monitor(names: ["m-1"], fleet: fleet)

        await monitor.check([entry("m-1", .installing)])

        #expect(await fleet.machinesCalls == 0)
        #expect(monitor.onlineAt.isEmpty)
    }

    @Test func machineFromAnotherServerIsSkipped() async throws {
        let fleet = FakeFleet(existing: ["m-1"], online: ["m-1"])
        let monitor = try monitor(names: ["m-1"], url: URL(string: "http://10.0.0.9:8235/")!, fleet: fleet)

        await monitor.check([entry("m-1")])

        #expect(await fleet.machinesCalls == 0)
    }

    @Test func machineOutsideTheBatchIsNotMarked() async throws {
        let fleet = FakeFleet(existing: ["m-1", "other"], online: ["m-1", "other"])
        let monitor = try monitor(names: ["m-1"], fleet: fleet)

        await monitor.check([entry("m-1"), entry("other")])

        #expect(Array(monitor.onlineAt.keys) == ["m-1"])
    }

    @Test func recordWithoutOrgIsSkipped() async throws {
        let fleet = FakeFleet(existing: ["m-1"], online: ["m-1"])
        let monitor = try monitor(names: ["m-1"], orgID: nil, locationID: nil, fleet: fleet)

        await monitor.check([entry("m-1")])

        #expect(await fleet.machinesCalls == 0)
    }

    @Test func onlineMachineIsNotCheckedAgain() async throws {
        let fleet = FakeFleet(existing: ["m-1"], online: ["m-1"])
        let monitor = try monitor(names: ["m-1"], fleet: fleet)

        await monitor.check([entry("m-1")])
        await monitor.check([entry("m-1")])

        #expect(await fleet.machinesCalls == 1)
    }

    @Test func offlineMachineIsCheckedUntilOnline() async throws {
        let fleet = FakeFleet(existing: ["m-1"], online: [])
        let monitor = try monitor(names: ["m-1"], fleet: fleet)

        await monitor.check([entry("m-1")])
        #expect(monitor.onlineAt.isEmpty)
        await fleet.setOnline(["m-1"])
        await monitor.check([entry("m-1")])

        #expect(monitor.onlineAt == ["m-1": t0])
        #expect(await fleet.machinesCalls == 2)
    }

    @Test func failedListingIsRetriedNextRound() async throws {
        let failing = FakeFleet(existing: ["m-1"], listingFailure: .unreachable("down"), online: ["m-1"])
        let monitor = try monitor(names: ["m-1"], fleet: failing)

        await monitor.check([entry("m-1")])
        await monitor.check([entry("m-1")])

        #expect(monitor.onlineAt.isEmpty)
        #expect(await failing.machinesCalls == 2)
    }

    @Test func machineNoLongerInstalledLosesItsOnlineTime() async throws {
        let fleet = FakeFleet(existing: ["m-1", "m-2"], online: ["m-1", "m-2"])
        let monitor = try monitor(names: ["m-1", "m-2"], fleet: fleet)
        await monitor.check([entry("m-1"), entry("m-2")])

        await monitor.check([entry("m-1", .assigned), entry("m-2")])

        #expect(monitor.onlineAt == ["m-2": t0])
    }

    @Test func runChecksEachRoundUntilSleepFails() async throws {
        let fleet = FakeFleet(existing: ["m-1"], online: [])
        let sleeps = OSAllocatedUnfairLock(initialState: 0)
        let monitor = try monitor(names: ["m-1"], fleet: fleet, sleep: { _ in
            let count = sleeps.withLock { count in
                count += 1
                return count
            }
            if count == 2 { throw StopSleeping() }
        })
        let queue = QueueModel(serverName: "bench", source: FixedQueue(entries: [entry("m-1")]))
        await queue.refresh()

        await monitor.run(queue)

        #expect(sleeps.withLock { $0 } == 2)
        #expect(await fleet.machinesCalls == 2)
    }
}
