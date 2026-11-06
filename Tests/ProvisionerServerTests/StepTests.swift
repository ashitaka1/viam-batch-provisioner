import Foundation
import ProvisionerAPI
@testable import ProvisionerServer
import Testing

private func queued(_ name: String = "m-1") async throws -> (Provisioner, DataDirectory) {
    let (provisioner, dir) = try makeProvisioner()
    _ = try await provisioner.provision([request(name)])
    return (provisioner, dir)
}

@Test func reportsAloneRecordOnlyTheirSteps() async throws {
    let (provisioner, _) = try await queued()
    _ = try await provisioner.report(report(.progress, .lateCommands, name: "m-1"))
    _ = try await provisioner.report(report(.progress, .tooling, name: "m-1"))
    _ = try await provisioner.report(report(.progress, .done, name: "m-1"))

    let entry = try await provisioner.entry("m-1")
    #expect(entry.steps?.map(\.step) == [.configuring, .installed])
    #expect(entry.steps?.map(\.attempt) == [1, 1])
    #expect(entry.status == .installed)
    let steps = await eventSummary(provisioner).filter { $0.hasPrefix("step-reached") }
    #expect(steps == ["step-reached m-1 configuring", "step-reached m-1 installed"])
}

@Test func installerStagesReachTheirSteps() async throws {
    #expect(reportedStep(.installer) == nil)
    #expect(reportedStep(.identity) == .configuring)
    #expect(reportedStep(.tailscale) == .configuring)
    #expect(reportedStep(.done) == .installed)

    let (provisioner, _) = try await queued()
    _ = try await provisioner.report(report(.progress, .identity, name: "m-1"))
    _ = try await provisioner.report(report(.progress, .tailscale, name: "m-1"))
    #expect(try await provisioner.entry("m-1").steps?.map(\.step) == [.configuring])
    #expect(await eventSummary(provisioner).filter { $0.hasPrefix("step-reached") } == ["step-reached m-1 configuring"])
}

@Test func installerFailureNamesInstalling() async throws {
    let (provisioner, _) = try await queued()
    _ = try await provisioner.report(report(.failed, .installer, name: "m-1", reason: "disk"))

    #expect(try await provisioner.entry("m-1").failureStep == .installing)
    let events = await provisioner.journalEvents(after: 0)
    guard case .installFailed(let failed) = events.last else { Issue.record("no install-failed event"); return }
    #expect(failed.step == .installing)
}

@Test func lateFailureNamesConfiguring() async throws {
    let (provisioner, _) = try await queued()
    _ = try await provisioner.report(report(.failed, .tooling, name: "m-1"))

    #expect(try await provisioner.entry("m-1").failureStep == .configuring)
    let events = await provisioner.journalEvents(after: 0)
    guard case .installFailed(let failed) = events.last else { Issue.record("no install-failed event"); return }
    #expect(failed.step == .configuring)
}

@Test func provisionRecordsModeAndTailscale() async throws {
    let (provisioner, _) = try makeProvisioner()
    let environment = Schemas.Environment(provisionMode: .agent, username: "viam", passwordHash: "$6$x$y",
                                          sshPublicKey: "ssh-ed25519 AAAA", timezone: "UTC", tailscaleAuthKey: "tskey-secret")
    _ = try await provisioner.provision([request("with-env", environment: environment), request("without")])

    let with = try await provisioner.entry("with-env")
    #expect(with.provisionMode == .agent)
    #expect(with.joinsTailscale == true)
    #expect(with.queuedAt == t0)
    let without = try await provisioner.entry("without")
    #expect(without.provisionMode == nil)
    #expect(without.joinsTailscale == nil)
}

@Test func observedStepReadsAssigned() async throws {
    let (_, dir) = try await queued()
    let record = MachineRecord(attempt: 1, steps: [StepRecord(step: "found", at: t0, attempt: 1)])
    try MachineStore(dir).save(machine: record, key: "m-1")

    let (reopened, _) = try makeProvisioner(dir.root)
    let entry = try await reopened.entry("m-1")
    #expect(entry.status == .assigned)
    #expect(entry.steps?.map(\.step) == [.found])
}

@Test func stepsOfAnEarlierAttemptAloneReadQueued() {
    let steps = [StepRecord(step: "found", at: t0, attempt: 1)]
    #expect(derivedStatus(MachineRecord(attempt: 2, steps: steps)) == .queued)
}

@Test func beginAttemptKeepsStepsAndClearsTheRest() async throws {
    let (provisioner, _) = try await queued()
    let earlier = t0.addingTimeInterval(-600)
    var record = MachineRecord(attempt: 1, stage: "tooling", attemptStartedAt: earlier, progressAt: earlier,
                               failedAt: t0, failureReason: "x", failureSource: "installer",
                               steps: [StepRecord(step: "found", at: t0, attempt: 1)], bootFilesSent: ["a"],
                               downloadBytes: 1, downloadTotal: 2, failureStep: "configuring")
    await provisioner.beginAttempt(&record)

    #expect(record.attempt == 2)
    #expect(record.attemptStartedAt == t0)
    #expect(record.stage == nil && record.progressAt == nil && record.failedAt == nil && record.failureStep == nil)
    #expect(record.failureReason == nil && record.failureSource == nil)
    #expect(record.bootFilesSent.isEmpty && record.downloadBytes == nil && record.downloadTotal == nil)
    #expect(record.steps.count == 1)
    #expect(derivedStatus(record) == .queued)
}

@Test func reachRecordsOncePerAttempt() async throws {
    let (provisioner, _) = try await queued()
    var record = MachineRecord(attempt: 1)
    #expect(await provisioner.reach(.found, &record)?.attempt == 1)
    #expect(await provisioner.reach(.found, &record) == nil)
    #expect(record.steps.count == 1)
    await provisioner.beginAttempt(&record)
    #expect(await provisioner.reach(.found, &record)?.attempt == 2)
    #expect(record.steps.map(\.attempt) == [1, 2])
    #expect(await eventSummary(provisioner).isEmpty)
}

@Test func announceEmitsStepReached() async throws {
    let (provisioner, _) = try await queued()
    var record = MachineRecord(attempt: 1)
    let added = try #require(await provisioner.reach(.found, &record))
    await provisioner.announce(added, name: "m-1", mac: "aa:bb:cc:dd:ee:ff")

    #expect(await eventSummary(provisioner) == ["step-reached m-1 found"])
}

@Test(.enabled(if: directoryPermissionsApply))
func failedSaveEmitsNoStepReached() async throws {
    let (provisioner, dir) = try await queued()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.machines.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.machines.path) }

    #expect(await failure { try await provisioner.report(report(.progress, .lateCommands, name: "m-1")) }?.kind == "internal")
    #expect(await eventSummary(provisioner).isEmpty)
}
