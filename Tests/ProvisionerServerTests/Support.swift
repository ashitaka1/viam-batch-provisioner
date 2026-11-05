import Foundation
import ProvisionerAPI
@testable import ProvisionerServer

/// A clock the test advances.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = t0) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

func report(_ kind: Schemas.InstallReport.KindPayload, _ stage: Schemas.InstallStage, name: String? = nil,
            mac: String? = nil, reason: String? = nil) -> Schemas.InstallReport {
    .init(kind: kind, stage: stage, name: name, mac: mac, reason: reason)
}

/// The journal's events after `id`, as (type, stage) pairs for readable comparison.
func eventSummary(_ provisioner: Provisioner, after id: Int = 0) async -> [String] {
    await provisioner.journalEvents(after: id).map(\.summary)
}

extension Schemas.MachineEvent {
    var summary: String {
        switch self {
        case .installProgress(let e): "install-progress \(e.stage.rawValue)"
        case .installFailed(let e): "install-failed \(e.stage.rawValue) \(e.source.rawValue): \(e.reason)"
        case .installComplete(let e): "install-complete \(e.durationSeconds)"
        case .resync(let e): "resync \(e.latestId)"
        default: "other"
        }
    }
}

final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Waits until `condition` holds or `limit` passes.
func poll(within limit: Duration, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + limit
    while !condition() && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}
