import Foundation
@testable import ProvisionerKit
import Testing

private let t0 = Date(timeIntervalSince1970: 1_000)

private func entry(
    status: EntryStatus, mode: ProvisionMode? = .full, steps: [ProvisioningStep] = [], stage: String? = nil,
    queuedAt: Date? = t0, failureStep: ProvisioningStep? = nil, bytes: Int? = nil, total: Int? = nil
) -> QueueEntry {
    QueueEntry(
        name: "m1", status: status, failureReason: status == .failed ? "Installer error" : nil, stage: stage,
        hasCredentials: true, queuedAt: queuedAt,
        steps: steps.enumerated().map { StepTime(step: $0.element, at: t0.addingTimeInterval(Double($0.offset + 1)), attempt: 1) },
        osName: "Ubuntu 24.04.4", downloadBytes: bytes, downloadTotal: total, failureStep: failureStep,
        provisionMode: mode, joinsTailscale: false)
}

private func line(_ entry: QueueEntry, onlineAt: Date? = nil) -> ProgressLine {
    ProgressLine(entry: entry, progress: ProvisioningProgress(entry: entry, onlineAt: onlineAt))
}

struct ProgressLineTests {
    @Test func queued() {
        #expect(line(entry(status: .queued)) == ProgressLine(tone: .waiting, text: "Queued"))
    }

    @Test func downloadingShowsItsPercentage() {
        let e = entry(status: .assigned, steps: [.found, .booting, .downloading], bytes: 42, total: 100)
        #expect(line(e) == ProgressLine(tone: .active, text: "Downloading Ubuntu 24.04.4 · 42%"))
    }

    @Test func configuringShowsItsSubStep() {
        let e = entry(status: .installing, steps: [.installing, .configuring], stage: "tooling")
        #expect(line(e) == ProgressLine(tone: .active, text: "Configuring · Installing Viam"))
    }

    @Test func fullMachineIsRestartingUntilViamOnline() {
        let e = entry(status: .installed, steps: [.installing, .configuring, .installed])
        #expect(line(e) == ProgressLine(tone: .installed, text: "Installed · restarting"))
        #expect(line(e, onlineAt: t0.addingTimeInterval(60)) == ProgressLine(tone: .installed, text: "Viam online"))
    }

    @Test func agentMachineEndsAtInstalled() {
        let e = entry(status: .installed, mode: .agent, steps: [.installing, .configuring, .installed])
        #expect(line(e) == ProgressLine(tone: .installed, text: "Installed"))
    }

    @Test func failureNamesItsStep() {
        let e = entry(status: .failed, steps: [.found, .booting, .downloading], failureStep: .downloading)
        #expect(line(e) == ProgressLine(tone: .failed, text: "Failed at Downloading Ubuntu 24.04.4"))
    }

    @Test func failureNamesItsSubStep() {
        let e = entry(status: .failed, steps: [.installing, .configuring], stage: "tooling", failureStep: .configuring)
        #expect(line(e) == ProgressLine(tone: .failed, text: "Failed at Configuring · Installing Viam"))
    }

    @Test func flashedMachine() {
        #expect(line(entry(status: .flashed)) == ProgressLine(tone: .waiting, text: "Flashed"))
    }

    @Test func pythonServerEntryShowsItsStatusAndStage() {
        let e = entry(status: .installing, stage: "late-commands", queuedAt: nil)
        #expect(line(e) == ProgressLine(tone: .active, text: "Installing · late-commands"))
        #expect(line(entry(status: .assigned, queuedAt: nil)) == ProgressLine(tone: .active, text: "Booting"))
    }
}
