public import Foundation
package import ProvisionerAPI

public struct MachineEvent: Sendable, Equatable {
    public enum FailureSource: String, Sendable, Equatable {
        case installer, timeout, reboot
    }

    public enum GuardReason: String, Sendable, Equatable {
        case hostnameFetch = "hostname-fetch"
        case repeatPXE = "repeat-pxe"
    }

    public enum Kind: Sendable, Equatable {
        case assigned
        case installStarted
        case installProgress(stage: String)
        case installFailed(stage: String, reason: String, source: FailureSource)
        case installComplete(duration: TimeInterval)
        case guardInstalled(reason: GuardReason)
        case stepReached(step: ProvisioningStep, attempt: Int)
        case downloadProgress(bytes: Int, total: Int)
    }

    public var id: Int
    public var timestamp: Date
    public var name: String
    /// Absent for USB-flashed machines.
    public var mac: String?
    public var kind: Kind

    public init(id: Int, timestamp: Date, name: String, mac: String?, kind: Kind) {
        self.id = id
        self.timestamp = timestamp
        self.name = name
        self.mac = mac
        self.kind = kind
    }
}

/// The `data` of one SSE frame.
package enum WireEvent: Sendable, Equatable {
    case machine(MachineEvent)
    case resync(latestID: Int)

    package init(_ wire: Components.Schemas.MachineEvent) {
        switch wire {
        case .machineAssigned(let e):
            self = .machine(.init(id: e.id, timestamp: e.timestamp, name: e.name, mac: e.mac, kind: .assigned))
        case .installStarted(let e):
            self = .machine(.init(id: e.id, timestamp: e.timestamp, name: e.name, mac: e.mac, kind: .installStarted))
        case .installProgress(let e):
            self = .machine(.init(id: e.id, timestamp: e.timestamp, name: e.name, mac: e.mac?.value1,
                                  kind: .installProgress(stage: e.stage.rawValue)))
        case .installFailed(let e):
            self = .machine(.init(id: e.id, timestamp: e.timestamp, name: e.name, mac: e.mac?.value1,
                                  kind: .installFailed(stage: e.stage.rawValue, reason: e.reason,
                                                       source: MachineEvent.FailureSource(rawValue: e.source.rawValue)!)))
        case .installComplete(let e):
            self = .machine(.init(id: e.id, timestamp: e.timestamp, name: e.name, mac: e.mac?.value1,
                                  kind: .installComplete(duration: e.durationSeconds)))
        case .guardInstalled(let e):
            self = .machine(.init(id: e.id, timestamp: e.timestamp, name: e.name, mac: e.mac,
                                  kind: .guardInstalled(reason: MachineEvent.GuardReason(rawValue: e.reason.rawValue)!)))
        case .stepReached(let e):
            self = .machine(.init(id: e.id, timestamp: e.timestamp, name: e.name, mac: e.mac?.value1,
                                  kind: .stepReached(step: ProvisioningStep(rawValue: e.step.rawValue)!, attempt: e.attempt)))
        case .downloadProgress(let e):
            self = .machine(.init(id: e.id, timestamp: e.timestamp, name: e.name, mac: e.mac?.value1,
                                  kind: .downloadProgress(bytes: e.bytes, total: e.total)))
        case .resync(let e):
            self = .resync(latestID: e.latestId)
        }
    }
}
