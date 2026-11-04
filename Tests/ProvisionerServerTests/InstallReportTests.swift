import Foundation
import ProvisionerAPI
@testable import ProvisionerServer
import Testing

private func queued(_ name: String = "m-1", clock: TestClock = TestClock()) async throws -> (Provisioner, DataDirectory) {
    let (provisioner, dir) = try makeProvisioner(now: { clock.now })
    _ = try await provisioner.provision([request(name)])
    return (provisioner, dir)
}

@Test func reportByMACIsNotFound() async throws {
    let (provisioner, _) = try await queued()

    await #expect(throws: ProvisionerFailure.self) {
        try await provisioner.report(report(.progress, .tooling, mac: "aa:bb:cc:dd:ee:ff"))
    }
    do {
        _ = try await provisioner.report(report(.progress, .tooling, mac: "aa:bb:cc:dd:ee:ff"))
    } catch .notFound {
    } catch {
        Issue.record("expected notFound, got \(error)")
    }
}

@Test func reportForUnknownNameIsNotFound() async throws {
    let (provisioner, _) = try await queued()

    await #expect(throws: ProvisionerFailure.notFound("other")) {
        try await provisioner.report(report(.progress, .tooling, name: "other"))
    }
}

@Test func reportWithNameAndMACRejected() async throws {
    let (provisioner, _) = try await queued()

    do {
        _ = try await provisioner.report(report(.progress, .tooling, name: "m-1", mac: "aa:bb:cc:dd:ee:ff"))
        Issue.record("expected the report to be rejected")
    } catch .invalid {
    }
}

@Test func progressRecordsAndEmits() async throws {
    let (provisioner, _) = try await queued()

    #expect(try await provisioner.report(report(.progress, .lateCommands, name: "M-1")) == .recorded)

    let entry = try await provisioner.entry("m-1")
    #expect(entry.status == .installing)
    #expect(entry.stage == .lateCommands)
    #expect(await eventSummary(provisioner) == ["install-progress late-commands"])
}

@Test func repeatStageIsDuplicate() async throws {
    let (provisioner, _) = try await queued()
    _ = try await provisioner.report(report(.progress, .tooling, name: "m-1"))

    #expect(try await provisioner.report(report(.progress, .tooling, name: "m-1")) == .duplicate)
    #expect(await eventSummary(provisioner).count == 1)
}

@Test func doneCompletes() async throws {
    let clock = TestClock()
    let (provisioner, _) = try await queued(clock: clock)
    _ = try await provisioner.report(report(.progress, .lateCommands, name: "m-1"))
    clock.advance(30)

    #expect(try await provisioner.report(report(.progress, .done, name: "m-1")) == .recorded)

    let entry = try await provisioner.entry("m-1")
    #expect(entry.status == .installed)
    #expect(entry.completedAt == t0 + 30)
    #expect(await eventSummary(provisioner) == ["install-progress late-commands", "install-progress done", "install-complete 30.0"])
}

@Test func progressAfterCompletionIgnored() async throws {
    let (provisioner, _) = try await queued()
    _ = try await provisioner.report(report(.progress, .done, name: "m-1"))

    #expect(try await provisioner.report(report(.progress, .tooling, name: "m-1")) == .ignored)
    #expect(try await provisioner.entry("m-1").status == .installed)
}

@Test func failureRecordsSanitizedReason() async throws {
    let (provisioner, _) = try await queued()

    #expect(try await provisioner.report(report(.failed, .tooling, name: "m-1", reason: "bad\u{7}\n\n disk")) == .recorded)

    let entry = try await provisioner.entry("m-1")
    #expect(entry.status == .failed)
    #expect(entry.failureReason == "bad disk")
    #expect(await eventSummary(provisioner) == ["install-failed tooling installer: bad disk"])
}

@Test func emptyReasonGetsDefault() async throws {
    let (provisioner, _) = try await queued()

    _ = try await provisioner.report(report(.failed, .installer, name: "m-1", reason: " \n"))

    #expect(try await provisioner.entry("m-1").failureReason == "installer reported a failure")
}

@Test func longReasonIsCut() async throws {
    let (provisioner, _) = try await queued()

    _ = try await provisioner.report(report(.failed, .installer, name: "m-1", reason: String(repeating: "x", count: 600)))

    #expect(try await provisioner.entry("m-1").failureReason?.count == 500)
}

@Test func failureRepeatDuplicate() async throws {
    let (provisioner, _) = try await queued()
    _ = try await provisioner.report(report(.failed, .tooling, name: "m-1"))

    #expect(try await provisioner.report(report(.failed, .tooling, name: "m-1")) == .duplicate)
}

@Test func failureAfterCompletionIgnored() async throws {
    let (provisioner, _) = try await queued()
    _ = try await provisioner.report(report(.progress, .done, name: "m-1"))

    #expect(try await provisioner.report(report(.failed, .tooling, name: "m-1")) == .ignored)
    #expect(try await provisioner.entry("m-1").status == .installed)
}

@Test func progressAfterFailureStartsNewAttempt() async throws {
    let clock = TestClock()
    let (provisioner, _) = try await queued(clock: clock)
    _ = try await provisioner.report(report(.progress, .lateCommands, name: "m-1"))
    _ = try await provisioner.report(report(.failed, .tooling, name: "m-1"))
    clock.advance(100)

    #expect(try await provisioner.report(report(.progress, .lateCommands, name: "m-1")) == .recorded)
    clock.advance(20)
    _ = try await provisioner.report(report(.progress, .done, name: "m-1"))

    let entry = try await provisioner.entry("m-1")
    #expect(entry.status == .installed)
    #expect(entry.failedAt == nil)
    #expect(entry.failureReason == nil)
    #expect(await provisioner.machineRecord("m-1")?.attempt == 2)
    #expect(await eventSummary(provisioner, after: 2) == ["install-progress late-commands", "install-progress done", "install-complete 20.0"])
}

@Test(arguments: [(Schemas.InstallReport.KindPayload.progress, Schemas.InstallStage.unknown),
                  (.progress, .installer), (.failed, .done), (.failed, .unknown)])
func stageNotAllowedForKind(kind: Schemas.InstallReport.KindPayload, stage: Schemas.InstallStage) async throws {
    let (provisioner, _) = try await queued()

    do {
        _ = try await provisioner.report(report(kind, stage, name: "m-1"))
        Issue.record("expected \(kind.rawValue) at \(stage.rawValue) to be rejected")
    } catch .invalid {
    }
}

@Test func journalFailureStillRecords() async throws {
    let root = try temporaryDirectory()
    try FileManager.default.createDirectory(at: DataDirectory(root).journal, withIntermediateDirectories: true)
    let (provisioner, _) = try makeProvisioner(root)
    _ = try await provisioner.provision([request("m-1")])

    #expect(try await provisioner.report(report(.progress, .tooling, name: "m-1")) == .recorded)
    #expect(try await provisioner.entry("m-1").status == .installing)
    #expect(await provisioner.lastEventID == 0)
}
