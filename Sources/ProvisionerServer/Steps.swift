import Foundation
import ProvisionerAPI

extension Provisioner {
    /// Records `step` for the current attempt and emits `step-reached`; a step the
    /// attempt already has is left alone. The caller saves the record.
    func reach(_ step: Components.Schemas.ProvisioningStep, _ record: inout MachineRecord, name: String, mac: String?) {
        guard !record.steps.contains(where: { $0.step == step.rawValue && $0.attempt == record.attempt }) else { return }
        let time = now()
        let attempt = record.attempt
        record.steps.append(StepRecord(step: step.rawValue, at: time, attempt: attempt))
        emit {
            .stepReached(.init(id: $0, _type: .stepReached, timestamp: time, name: name,
                               mac: mac.map { .init(value1: $0) }, step: step, attempt: attempt))
        }
    }

    /// Starts the next attempt. Earlier attempts' steps stay.
    func beginAttempt(_ record: inout MachineRecord) {
        record.attempt += 1
        record.attemptStartedAt = now()
        record.stage = nil
        record.progressAt = nil
        record.failedAt = nil
        record.failureReason = nil
        record.failureSource = nil
        record.failureStep = nil
        record.bootFilesSent = []
        record.downloadBytes = nil
        record.downloadTotal = nil
    }
}
