import Foundation
@testable import ProvisionerKit
import Testing

private let t0 = Date(timeIntervalSince1970: 1_000)

private func entry(
    status: EntryStatus = .queued, mode: ProvisionMode? = .full, steps: [(ProvisioningStep, Int)] = [],
    osName: String? = "Ubuntu 24.04.4", stage: String? = nil, tailscale: Bool? = nil
) -> QueueEntry {
    QueueEntry(
        name: "m1", status: status, stage: stage, hasCredentials: true, queuedAt: t0,
        steps: steps.enumerated().map { StepTime(step: $0.element.0, at: t0.addingTimeInterval(Double($0.offset + 1)), attempt: $0.element.1) },
        osName: osName, provisionMode: mode, joinsTailscale: tailscale)
}

private func progress(_ entry: QueueEntry, onlineAt: Date? = nil) -> ProvisioningProgress {
    ProvisioningProgress(entry: entry, onlineAt: onlineAt)!
}

struct ProvisioningProgressTests {
    @Test func queuedEntryShowsQueuedThenPending() {
        let rows = progress(entry()).rows
        #expect(rows.map(\.title) == ["Queued", "Found", "Booting", "Downloading Ubuntu 24.04.4", "Installing Ubuntu 24.04.4", "Configuring", "Installed", "Online"])
        #expect(rows.map(\.state) == [.current] + Array(repeating: .pending, count: 7))
        #expect(rows[0].at == t0)
    }

    @Test func agentEndsAtInstalled() {
        #expect(progress(entry(mode: .agent)).rows.last?.title == "Installed")
    }

    @Test func noOSNameSaysOS() {
        let titles = progress(entry(osName: nil)).rows.map(\.title)
        #expect(titles.contains("Downloading OS"))
        #expect(titles.contains("Installing OS"))
    }

    @Test func reachedStepsAreDoneAndLastIsCurrent() {
        let rows = progress(entry(status: .assigned, steps: [(.found, 1), (.booting, 1)])).rows
        #expect(rows.map(\.state) == [.done, .done, .current] + Array(repeating: .pending, count: 5))
    }

    @Test func downloadingCarriesFraction() {
        var e = entry(status: .assigned, steps: [(.found, 1), (.booting, 1), (.downloading, 1)])
        e.downloadBytes = 25
        e.downloadTotal = 100
        let p = progress(e)
        #expect(p.current.title == "Downloading Ubuntu 24.04.4")
        #expect(p.current.fraction == 0.25)
    }

    @Test func configuringSubSteps() {
        let steps: [(ProvisioningStep, Int)] = [(.found, 1), (.booting, 1), (.downloading, 1), (.installing, 1), (.configuring, 1)]
        let agent = progress(entry(status: .installing, mode: .agent, steps: steps, stage: "tooling")).current
        #expect(agent.subSteps.map(\.title) == ["Setting name and credentials", "Installing Viam"])
        #expect(agent.subSteps.map(\.state) == [.done, .current])
        let osOnly = progress(entry(status: .installing, mode: .osOnly, steps: steps, stage: "tailscale", tailscale: true)).current
        #expect(osOnly.subSteps.map(\.title) == ["Setting name and credentials", "Joining Tailscale"])
        #expect(osOnly.subSteps.map(\.state) == [.done, .current])
    }

    @Test func installedMarksEverySubStepDone() {
        let steps: [(ProvisioningStep, Int)] = [(.configuring, 1), (.installed, 1)]
        let rows = progress(entry(status: .installed, mode: .agent, steps: steps)).rows
        let configuring = rows.first { $0.kind == .configuring }
        #expect(configuring?.subSteps.map(\.state) == [.done, .done])
    }

    @Test func failureMarksItsStep() {
        var e = entry(status: .failed, steps: [(.found, 1), (.booting, 1), (.downloading, 1), (.installing, 1)])
        e.failureStep = .installing
        let p = progress(e)
        #expect(p.current.title == "Installing Ubuntu 24.04.4")
        #expect(p.current.state == .failed)
    }

    @Test func failureAtUnreachedStepAppendsIt() {
        var e = entry(status: .failed, steps: [(.found, 1)])
        e.failureStep = .booting
        let p = progress(e)
        #expect(p.current.kind == .booting)
        #expect(p.current.state == .failed)
        #expect(p.rows.filter { $0.kind == .booting }.count == 1)
    }

    @Test func onlineCompletes() {
        let steps: [(ProvisioningStep, Int)] = [(.found, 1), (.booting, 1), (.downloading, 1), (.installing, 1), (.configuring, 1), (.installed, 1)]
        let online = t0.addingTimeInterval(99)
        let p = progress(entry(status: .installed, steps: steps), onlineAt: online)
        #expect(p.current.kind == .online)
        #expect(p.current.state == .done)
        #expect(p.current.at == online)
        #expect(progress(entry(status: .installed, steps: steps)).current.kind == .installed)
    }

    @Test func earlierAttemptKept() {
        let p = progress(entry(status: .assigned, steps: [(.found, 1), (.booting, 1), (.found, 2)]))
        #expect(p.rows.prefix(2).map(\.title) == ["Queued", "Found"])
        #expect(p.earlierAttempts.map { $0.map(\.title) } == [["Found", "Booting"]])
    }

    @Test func pythonEntryHasNoProgress() {
        #expect(ProvisioningProgress(entry: entry(status: .installing, stage: "tooling")) == nil)
        #expect(ProvisioningProgress(entry: entry(status: .queued)) != nil)
    }

    @Test func skippedStepsBeforeTheLatestAreOmitted() {
        let agent = progress(entry(status: .installing, mode: .agent, steps: [(.configuring, 1), (.installed, 1)])).rows
        #expect(agent.map(\.title) == ["Queued", "Configuring", "Installed"])
    }

    @Test func entryAtInstallingShowsLaterStepsPending() {
        let p = progress(entry(status: .installing, steps: [(.installing, 1)]))
        #expect(p.rows.map(\.title) == ["Queued", "Installing Ubuntu 24.04.4", "Configuring", "Installed", "Online"])
        #expect(p.current.kind == .installing)
    }

    @Test func unreachedFailureStepSitsInCanonicalPosition() {
        var e = entry(status: .failed, steps: [(.found, 1)])
        e.failureStep = .installing
        let rows = progress(e).rows
        #expect(rows.map(\.title) == ["Queued", "Found", "Installing Ubuntu 24.04.4", "Configuring", "Installed", "Online"])
        #expect(rows.map(\.state) == [.done, .done, .failed, .pending, .pending, .pending])
    }

    @Test func failureBeforeLastReachedStepKeepsLaterRowsDone() {
        var e = entry(status: .failed, steps: [(.found, 1), (.booting, 1), (.downloading, 1)])
        e.failureStep = .booting
        let p = progress(e)
        #expect(p.current.kind == .booting)
        #expect(p.rows.first { $0.kind == .downloading }?.state == .done)
    }

    @Test func failureWithoutStepMarksLastReached() {
        let p = progress(entry(status: .failed, steps: [(.found, 1), (.booting, 1)]))
        #expect(p.current.kind == .booting)
        #expect(p.current.state == .failed)
        #expect(p.rows.first { $0.kind == .found }?.state == .done)
    }

    @Test func fractionClampsAndNeedsATotal() {
        #expect(ProvisioningProgress.fraction(bytes: 150, total: 100) == 1)
        #expect(ProvisioningProgress.fraction(bytes: 5, total: 0) == nil)
        #expect(ProvisioningProgress.fraction(bytes: nil, total: 10) == nil)
    }
}
