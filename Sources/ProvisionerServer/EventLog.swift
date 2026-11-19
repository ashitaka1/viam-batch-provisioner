import Foundation
import ProvisionerAPI

extension Components.Schemas.MachineEvent {
    /// The event as one line of the server's log. Install reports carry no log text, so nothing here is secret.
    var logDescription: String {
        switch self {
        case .stepReached(let e): "\(e.name) reached \(e.step.rawValue) in attempt \(e.attempt)"
        case .installProgress(let e): "\(e.name) reported \(e.stage.rawValue)"
        case .installFailed(let e): "\(e.name) failed at \(e.stage.rawValue) (\(e.source.rawValue)): \(e.reason)"
        case .installComplete(let e): "\(e.name) installed in \(e.durationSeconds) s"
        case .downloadProgress(let e): "\(e.name) downloaded \(e.bytes) of \(e.total) bytes"
        case .resync(let e): "resync to \(e.latestId)"
        default: "\(self)"
        }
    }

    var eventID: Int? {
        switch self {
        case .stepReached(let e): e.id
        case .installProgress(let e): e.id
        case .installFailed(let e): e.id
        case .installComplete(let e): e.id
        case .downloadProgress(let e): e.id
        default: nil
        }
    }
}
