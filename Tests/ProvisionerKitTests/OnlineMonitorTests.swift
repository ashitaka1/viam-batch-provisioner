import Foundation
@testable import ProvisionerKit
import Testing

private let server = URL(string: "http://10.0.0.2:8235/")!
private let t0 = Date(timeIntervalSince1970: 5_000)

private func entry(_ name: String, _ status: EntryStatus = .installed, mode: ProvisionMode? = .full) -> QueueEntry {
    QueueEntry(name: name, status: status, hasCredentials: true, provisionMode: mode)
}

@MainActor
private func monitor(
    names: [String], url: URL = server, orgID: String? = "o1", locationID: String? = "loc-1", fleet: FakeFleet
) throws -> OnlineMonitor {
    let file = FileManager.default.temporaryDirectory.appending(path: "online-\(UUID().uuidString)/batches.json")
    let history = BatchHistory(file: file)
    try history.save(BatchRecord(
        id: UUID(), date: t0, environmentName: "Lab", mode: .full, orgName: "Acme", locationName: "Bench",
        serverName: "bench", serverURL: url, machines: names, problems: [], orgID: orgID, locationID: locationID))
    return OnlineMonitor(serverURL: server, history: history, fleet: { _ in fleet }, now: { t0 })
}

@MainActor
struct OnlineMonitorTests {
    @Test func onlineMachineIsMarked() async throws {
        let fleet = FakeFleet(existing: ["m-1", "m-2"], online: ["m-1"])
        let monitor = try monitor(names: ["m-1", "m-2"], fleet: fleet)

        await monitor.check([entry("m-1"), entry("m-2")])

        #expect(monitor.onlineAt == ["m-1": t0])
        #expect(await fleet.machinesCalls == 1)
    }

    @Test func onlyInstalledFullMachinesAreChecked() async throws {
        let fleet = FakeFleet(existing: ["a-1", "m-1"], online: ["a-1", "m-1"])
        let monitor = try monitor(names: ["a-1", "m-1"], fleet: fleet)

        await monitor.check([entry("a-1", mode: .agent), entry("m-1", .installing)])

        #expect(await fleet.machinesCalls == 0)
        #expect(monitor.onlineAt.isEmpty)
    }

    @Test func machineFromAnotherServerIsSkipped() async throws {
        let fleet = FakeFleet(existing: ["m-1"], online: ["m-1"])
        let monitor = try monitor(names: ["m-1"], url: URL(string: "http://10.0.0.9:8235/")!, fleet: fleet)

        await monitor.check([entry("m-1")])

        #expect(await fleet.machinesCalls == 0)
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

    @Test func failedListingIsRetriedNextRound() async throws {
        let failing = FakeFleet(existing: ["m-1"], listingFailure: .unreachable("down"), online: ["m-1"])
        let monitor = try monitor(names: ["m-1"], fleet: failing)

        await monitor.check([entry("m-1")])
        await monitor.check([entry("m-1")])

        #expect(monitor.onlineAt.isEmpty)
        #expect(await failing.machinesCalls == 2)
    }
}
