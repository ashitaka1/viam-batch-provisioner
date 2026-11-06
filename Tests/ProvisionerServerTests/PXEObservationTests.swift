import Foundation
import ProvisionerAPI
@testable import ProvisionerServer
import Testing

private let mac = "aa:bb:cc:00:00:01"

private func bound(now: @escaping @Sendable () -> Date = { t0 }) async throws -> Provisioner {
    let (provisioner, _) = try makeProvisioner(bindings: FixedBindings(), now: now)
    _ = try await provisioner.provision([request("m-1")])
    return provisioner
}

private func stepList(_ provisioner: Provisioner) async throws -> [String] {
    try await provisioner.entry("m-1").steps?.map { "\($0.step.rawValue)@\($0.attempt)" } ?? []
}

@Test func offerReachesFound() async throws {
    let provisioner = try await bound()
    await provisioner.observe(.offered(mac: mac))

    let entry = try await provisioner.entry("m-1")
    #expect(try await stepList(provisioner) == ["found@1"])
    #expect(entry.status == .assigned)
    #expect(await provisioner.machineRecord("m-1")?.attemptStartedAt == t0)
    #expect(await eventSummary(provisioner) == ["step-reached m-1 found"])
}

@Test func repeatOfferInOneBootIsIgnored() async throws {
    let provisioner = try await bound()
    await provisioner.observe(.offered(mac: mac))
    await provisioner.observe(.offered(mac: mac))

    #expect(try await stepList(provisioner) == ["found@1"])
    #expect(await eventSummary(provisioner).count == 1)
}

@Test func kernelAndInitrdReachBooting() async throws {
    let provisioner = try await bound()
    await provisioner.observe(.offered(mac: mac))
    await provisioner.observe(.fileSent(filename: "hwe-vmlinuz", mac: mac))
    #expect(try await stepList(provisioner) == ["found@1"])

    await provisioner.observe(.fileSent(filename: "grubx64.efi", mac: mac))
    #expect(try await stepList(provisioner) == ["found@1"])

    await provisioner.observe(.fileSent(filename: "/hwe-initrd", mac: mac))
    #expect(try await stepList(provisioner) == ["found@1", "booting@1"])
}

@Test func offerAfterProgressStartsNewAttempt() async throws {
    let provisioner = try await bound()
    await provisioner.observe(.offered(mac: mac))
    await provisioner.observe(.fileSent(filename: "hwe-initrd", mac: mac))
    await provisioner.observe(.fileSent(filename: "hwe-vmlinuz", mac: mac))
    _ = try await provisioner.report(report(.progress, .tooling, name: "m-1"))
    await provisioner.observe(.offered(mac: mac))

    let entry = try await provisioner.entry("m-1")
    #expect(try await stepList(provisioner) == ["found@1", "booting@1", "configuring@1", "found@2"])
    #expect(entry.stage == nil)
    #expect(entry.status == .assigned)
}

@Test func offerAfterFailureClearsIt() async throws {
    let clock = TestClock()
    let provisioner = try await bound(now: { clock.now })
    _ = try await provisioner.report(report(.failed, .installer, name: "m-1", reason: "disk"))
    clock.advance(60)
    await provisioner.observe(.offered(mac: mac))

    let entry = try await provisioner.entry("m-1")
    #expect(entry.status == .assigned)
    #expect(entry.failureReason == nil)
    #expect(entry.failureStep == nil)
    #expect(await provisioner.machineRecord("m-1")?.attempt == 2)
    #expect(await provisioner.machineRecord("m-1")?.attemptStartedAt == t0.addingTimeInterval(60))
}

@Test func bootFilesBeforeAnyOfferAreIgnored() async throws {
    let provisioner = try await bound()
    await provisioner.observe(.fileSent(filename: "hwe-initrd", mac: mac))
    await provisioner.observe(.fileSent(filename: "hwe-vmlinuz", mac: mac))

    #expect(await provisioner.machineRecord("m-1") == nil)
    #expect(await eventSummary(provisioner).isEmpty)
}

@Test func failedMachineBootsWithinItsAttempt() async throws {
    let provisioner = try await bound()
    await provisioner.observe(.offered(mac: mac))
    _ = try await provisioner.report(report(.failed, .installer, name: "m-1", reason: "disk"))
    await provisioner.observe(.fileSent(filename: "hwe-initrd", mac: mac))
    await provisioner.observe(.fileSent(filename: "hwe-vmlinuz", mac: mac))

    let entry = try await provisioner.entry("m-1")
    #expect(try await stepList(provisioner) == ["found@1", "booting@1"])
    #expect(entry.status == .failed)
    #expect(entry.failureReason == "disk")
}

@Test func offerToInstalledChangesNothing() async throws {
    let provisioner = try await bound()
    _ = try await provisioner.report(report(.progress, .done, name: "m-1"))
    let before = try await stepList(provisioner)
    let events = await eventSummary(provisioner)
    await provisioner.observe(.offered(mac: mac))

    #expect(try await stepList(provisioner) == before)
    #expect(await eventSummary(provisioner) == events)
}

@Test func unboundMACIsIgnored() async throws {
    let provisioner = try await bound()
    await provisioner.observe(.offered(mac: "aa:bb:cc:00:00:99"))
    await provisioner.observe(.fileSent(filename: "hwe-initrd", mac: nil))

    #expect(await provisioner.machineRecord("m-1") == nil)
    #expect(await eventSummary(provisioner).isEmpty)
}

@Test(.enabled(if: directoryPermissionsApply))
func saveFailureEmitsNothing() async throws {
    let log = CapturedLog()
    let dir = DataDirectory(try temporaryDirectory())
    let provisioner = try Provisioner(dataDirectory: dir, bindings: FixedBindings(), logger: log.logger)
    _ = try await provisioner.provision([request("m-1")])
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.machines.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.machines.path) }

    await provisioner.observe(.offered(mac: mac))

    #expect(await eventSummary(provisioner).isEmpty)
    #expect(log.errors.count == 1)
}
