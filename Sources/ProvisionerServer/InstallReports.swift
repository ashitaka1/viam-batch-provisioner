import Foundation
import ProvisionerAPI

let maxReasonLength = 500
let defaultFailureReason = "installer reported a failure"

/// Mirrors PROGRESS_STAGES and FAILURE_STAGES in pxe-watcher/provisioner_service.py.
private let progressStages: Set<Components.Schemas.InstallStage> = [.lateCommands, .identity, .tooling, .tailscale, .done]
private let failureStages: Set<Components.Schemas.InstallStage> = [.installer, .lateCommands, .identity, .tooling, .tailscale]

/// A failure reason safe to store: control characters become spaces,
/// whitespace collapses, the length is capped, and empty becomes the default.
func sanitizeReason(_ text: String?) -> String {
    guard let text else { return defaultFailureReason }
    let printable = String(text.unicodeScalars.map { scalar -> Character in
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: " "
        default: Character(scalar)
        }
    })
    let collapsed = printable.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let cut = String(collapsed.prefix(maxReasonLength))
    return cut.isEmpty ? defaultFailureReason : cut
}

func reportedStep(_ stage: Components.Schemas.InstallStage) -> Components.Schemas.ProvisioningStep? {
    switch stage {
    case .lateCommands, .identity, .tooling, .tailscale: .configuring
    case .done: .installed
    default: nil
    }
}

extension Provisioner {
    func report(_ report: Components.Schemas.InstallReport) throws(ProvisionerFailure) -> Components.Schemas.InstallReportResult.ResultPayload {
        try validate(report)
        guard let name = report.name else { throw .notFound(report.mac ?? "") }
        let (queued, store) = try lookup(name)
        var record = store.machine(queued.key) ?? MachineRecord()
        let stage = report.stage
        let time = now()

        switch report.kind {
        case .progress:
            if record.completedAt != nil { return .ignored }
            if record.failedAt != nil {
                beginAttempt(&record)
            } else if record.stage == stage.rawValue {
                return .duplicate
            }
            if record.attemptStartedAt == nil {
                record.attemptStartedAt = time
                record.attempt = max(record.attempt, 1)
            }
            record.stage = stage.rawValue
            record.progressAt = time
            if stage == .done { record.completedAt = time }
            let step = reportedStep(stage)
            let added = step.flatMap { reach($0, &record) }
            try save(record, queued.key, store)
            if let added { announce(added, name: queued.name, mac: nil) }
            emit { .installProgress(.init(id: $0, _type: .installProgress, timestamp: time, name: queued.name, stage: stage)) }
            if stage == .done, let started = record.attemptStartedAt {
                let duration = time.timeIntervalSince(started)
                emit { .installComplete(.init(id: $0, _type: .installComplete, timestamp: time, name: queued.name,
                                              durationSeconds: duration)) }
            }
        case .failed:
            if record.completedAt != nil { return .ignored }
            if record.failedAt != nil { return .duplicate }
            let reason = sanitizeReason(report.reason)
            if record.attemptStartedAt == nil {
                record.attemptStartedAt = time
                record.attempt = max(record.attempt, 1)
            }
            record.stage = stage.rawValue
            record.failedAt = time
            record.failureReason = reason
            record.failureSource = "installer"
            let failureStep: Components.Schemas.ProvisioningStep = stage == .installer ? .installing : .configuring
            record.failureStep = failureStep.rawValue
            try save(record, queued.key, store)
            emit { .installFailed(.init(id: $0, _type: .installFailed, timestamp: time, name: queued.name, stage: stage,
                                        reason: reason, source: .installer, step: failureStep)) }
        }
        return .recorded
    }

    private func validate(_ report: Components.Schemas.InstallReport) throws(ProvisionerFailure) {
        var details: [Components.Schemas.ErrorDetail] = []
        let allowed = report.kind == .progress ? progressStages : failureStages
        if !allowed.contains(report.stage) {
            let names = allowed.map(\.rawValue).sorted().joined(separator: ", ")
            details.append(.init(field: "stage", message: "for \(report.kind.rawValue) must be one of \(names)"))
        }
        if (report.name == nil) == (report.mac == nil) {
            details.append(.init(message: "exactly one of name and mac is required"))
        }
        if !details.isEmpty {
            throw .invalid(message: "invalid install report", details: details)
        }
    }

    private func save(_ record: MachineRecord, _ key: String, _ store: MachineStore) throws(ProvisionerFailure) {
        do {
            try store.save(machine: record, key: key)
        } catch {
            throw .internal("could not record the report: \(error)")
        }
    }
}
