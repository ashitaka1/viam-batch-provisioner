import ProvisionerAPI

/// A machine's status from its record: `failed` first, since a failure can
/// follow a completion.
func derivedStatus(_ record: MachineRecord?) -> Components.Schemas.EntryStatus {
    guard let record else { return .queued }
    if record.failedAt != nil { return .failed }
    if record.completedAt != nil { return .installed }
    if record.stage != nil { return .installing }
    if record.steps.contains(where: { $0.attempt == record.attempt }) { return .assigned }
    return .queued
}
