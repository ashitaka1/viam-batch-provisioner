/// A Viam location in the org a fleet is bound to.
public struct ViamLocation: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ViamMachine: Sendable, Equatable {
    public let id: String
    public let name: String
    public let online: Bool

    public init(id: String, name: String, online: Bool = false) {
        self.id = id
        self.name = name
        self.online = online
    }
}

/// A machine's main part: the ID and secret its viam.json carries.
public struct MachinePart: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: String
    public let secret: String

    public init(id: String, secret: String) {
        self.id = id
        self.secret = secret
    }

    public var description: String { "MachinePart(\(id))" }
    public var debugDescription: String { description }
}

public enum FleetError: Error, Sendable, Equatable {
    /// The key was refused; every later call would be refused too.
    case rejected(String)
    /// Viam returned an error status; the call changed nothing.
    case failed(String)
    /// No usable answer; the call may or may not have taken effect.
    case unreachable(String)
}

/// The Viam calls machine creation needs, bound to one org's credential.
public protocol ViamFleet: Sendable {
    func locations() async throws(FleetError) -> [ViamLocation]
    func machines(location: String) async throws(FleetError) -> [ViamMachine]
    /// Returns the new machine's ID.
    func createMachine(name: String, location: String) async throws(FleetError) -> String
    func mainPart(machine: String) async throws(FleetError) -> MachinePart
    func deleteMachine(id: String) async throws(FleetError)
}
