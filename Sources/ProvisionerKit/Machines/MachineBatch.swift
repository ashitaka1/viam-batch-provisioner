public import Foundation

/// A machine created in Viam, with the viam.json its installer needs.
public struct ProvisionedMachine: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let name: String
    public let machineID: String
    public let partID: String
    /// `{"cloud": {"app_address", "id", "secret"}}`: the machine's viam.json.
    public let credentialsJSON: Data

    public var request: ProvisionRequest { ProvisionRequest(name: name, credentialsJSON: credentialsJSON) }

    public var description: String { "ProvisionedMachine(\(name), machine \(machineID), part \(partID))" }
    public var debugDescription: String { description }
}

public struct MachineFailure: Sendable, Equatable {
    public let name: String
    public let message: String
    /// Known once Viam returned the machine's ID or the lookup found it.
    public let machineID: String?
    /// A machine may remain in Viam: its delete or the lookup for it failed, or,
    /// after an unknown outcome, the lookup found one under the name.
    public let leftInViam: Bool

    public init(name: String, message: String, machineID: String?, leftInViam: Bool) {
        self.name = name
        self.message = message
        self.machineID = machineID
        self.leftInViam = leftInViam
    }
}

public enum BatchStop: Sendable, Equatable {
    case rejected(String)
    case cancelled
}

public struct BatchResult: Sendable, Equatable {
    public var created: [ProvisionedMachine] = []
    public var failures: [MachineFailure] = []
    public var stop: BatchStop?
    /// Names never attempted because the batch stopped.
    public var untried: [String] = []
}

public enum BatchError: Error, Sendable, Equatable {
    case naming(MachineNamingError)
    case fleet(FleetError)
}

/// Creates a batch of machines in one location, one at a time. A machine that
/// fails partway is deleted; the batch goes on with the next name, and stops
/// early only when the key is rejected or the task is cancelled.
public struct MachineBatch: Sendable {
    public static let appAddress = "https://app.viam.com:443"

    private let fleet: any ViamFleet
    private let location: String

    public init(fleet: any ViamFleet, location: String) {
        self.fleet = fleet
        self.location = location
    }

    /// Lists the location, picks names, then creates them. Throws only before
    /// the first machine is created; after that the result says what happened.
    public func create(prefix: String, count: Int, queued: Set<String>) async throws(BatchError) -> BatchResult {
        do {
            try MachineNaming.check(prefix: prefix, count: count)
        } catch {
            throw .naming(error)
        }
        let existing: [ViamMachine]
        do {
            existing = try await fleet.machines(location: location)
        } catch {
            throw .fleet(error)
        }
        let names: [String]
        do {
            names = try MachineNaming.names(prefix: prefix, count: count, existing: existing.map(\.name), queued: queued)
        } catch {
            throw .naming(error)
        }
        return await create(names: names)
    }

    private func create(names: [String]) async -> BatchResult {
        var result = BatchResult()
        for (index, name) in names.enumerated() {
            if Task.isCancelled {
                result.stop = .cancelled
                result.untried = Array(names[index...])
                break
            }
            // An unstructured task doesn't inherit cancellation, so the machine in
            // progress is finished or deleted, never abandoned half-made.
            switch await Task(operation: { await createOne(name) }).value {
            case .created(let machine):
                result.created.append(machine)
            case .failed(let failure, let rejection):
                result.failures.append(failure)
                if let rejection {
                    result.stop = .rejected(rejection)
                    result.untried = Array(names[(index + 1)...])
                    return result
                }
            }
        }
        return result
    }

    private enum Outcome {
        case created(ProvisionedMachine)
        /// The rejection message when the key was refused.
        case failed(MachineFailure, rejection: String?)
    }

    private func createOne(_ name: String) async -> Outcome {
        let machineID: String
        do {
            machineID = try await fleet.createMachine(name: name, location: location)
        } catch {
            switch error {
            case .rejected(let message):
                return .failed(MachineFailure(name: name, message: message, machineID: nil, leftInViam: false), rejection: message)
            case .failed(let message):
                return .failed(MachineFailure(name: name, message: message, machineID: nil, leftInViam: false), rejection: nil)
            case .unreachable(let message):
                return .failed(await reportIfCreated(name, message: message), rejection: nil)
            }
        }

        let part: MachinePart
        do {
            part = try await fleet.mainPart(machine: machineID)
        } catch {
            let deleted = await delete(machineID)
            let failure = MachineFailure(name: name, message: error.message, machineID: machineID, leftInViam: !deleted)
            if case .rejected(let message) = error { return .failed(failure, rejection: message) }
            return .failed(failure, rejection: nil)
        }

        return .created(ProvisionedMachine(
            name: name, machineID: machineID, partID: part.id, credentialsJSON: Self.credentialsJSON(part)))
    }

    /// After a create whose outcome is unknown: report a same-named machine as
    /// possibly left in Viam. It is never deleted, because another operator may
    /// have created it.
    private func reportIfCreated(_ name: String, message: String) async -> MachineFailure {
        let match: ViamMachine?
        do {
            match = try await fleet.machines(location: location).first { $0.name.lowercased() == name.lowercased() }
        } catch {
            return MachineFailure(name: name, message: message, machineID: nil, leftInViam: true)
        }
        return MachineFailure(name: name, message: message, machineID: match?.id, leftInViam: match != nil)
    }

    private func delete(_ machineID: String) async -> Bool {
        do {
            try await fleet.deleteMachine(id: machineID)
            return true
        } catch {
            return false
        }
    }

    static func credentialsJSON(_ part: MachinePart) -> Data {
        let blob = ["cloud": ["app_address": appAddress, "id": part.id, "secret": part.secret]]
        // A dictionary of strings always serializes.
        return try! JSONSerialization.data(withJSONObject: blob, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

extension FleetError {
    var message: String {
        switch self {
        case .rejected(let message), .failed(let message), .unreachable(let message): message
        }
    }
}
