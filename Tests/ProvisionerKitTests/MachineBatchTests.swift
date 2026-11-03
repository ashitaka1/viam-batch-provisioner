import Foundation
import ProvisionerKit
import Testing

private func batch(_ fleet: FakeFleet) -> MachineBatch {
    MachineBatch(fleet: fleet, location: "loc-1")
}

private func create(_ fleet: FakeFleet, count: Int, queued: Set<String> = []) async throws -> BatchResult {
    try await batch(fleet).create(prefix: "lab-pi", count: count, queued: queued)
}

@Test func createsEveryMachine() async throws {
    let fleet = FakeFleet(existing: ["lab-pi-1"])
    let result = try await create(fleet, count: 2)

    #expect(result.created.map(\.name) == ["lab-pi-2", "lab-pi-3"])
    #expect(result.failures.isEmpty && result.stop == nil && result.untried.isEmpty)
    let machine = try #require(result.created.first)
    #expect(machine.machineID == "m-lab-pi-2" && machine.partID == "p-lab-pi-2")
    let json = try #require(try JSONSerialization.jsonObject(with: machine.credentialsJSON) as? [String: [String: String]])
    #expect(json == ["cloud": ["app_address": "https://app.viam.com:443", "id": "p-lab-pi-2", "secret": "s-lab-pi-2"]])
    #expect(machine.request.name == "lab-pi-2")
    #expect(machine.request.credentialsJSON == machine.credentialsJSON)
}

@Test func partFailureDeletesAndContinues() async throws {
    let fleet = FakeFleet(partFailures: ["lab-pi-1": .failed("no main part")])
    let result = try await create(fleet, count: 2)

    #expect(result.created.map(\.name) == ["lab-pi-2"])
    #expect(result.failures == [MachineFailure(name: "lab-pi-1", message: "no main part", machineID: "m-lab-pi-1", leftInViam: false)])
    #expect(await fleet.names == ["lab-pi-2"], "the failed machine must be deleted from Viam")
}

@Test func deleteFailureIsLeftInViam() async throws {
    let fleet = FakeFleet(partFailures: ["lab-pi-1": .failed("no main part")], deleteFailures: ["lab-pi-1": .unreachable("timeout")])
    let result = try await create(fleet, count: 1)

    #expect(result.failures == [MachineFailure(name: "lab-pi-1", message: "no main part", machineID: "m-lab-pi-1", leftInViam: true)])
}

@Test func createFailedStatusLeavesNothing() async throws {
    let fleet = FakeFleet(createOutcomes: ["lab-pi-1": .fail(.failed("already a robot with the name lab-pi-1"))])
    let result = try await create(fleet, count: 1)

    #expect(result.failures == [MachineFailure(
        name: "lab-pi-1", message: "already a robot with the name lab-pi-1", machineID: nil, leftInViam: false)])
    #expect(!(await fleet.calls).contains { if case .delete = $0 { true } else { false } })
}

@Test func unknownCreateOutcomeLooksUpAndDeletes() async throws {
    let fleet = FakeFleet(createOutcomes: ["lab-pi-1": .createdThenUnreachable])
    let result = try await create(fleet, count: 1)

    #expect(await fleet.calls == [.machines, .create("lab-pi-1"), .machines, .delete("m-lab-pi-1")])
    #expect(result.failures == [MachineFailure(name: "lab-pi-1", message: "connection reset", machineID: "m-lab-pi-1", leftInViam: false)])
    #expect(await fleet.names == [])
}

@Test func unknownCreateOutcomeNotFoundLeavesNothing() async throws {
    let fleet = FakeFleet(createOutcomes: ["lab-pi-1": .fail(.unreachable("timeout"))])
    let result = try await create(fleet, count: 1)

    #expect(result.failures == [MachineFailure(name: "lab-pi-1", message: "timeout", machineID: nil, leftInViam: false)])
    #expect(await fleet.calls == [.machines, .create("lab-pi-1"), .machines])
}

@Test func unknownCreateOutcomeLookupFailsIsLeftInViam() async throws {
    let fleet = FakeFleet(
        createOutcomes: ["lab-pi-1": .createdThenUnreachable],
        listingFailureAfterCreate: .unreachable("offline"))
    let result = try await create(fleet, count: 2)

    #expect(result.failures.first == MachineFailure(name: "lab-pi-1", message: "connection reset", machineID: nil, leftInViam: true))
    #expect(result.created.map(\.name) == ["lab-pi-2"], "the batch continues with the next name")
}

@Test func rejectionStopsWithPartialResult() async throws {
    let fleet = FakeFleet(createOutcomes: ["lab-pi-2": .fail(.rejected("key revoked"))])
    let result = try await create(fleet, count: 3)

    #expect(result.created.map(\.name) == ["lab-pi-1"])
    #expect(result.stop == .rejected("key revoked"))
    #expect(result.untried == ["lab-pi-3"])
    #expect(result.failures.map(\.name) == ["lab-pi-2"])
}

@Test func cancelMidMachineFinishesIt() async throws {
    let fleet = FakeFleet(holdAfterCreating: "lab-pi-1")
    let running = Task { try await create(fleet, count: 3) }
    await fleet.waitUntilHeld()
    running.cancel()
    await fleet.release()
    let result = try await running.value

    #expect(result.created.map(\.name) == ["lab-pi-1"], "the machine in progress must be finished, not abandoned")
    #expect(result.stop == .cancelled)
    #expect(result.untried == ["lab-pi-2", "lab-pi-3"])
}

@Test func listingFailureThrows() async {
    let fleet = FakeFleet(listingFailure: .unreachable("offline"))
    await #expect(throws: BatchError.fleet(.unreachable("offline"))) { try await create(fleet, count: 1) }
    #expect(await fleet.calls == [.machines])
}

@Test func namingErrorThrows() async {
    let fleet = FakeFleet()
    await #expect(throws: BatchError.naming(.invalidCount(0))) { try await create(fleet, count: 0) }
    #expect(await fleet.calls.allSatisfy { $0 == .machines }, "no machine may be created")
}

@Test func descriptionsHideSecrets() async throws {
    let result = try await create(FakeFleet(), count: 1)
    #expect(!String(describing: result.created[0]).contains("s-lab-pi-1"))
    #expect(!String(describing: result).contains("s-lab-pi-1"))
    #expect(!String(reflecting: result).contains("s-lab-pi-1"))
}
