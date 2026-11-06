import Foundation
import ProvisionerAPI

extension Provisioner {
    /// Appends `step` for the current attempt and returns the added record, or nil
    /// when the attempt already has the step. The caller saves the record, then
    /// calls `announce`, so no event is journaled for an unsaved record.
    func reach(_ step: Components.Schemas.ProvisioningStep, _ record: inout MachineRecord) -> StepRecord? {
        guard !record.steps.contains(where: { $0.step == step.rawValue && $0.attempt == record.attempt }) else { return nil }
        let added = StepRecord(step: step.rawValue, at: now(), attempt: record.attempt)
        record.steps.append(added)
        return added
    }

    /// Emits `step-reached` for a step `reach` added and the caller saved.
    func announce(_ added: StepRecord, name: String, mac: String?) {
        guard let step = Components.Schemas.ProvisioningStep(rawValue: added.step) else { return }
        emit {
            .stepReached(.init(id: $0, _type: .stepReached, timestamp: added.at, name: name,
                               mac: mac.map { .init(value1: $0) }, step: step, attempt: added.attempt))
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
