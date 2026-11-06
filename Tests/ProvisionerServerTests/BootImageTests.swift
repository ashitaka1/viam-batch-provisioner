import Foundation
import ProvisionerAPI
@testable import ProvisionerServer
import Testing

@Test func osNameFromUbuntuISO() {
    #expect(osName(forImageNamed: "ubuntu-24.04.4-live-server-amd64.iso") == "Ubuntu 24.04.4")
}

@Test func osNameFallsBackToFileName() {
    #expect(osName(forImageNamed: "custom.iso") == "custom")
}

@Test func provisionRecordsOSName() async throws {
    let files = try temporaryDirectory()
    try Data("iso".utf8).write(to: files.appending(path: "ubuntu-24.04.4-live-server-amd64.iso"))
    let image = try BootImage(files: files, path: "ubuntu-24.04.4-live-server-amd64.iso")
    let (provisioner, _) = try makeProvisioner(bootImage: image)

    _ = try await provisioner.provision([request("m-1")])

    #expect(try await provisioner.entry("m-1").osName == "Ubuntu 24.04.4")
}

private func queued(now: @escaping @Sendable () -> Date = { t0 }) async throws -> Provisioner {
    let (provisioner, _) = try makeProvisioner(now: now)
    _ = try await provisioner.provision([request("m-1")])
    return provisioner
}

private func stepNames(_ provisioner: Provisioner) async throws -> [String] {
    try await provisioner.entry("m-1").steps?.map(\.step.rawValue) ?? []
}

@Test func downloadReachesDownloadingThenInstalling() async throws {
    let provisioner = try await queued()

    await provisioner.downloadStarted("m-1", total: 100)
    await provisioner.downloadEnded("m-1", bytes: 100)

    #expect(try await stepNames(provisioner) == ["downloading", "installing"])
    let events = await eventSummary(provisioner)
    #expect(events.contains("download-progress m-1 0/100"))
    #expect(events.contains("step-reached m-1 installing"))
    let entry = try await provisioner.entry("m-1")
    #expect(entry.downloadBytes == 100)
    #expect(entry.downloadTotal == 100)
}

@Test func progressIsJournaledCoarsely() async throws {
    let clock = TestClock()
    let provisioner = try await queued(now: { clock.now })
    await provisioner.downloadStarted("m-1", total: 1000)
    let start = await provisioner.lastEventID

    clock.advance(1)
    await provisioner.downloadProgressed("m-1", bytes: 10)
    #expect(await eventSummary(provisioner, after: start) == [])

    clock.advance(5)
    await provisioner.downloadProgressed("m-1", bytes: 60)
    #expect(await eventSummary(provisioner, after: start) == ["download-progress m-1 60/1000"])
    #expect(try await provisioner.entry("m-1").downloadBytes == 60)

    clock.advance(14)
    await provisioner.downloadProgressed("m-1", bytes: 70)
    #expect(await eventSummary(provisioner, after: start) == ["download-progress m-1 60/1000"])

    clock.advance(1)
    await provisioner.downloadProgressed("m-1", bytes: 200)
    #expect(await eventSummary(provisioner, after: start)
        == ["download-progress m-1 60/1000", "download-progress m-1 200/1000"])
}

@Test func interruptedDownloadStaysDownloading() async throws {
    let provisioner = try await queued()

    await provisioner.downloadStarted("m-1", total: 100)
    await provisioner.downloadEnded("m-1", bytes: 40)

    #expect(try await stepNames(provisioner) == ["downloading"])
    #expect(try await provisioner.entry("m-1").downloadBytes == 40)
    #expect(await eventSummary(provisioner).last == "download-progress m-1 40/100")
}

@Test func secondDownloadRestartsCount() async throws {
    let provisioner = try await queued()

    await provisioner.downloadStarted("m-1", total: 100)
    await provisioner.downloadEnded("m-1", bytes: 40)
    await provisioner.downloadStarted("m-1", total: 100)

    #expect(try await stepNames(provisioner) == ["downloading"])
    #expect(try await provisioner.entry("m-1").downloadBytes == 0)
}

@Test func installedMachineRecordsNothing() async throws {
    let provisioner = try await queued()
    _ = try await provisioner.report(report(.progress, .done, name: "m-1"))
    let before = try await provisioner.entry("m-1")
    let lastID = await provisioner.lastEventID

    await provisioner.downloadStarted("m-1", total: 100)
    await provisioner.downloadEnded("m-1", bytes: 100)

    #expect(try await provisioner.entry("m-1") == before)
    #expect(await eventSummary(provisioner, after: lastID) == [])
}
