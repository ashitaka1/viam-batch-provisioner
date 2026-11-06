import Foundation
import ProvisionerAPI

extension Provisioner {
    /// Appends `step` for the current attempt and returns whether it was added; a
    /// step the attempt already has is left alone. The caller saves the record,
    /// then calls `announce`, so no event is journaled for an unsaved record.
    @discardableResult
    func reach(_ step: Components.Schemas.ProvisioningStep, _ record: inout MachineRecord, name: String, mac: String?) -> Bool {
        guard !record.steps.contains(where: { $0.step == step.rawValue && $0.attempt == record.attempt }) else { return false }
        record.steps.append(StepRecord(step: step.rawValue, at: now(), attempt: record.attempt))
        return true
    }

    /// Emits `step-reached` for a step `reach` added and the caller saved.
    func announce(_ step: Components.Schemas.ProvisioningStep, _ record: MachineRecord, name: String, mac: String?) {
        let time = record.steps.last { $0.step == step.rawValue }?.at ?? now()
        let attempt = record.attempt
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
