import Foundation
import ProvisionerAPI

enum Backlog: Sendable {
    case events([Components.Schemas.MachineEvent])
    case resync(latestID: Int)
}

/// What a stream sends: the backlog first, then `live` until `cancel`.
struct EventSubscription: Sendable {
    let backlog: Backlog
    let live: AsyncStream<Components.Schemas.MachineEvent>
    let cancel: @Sendable () -> Void
}

/// Live event delivery to open streams. Owned by the `Provisioner` actor.
struct EventFanout {
    private var continuations: [UUID: AsyncStream<Components.Schemas.MachineEvent>.Continuation] = [:]

    mutating func add(_ id: UUID, _ continuation: AsyncStream<Components.Schemas.MachineEvent>.Continuation) {
        continuations[id] = continuation
    }

    mutating func remove(_ id: UUID) {
        continuations[id] = nil
    }

    var count: Int { continuations.count }

    func publish(_ event: Components.Schemas.MachineEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }
}
