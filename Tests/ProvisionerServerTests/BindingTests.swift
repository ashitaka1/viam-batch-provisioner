import Foundation
@testable import ProvisionerServer
import Testing

private let mac1 = "aa:bb:cc:00:00:01"
private let mac2 = "aa:bb:cc:00:00:02"

/// `m-1` and `m-2` queued with an environment, on a provisioner with a boot image.
private func queued() async throws -> Provisioner {
    let (provisioner, _) = try makeImageProvisioner()
    _ = try await provisioner.provision([request("m-1", environment: validEnvironment()),
                                         request("m-2", environment: validEnvironment())])
    return provisioner
}

@Test(arguments: [
    ("aa:bb:cc:00:00:01", "aa:bb:cc:00:00:01"), ("AA:BB:CC:00:00:01", "aa:bb:cc:00:00:01"),
    ("aa-bb-cc-00-00-01", "aa:bb:cc:00:00:01"),
])
func macsAreNormalised(input: String, expected: String) {
    #expect(normalizedMAC(input) == expected)
}

@Test(arguments: ["aa:bb:cc:00:00", "zz:bb:cc:00:00:01", "aabbcc000001", "aa:bb-cc:00:00:01", "", "aa:bb:cc:00:00:01:02"])
func malformedMACsAreRefused(input: String) {
    #expect(normalizedMAC(input) == nil)
}

@Test func bindMakesTheEntryAssigned() async throws {
    let provisioner = try await queued()
    let entry = try await provisioner.bind("M-1", mac: "AA-BB-CC-00-00-01")
    #expect(entry.mac == mac1)
    #expect(entry.status == .assigned)
    #expect(entry.assignedAt == t0)
    #expect(await eventSummary(provisioner).last == "machine-assigned m-1 \(mac1)")
    #expect(await provisioner.counts()?.assigned == 1)
}

@Test func unbindReturnsTheEntryToQueued() async throws {
    let provisioner = try await queued()
    _ = try await provisioner.bind("m-1", mac: mac1)
    try await provisioner.unbind("m-1")
    let entry = try await provisioner.entry("m-1")
    #expect(entry.status == .queued)
    #expect(entry.mac == nil)
    #expect(entry.assignedAt == nil)
}

@Test func bindRefusesAMalformedMAC() async throws {
    let provisioner = try await queued()
    let failure = await failure { try await provisioner.bind("m-1", mac: "aa:bb:cc:00:00") }
    #expect(failure?.kind == "invalid")
}

@Test func bindRefusesAnUnqueuedName() async throws {
    let provisioner = try await queued()
    #expect(await failure { try await provisioner.bind("m-9", mac: mac1) } == .notFound("m-9"))
}

@Test func bindRefusesAMACBoundToAnotherName() async throws {
    let provisioner = try await queued()
    _ = try await provisioner.bind("m-1", mac: mac1)
    #expect(await failure { try await provisioner.bind("m-2", mac: mac1) } == .macBound("m-1"))
}

@Test func bindRefusesUnbindableEntries() async throws {
    let provisioner = try await queued()
    _ = try await provisioner.provision([request("bare")])
    #expect(await failure { try await provisioner.bind("bare", mac: mac1) }?.kind == "notBindable")

    _ = try await provisioner.report(report(.progress, .lateCommands, name: "m-1"))
    #expect(await failure { try await provisioner.bind("m-1", mac: mac1) }?.kind == "notBindable")

    _ = try await provisioner.report(report(.progress, .done, name: "m-2"))
    #expect(await failure { try await provisioner.bind("m-2", mac: mac2) }?.kind == "notBindable")

    let (noImage, _) = try makeProvisioner()
    _ = try await noImage.provision([request("m-1", environment: validEnvironment())])
    #expect(await failure { try await noImage.bind("m-1", mac: mac1) }?.kind == "notBindable")
}

@Test func unbindRefusesAnInstallingMachine() async throws {
    let provisioner = try await queued()
    _ = try await provisioner.bind("m-1", mac: mac1)
    _ = try await provisioner.report(report(.progress, .lateCommands, name: "m-1"))
    #expect(await failure { try await provisioner.unbind("m-1") } == .alreadyAssigned("m-1"))
}

@Test func rebindReplacesTheMAC() async throws {
    let provisioner = try await queued()
    _ = try await provisioner.bind("m-1", mac: mac1)
    #expect(try await provisioner.bind("m-1", mac: mac2).mac == mac2)
    #expect(try await provisioner.bind("m-2", mac: mac1).mac == mac1)
}
